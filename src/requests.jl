abstract type AbstractRequest end
mutable struct Request <: AbstractRequest
    native::Ptr{Cvoid}
    runtime::Runtime
    comm::Comm
    buffer::Any
    registrations::Vector{Any}
    operation::Symbol
    peer::Int
    tag::Culong
    state::Symbol
    error::Union{Nothing,WaitIOError}
end

function _tag(tag::Integer)
    0<=tag<=typemax(Culong) || throw(ArgumentError("tag must fit unsigned long"))
    Culong(tag)
end
@locked function _post(data,c::Comm,peer::Integer,tag::Integer,receive::Bool;object_protocol=false)
    r=_rt(); handle=_comm(c); rank=_rank(c,peer); native_tag=_tag(tag)
    b=Buffer(data); bytes=Csize_t(_nbytes(b))
    registrations=_registered_buffers(r,b)
    p=ccall(_symbol(:wjl_request_alloc),Ptr{Cvoid},())
    p==C_NULL && throw(OutOfMemoryError())
    operation=receive ? :waitio_irecv : :waitio_isend
    req=Request(p,r,c,b,registrations,operation,Int(peer),native_tag,:posted,nothing)
    r.requests[req]=nothing
    for memory in registrations; memory.users+=1; end
    # Root in runtime before exposing pointers to C. ccall preservation alone is insufficient.
    code = GC.@preserve b begin
        receive ? API.waitio_irecv(handle,rank,_pointer(b),bytes,native_tag,p) :
                  API.waitio_isend(handle,rank,_pointer(b),bytes,native_tag,p)
    end
    if code!=0
        req.state=:error
        req.error=WaitIOError(operation,code,"peer=$peer tag=$tag; native request retained because completion is unknown")
        throw(req.error)
    end
    req
end
Isend(data,c::Comm=Comm_world();dest::Integer,tag::Integer=0) = _post(data,c,dest,tag,false)
Irecv!(data,c::Comm=Comm_world();source::Integer,tag::Integer=0) = _post(data,c,source,tag,true)

function _request_context(req)
    req.runtime===_rt() || throw(ArgumentError("request belongs to another runtime"))
    req.state==:error && throw(req.error)
end
@locked function _poll(req::Request)
    req.state in (:complete,:observed) && return true
    _request_context(req)
    code=API.waitio_test(req.native)
    if code==0
        req.state=:observed
        return true
    elseif code==_library[].config.test_pending
        return false
    end
    req.state=:error
    req.error=WaitIOError(:waitio_test,code,"peer=$(req.peer) tag=$(req.tag); storage retained")
    throw(req.error)
end
@locked function _complete(req::Request)
    req.state==:complete && return nothing
    req.state==:observed || throw(ArgumentError("cannot release an incomplete request"))
    _threadcheck()
    req.operation==:waitio_irecv && _writeback!(req.buffer)
    ccall(_symbol(:wjl_request_free),Cvoid,(Ptr{Cvoid},),req.native)
    req.native=C_NULL
    for memory in req.registrations; memory.users-=1; end
    empty!(req.registrations)
    req.buffer=nothing
    req.state=:complete
    delete!(req.runtime.requests,req)
    nothing
end
@locked function Test(req::AbstractRequest)
    _progress_objects()
    done=_poll(req)
    done && _complete(req)
    done
end
function Wait(req::Request)
    while !Test(req); yield(); sleep(0.0001); end
    nothing
end
function Base.wait(req::AbstractRequest)
    while !Test(req); yield(); sleep(0.0001); end
    req
end
function _request_list(reqs)
    seen=IdDict{Any,Nothing}()
    for req in reqs
        req isa AbstractRequest || throw(ArgumentError("expected request objects"))
        haskey(seen,req) && throw(ArgumentError("duplicate request in completion list"))
        seen[req]=nothing
    end
    reqs
end
@locked function Testall(reqs::AbstractVector)
    _progress_objects()
    _request_list(reqs)
    ready=true
    for req in reqs
        ready=_poll(req) && ready # poll every request, even if an earlier one is pending
    end
    ready && foreach(_complete,reqs)
    ready
end
function Waitall(reqs::AbstractVector)
    _request_list(reqs)
    while !Testall(reqs); yield(); sleep(0.0001); end
    nothing
end
@locked function Testany(reqs::AbstractVector)
    _progress_objects()
    _request_list(reqs)
    active=false
    for i in eachindex(reqs)
        req=reqs[i]
        req.state==:complete && continue
        active=true
        if _poll(req)
            _complete(req)
            return true,i
        end
    end
    (!active,nothing)
end
function Waitany(reqs::AbstractVector)
    while true
        flag,index=Testany(reqs)
        flag && return index
        yield(); sleep(0.0001)
    end
end
@locked function Testsome(reqs::AbstractVector)
    _progress_objects()
    _request_list(reqs)
    active=false; indices=Int[]
    for i in eachindex(reqs)
        req=reqs[i]; req.state==:complete && continue
        active=true
        if _poll(req); _complete(req); push!(indices,i); end
    end
    active ? indices : nothing
end
function Waitsome(reqs::AbstractVector)
    while true
        indices=Testsome(reqs)
        (indices===nothing || !isempty(indices)) && return indices
        yield(); sleep(0.0001)
    end
end
Send(data,c::Comm=Comm_world();kwargs...) = Wait(Isend(data,c;kwargs...))
function Recv!(data,c::Comm=Comm_world();kwargs...)
    Wait(Irecv!(data,c;kwargs...))
    data
end
