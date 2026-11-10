mutable struct Runtime
    state::Symbol
    owns_mpi::Bool
    threadlevel::Int
    requests::IdDict{Any,Nothing}
    groups::Dict{Int,Any}
    registrations::IdDict{Any,Nothing}
end
const _runtime = Ref{Union{Nothing,Runtime}}(nothing)

struct Comm
    handle::Ptr{Cvoid}
    runtime::Runtime
    gid::Int
    keepalive::Any
    rankmap::Union{Nothing,Vector{Cint}}
end
Comm(handle,runtime,gid,keepalive)=Comm(handle,runtime,gid,keepalive,nothing)
_reordered(c::Comm)=c.rankmap!==nothing
Initialized() = _runtime[] !== nothing && _runtime[].state in (:active,:finalized)
Finalized() = _runtime[] !== nothing && _runtime[].state == :finalized

function _threadcheck()
    r=_runtime[]
    r!==nothing && r.threadlevel>=2 && return nothing
    ccall(_symbol(:wjl_thread_ok),Cint,())==1 || throw(ArgumentError("MPI provided only THREAD_FUNNELED; call WaitIO on the initialization OS thread or initialize MPI with THREAD_SERIALIZED/THREAD_MULTIPLE"))
end
@locked function _rt()
    r=_runtime[]
    r!==nothing && r.state==:active || throw(ArgumentError("WaitIO is not active"))
    _threadcheck()
    ccall(_symbol(:wjl_mpi_finalized),Cint,())==0 || throw(ArgumentError("MPI was finalized externally"))
    r
end
function _comm(c::Comm)
    c.runtime===_rt() || throw(ArgumentError("communicator belongs to another runtime"))
    c.handle==C_NULL && throw(ArgumentError("null communicator"))
    c.handle
end

"Initialize once. mpi=:external never initializes or finalizes MPI; :auto owns MPI only if it starts it."
@locked function Init(;config=nothing,mpi::Symbol=:auto)
    mpi in (:auto,:external) || throw(ArgumentError("mpi must be :auto or :external"))
    if _runtime[]!==nothing
        _runtime[].state==:active && config===nothing && return (_rt(); nothing)
        throw(ArgumentError("cannot reinitialize or reconfigure a started runtime"))
    end
    config===nothing || configure!(config)
    check_library()
    r=Runtime(:starting,false,0,IdDict(),Dict(),IdDict())
    _runtime[]=r
    owned=Ref{Cint}(0); provided=Ref{Cint}(0)
    code=ccall(_symbol(:wjl_mpi_start),Cint,(Cint,Ref{Cint},Ref{Cint}),mpi==:external,owned,provided)
    r.owns_mpi=owned[]!=0; r.threadlevel=Int(provided[])
    if code!=0
        r.state=:failed
        throw(WaitIOError(:MPI_Init_thread,code,"cannot safely initialize; use a fresh process"))
    end
    handle=Ref{Ptr{Cvoid}}(C_NULL)
    code=API.waitio_create_universe(handle) # includes waitio_init; do not initialize twice
    if code!=0 || handle[]==C_NULL
        r.state=:failed
        throw(WaitIOError(:waitio_create_universe,code,"initialization incomplete; native state retained"))
    end
    r.groups[0]=Comm(handle[],r,0,nothing)
    r.state=:active
    nothing
end
Comm_world() = _rt().groups[0]::Comm
function _int_query(fn::Function)
    value=Ref{Cint}(0)
    _check(nameof(fn),fn(value))
    Int(value[])
end
@locked function Comm_rank(c::Comm=Comm_world())
    _comm(c)
    native=_int_query(v -> API.waitio_group_rank(c.handle,v))
    c.rankmap===nothing && return native
    i=findfirst(==(native),c.rankmap)
    i===nothing ? -1 : i-1
end
Comm_size(c::Comm=Comm_world()) = (_comm(c); _int_query(v -> API.waitio_group_size(c.handle,v)))
PB_rank() = (_rt(); _int_query(API.waitio_pb_rank))
PB_size() = (_rt(); _int_query(API.waitio_pb_size))
@locked function PB_nprocs()
    _rt()
    result=zeros(Cint,PB_size())
    _check(:waitio_get_nprocs,API.waitio_get_nprocs(result))
    Int.(result)
