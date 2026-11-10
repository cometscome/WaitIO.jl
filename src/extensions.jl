"""
Opt-in Julia collective protocols. Every participant must implement the chosen
protocol; these are not interchangeable with native WaitIO C collective calls.
"""
module Extensions
import ..WaitIO
using ..WaitIO: API, Comm, Comm_world, Comm_rank, Comm_size, PB_size, PB_nprocs,
    Buffer, UBuffer, VBuffer, Datatype, Op, ValueLoc, InPlace, IN_PLACE,
    SUM, MIN, MAX, MAXLOC, MINLOC, Send, Recv!, WaitIOError,
    _call_lock, @locked, _comm, _rank, _count, _cint, _typed, _pointer,
    _locparts, _validate_reduction, _native_datatype, _reordered, _input, _same_type,
    _code, _check, _writeback!, _wireunits, _wirecounts, _wiredisplacements
include("extension_collectives.jl")
include("generic_collectives.jl")
include("inplace.jl")

"Create a group with Julia logical ranks over a canonical native group."
@locked function Create_group(gid::Integer;selection=fill(:all,PB_size()),order=collect(0:PB_size()-1))
    n=PB_size()
    sort(collect(order))==collect(0:n-1) || throw(ArgumentError("order must be a permutation of PB IDs"))
    c=WaitIO.Create_group(gid;selection)
    sizes=PB_nprocs()
    counts=[selection[i]==:none ? 0 : selection[i]==:head ? min(1,sizes[i]) : sizes[i] for i in 1:n]
    starts=cumsum(vcat(0,counts[1:end-1]))
    map=Cint[starts[pb+1]+j for pb in order for j in 0:counts[pb+1]-1]
    logical=Comm(c.handle,c.runtime,c.gid,c.keepalive,map)
    c.runtime.groups[Int(gid)]=logical
    logical
end
end
