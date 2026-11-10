const _OBJECT_GATHER_TAG=Culong(0x574a4c17)
const DEFAULT_MAX_OBJECT_BYTES = typemax(Int)
const _OBJECT_MAGIC = UInt8[0x57,0x4a,0x4c,0x4f,0x42,0x4a,0x30,0x32] # WJLOBJ02

function _object_limit(maxbytes::Integer)
    0<maxbytes<=typemax(Int) || throw(ArgumentError("maxbytes must be in 1:typemax(Int)"))
    Int(maxbytes)
end
function _serialize_object(obj,maxbytes)
    limit=_object_limit(maxbytes)
    io=IOBuffer(); Serialization.serialize(io,obj); bytes=take!(io)
    length(bytes)<=limit || throw(ArgumentError("serialized object exceeds maxbytes=$limit"))
    bytes
end
function _object_header(n::Integer)
    bytes=copy(_OBJECT_MAGIC)
    for shift in 0:8:56; push!(bytes,UInt8((UInt64(n)>>shift)&0xff)); end
    bytes
end
function _object_length(header,maxbytes)
    limit=_object_limit(maxbytes)
    length(header)==16 && header[1:8]==_OBJECT_MAGIC || throw(ArgumentError("invalid serialized-object protocol header"))
    n=zero(UInt64)
    for i in 0:7; n |= UInt64(header[9+i])<<(8i); end
    0<n<=limit || throw(ArgumentError("serialized object length exceeds maxbytes=$limit or is zero"))
    Int(n)
end
# A single user tag carries the header and payload in sequence. At most one
# stage is posted per peer/tag, so native matching need not order duplicates.
_object_tags(tag::Integer)=(_tag(tag),_tag(tag))
const _object_tails=Dict{Tuple{Ptr{Cvoid},Int,Culong},Any}()
const _object_receive_locks=Dict{Tuple{Ptr{Cvoid},Int,Culong},ReentrantLock}()
_object_key(c,peer,tag)=(c.handle,Int(peer),Culong(tag))

"A serialized nonblocking send, queued in call order for each peer and tag."
mutable struct ObjectRequest <: AbstractRequest
    runtime::Runtime
    comm::Comm
    peer::Int
    tag::Culong
    children::Vector{Request}
    buffer::Nothing
    state::Symbol
    error::Any
    payload::Vector{UInt8}
    predecessor::Any
    stage::Symbol
end
@locked function _poll(req::ObjectRequest)
    req.state in (:complete,:observed) && return true
    req.runtime===_rt() || throw(ArgumentError("request belongs to another runtime"))
    req.state==:error && throw(req.error)
    try
        if req.predecessor!==nothing
            # Follow a long queued stream iteratively, not through recursive
            # calls proportional to its number of outstanding messages.
            first=req
            while first.predecessor!==nothing && first.predecessor.state!=:complete
                first=first.predecessor
            end
            if first!==req
                _poll(first) && _complete(first)
                return false
            end
            req.predecessor=nothing
        end
        if req.stage==:queued
            push!(req.children,_post(_object_header(length(req.payload)),req.comm,req.peer,req.tag,false;object_protocol=true))
            req.stage=:header
        end
        child=last(req.children)
        _poll(child) || return false
        _complete(child)
        if req.stage==:header
            push!(req.children,_post(req.payload,req.comm,req.peer,req.tag,false;object_protocol=true))
            req.stage=:payload
            return false
        end
        req.state=:observed
        true
    catch e
        req.state=:error; req.error=e
        rethrow()
    end
end
@locked function _complete(req::ObjectRequest)
    req.state==:complete && return nothing
    req.state==:observed || throw(ArgumentError("object send is not complete"))
    _threadcheck()
    foreach(_complete,req.children)
    req.state=:complete
    req.payload=UInt8[]
    key=_object_key(req.comm,req.peer,req.tag)
    get(_object_tails,key,nothing)===req && delete!(_object_tails,key)
    delete!(req.runtime.requests,req)
    nothing
end
# Called by high-level completion routines so a recv also progresses queued
# local sends. No background thread may call a FUNNELED MPI implementation.
function _progress_objects()
    r=_runtime[]
    r===nothing && return nothing
    for req in collect(keys(r.requests))
        req isa ObjectRequest || continue
        req.state==:error && continue # report errors when this request is observed
        _poll(req) && _complete(req)
    end
    nothing