end
@locked function Ismember(c::Comm)
    code=API.waitio_group_ismember(_comm(c))
    code in (0,1) || throw(WaitIOError(:waitio_group_ismember,code,"unrecognized membership result"))
    code==1
end
@locked function Hostinfo(c::Comm,rank::Integer)
    native_rank=_rank(c,rank)
    ip=Ref{Cint}(0); port=Ref{Cint}(0)
    _check(:waitio_group_hostinfo,API.waitio_group_hostinfo(_comm(c),native_rank,ip,port))
    (;address_raw=reinterpret(UInt32,ip[]),port_raw=port[])
end
@locked function PB_hostinfo(pbid::Integer,rank::Integer)
    0<=pbid<PB_size() || throw(ArgumentError("invalid PB ID"))
    0<=rank<PB_nprocs()[pbid+1] || throw(ArgumentError("invalid rank within PB"))
    ip=Ref{Cint}(0); port=Ref{Cint}(0)
    _check(:waitio_pb_hostinfo,API.waitio_pb_hostinfo(_cint(pbid),_cint(rank),ip,port))
    (;address_raw=reinterpret(UInt32,ip[]),port_raw=port[])
end

"""
Create a local group table with a C filter per PB: :all, :head, or :none.
All processes, including excluded processes, must use the same ID and selection.
Create every required group, then Barrier(Comm_world()) before using any new group:
native progress may receive traffic for another group before a peer has created it.
Only members should query rank/size or communicate on the returned group.
"""
@locked function Create_group(gid::Integer;selection=fill(:all,PB_size()),order=collect(0:PB_size()-1))
    r=_rt(); n=PB_size()
    limit=ccall(_symbol(:wjl_group_limit),Cint,())
    0<gid<limit || throw(ArgumentError("group ID must be in 1:$(limit-1); 0 is the universe"))
    haskey(r.groups,gid) && throw(ArgumentError("group ID already used"))
    length(selection)==length(order)==n || throw(DimensionMismatch("one selection and order entry required per PB"))
    sort(collect(order))==collect(0:n-1) || throw(ArgumentError("order must be a permutation of PB IDs"))
    filters=Cint[ s==:all ? 1 : s==:head ? 2 : s==:none ? 0 : throw(ArgumentError("invalid selection: $s")) for s in selection ]
    ordering=Cint.(order)
    rankmap=nothing
    handle=ccall(_symbol(:wjl_create_group),Ptr{Cvoid},(Cint,Cint,Ptr{Cint},Ptr{Cint}),_cint(gid),_cint(n),filters,ordering)
    handle==C_NULL && throw(WaitIOError(:waitio_create_group,-1,"returned NULL"))
    c=Comm(handle,r,Int(gid),(filters,ordering),rankmap)
    r.groups[Int(gid)]=c
    c
end
Comm_pbheads(;gid=1) = Create_group(gid;selection=fill(:head,PB_size()))
function _rank(c,rank)
    0<=rank<Comm_size(c) || throw(ArgumentError("rank $rank outside communicator"))
    c.rankmap===nothing ? _cint(rank) : c.rankmap[Int(rank)+1]
end

pending_count() = lock(() -> length(_rt().requests),_call_lock)
"Wait for all retained requests, including requests whose user references were dropped."
function Drain()
    Waitall(lock(() -> collect(keys(_rt().requests)),_call_lock))
    nothing
end
"Finalize explicitly. Pending requests prevent teardown; native libraries remain loaded."
@locked function Finalize()
    Finalized() && return nothing
    r=_rt()
    !r.owns_mpi || ccall(_symbol(:wjl_thread_ok),Cint,())==1 || throw(ArgumentError("finalize on the initialization OS thread, as required by MPI"))
    isempty(r.requests) || throw(PendingRequestsError(length(r.requests)))
    for memory in collect(keys(r.registrations))
        Unregister!(memory)
    end
    r.state=:finalizing
    try
        _check(:waitio_finalize,API.waitio_finalize())
        ccall(_symbol(:wjl_cleanup_groups),Cvoid,())
        _check(:MPI_Finalize,ccall(_symbol(:wjl_mpi_stop),Cint,(Cint,),r.owns_mpi))
        _cleanup_objects!()
        r.state=:finalized
    catch
        r.state=:failed
        rethrow()
    end
    nothing
end