end
function Wait(req::ObjectRequest)
    while !Test(req); yield(); sleep(0.0001); end
    nothing
end

"Serialize now and queue a send; Wait/Test progresses its header and payload."
@locked function isend(obj,c::Comm=Comm_world();dest::Integer,tag::Integer=0,maxbytes::Integer=DEFAULT_MAX_OBJECT_BYTES)
    r=_rt(); _comm(c); _rank(c,dest); ht,_=_object_tags(tag)
    payload=_serialize_object(obj,maxbytes)
    key=_object_key(c,dest,ht)
    previous=get(_object_tails,key,nothing)
    req=ObjectRequest(r,c,Int(dest),ht,Request[],nothing,:posted,nothing,payload,previous,:queued)
    r.requests[req]=nothing
    _object_tails[key]=req
    _poll(req) # post the header when no previous message is active
    req
end
"Send a serialized Julia object. The peer must use WaitIO.recv, with compatible type definitions."
send(obj,c::Comm=Comm_world();kwargs...) = Wait(isend(obj,c;kwargs...))

"Receive and deserialize an object from a trusted Julia peer; no wildcard/probe is needed."
function recv(c::Comm=Comm_world();source::Integer,tag::Integer=0,maxbytes::Integer=DEFAULT_MAX_OBJECT_BYTES)
    _object_limit(maxbytes); ht,pt=_object_tags(tag)
    # Serialize receivers of this stream while allowing all other streams and
    # send progress. Never acquire a stream lock while holding _call_lock.
    stream=lock(_call_lock) do
        _comm(c); _rank(c,source)
        get!(_object_receive_locks,_object_key(c,source,ht)) do
            ReentrantLock()
        end
    end
    lock(stream) do
        header=zeros(UInt8,16)
        Wait(_post(header,c,source,ht,true;object_protocol=true))
        n=_object_length(header,maxbytes)
        payload=Vector{UInt8}(undef,n)
        Wait(_post(payload,c,source,pt,true;object_protocol=true))
        Serialization.deserialize(IOBuffer(payload))
    end
end

"Broadcast a serialized Julia object. All ranks must use the same root and maxbytes."
@locked function bcast(obj,c::Comm=Comm_world();root::Integer=0,maxbytes::Integer=DEFAULT_MAX_OBJECT_BYTES)
    _rank(c,root); _object_limit(maxbytes)
    mine=Comm_rank(c)==root
    payload=mine ? _serialize_object(obj,maxbytes) : UInt8[]
    header=mine ? _object_header(length(payload)) : zeros(UInt8,16)
    Bcast!(header,c;root)
    n=_object_length(header,maxbytes)
    mine || resize!(payload,n)
    # C collective counts are signed int; chunk large serialized payloads.
    for start in 1:Int(typemax(Cint)):n
        Bcast!(Buffer(payload;offset=start-1,count=min(n-start+1,Int(typemax(Cint)))),c;root)
    end
    mine ? obj : Serialization.deserialize(IOBuffer(payload))
end

"Gather serialized objects in rank order; returns Vector{Any} on root and nothing elsewhere."
@locked function gather(obj,c::Comm=Comm_world();root::Integer=0,maxbytes::Integer=DEFAULT_MAX_OBJECT_BYTES)
    _rank(c,root)
    payload=_serialize_object(obj,maxbytes)
    mine=Comm_rank(c)==root; nranks=Comm_size(c)
    headers=mine ? zeros(UInt8,16*nranks) : nothing
    Gather!(_object_header(length(payload)),headers,c;root)
    counts=mine ? [_object_length(@view(headers[16*i+1:16*(i+1)]),maxbytes) for i in 0:nranks-1] : Int[]
    total=mine ? sum(Int128.(counts)) : 0
    total<=typemax(Int) || throw(OverflowError("gathered objects exceed addressable memory"))
    if mine
        result=Vector{Any}(undef,nranks)
        for peer in 0:nranks-1
            bytes=peer==root ? payload : Vector{UInt8}(undef,counts[peer+1])
            peer==root || Recv!(bytes,c;source=peer,tag=_OBJECT_GATHER_TAG)
            result[peer+1]=Serialization.deserialize(IOBuffer(bytes))
        end
        result
    else
        Send(payload,c;dest=root,tag=_OBJECT_GATHER_TAG)
        nothing
    end
end

function _cleanup_objects!()
    empty!(_object_tails)
    empty!(_object_receive_locks)
    nothing
end
