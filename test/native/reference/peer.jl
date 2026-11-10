# Same fixtures, independently implemented in Julia. Native API symbols are
# never replaced by Julia algorithms; wide cases explicitly select LONG.
using WaitIO
const W=WaitIO
length(ARGS)==6 || error("usage: peer.jl ID OPERATION TYPE OP ROOT COUNT")
id,name,casekind,opname,rootarg,countarg=ARGS
kind=replace(casekind,"-wide"=>"")
n=parse(Int,countarg); 0<=n<=1024 || error("invalid count")
T=Dict("i32"=>Int32,"i64"=>Int64,"f32"=>Float32,"f64"=>Float64,"u8"=>UInt8,"i8"=>Int8)[kind]
function input(rank,i)
    kind=="u8" && return opname=="sum" ? rank+1 : (rank==0 ? 200+i : 100-i)
    kind=="i8" && return opname=="sum" ? rank+1 : (rank==0 ? -56+i : 100-i)
    kind=="i64" && return (Int64(1)<<40)+10rank+i
    x=(rank==0 ? 10 : -10)+i
    startswith(kind,"f") ? x+0.25 : x
end
config=W.configuration_info().config
for (field,env) in ((:libwaitio,"REFERENCE_LIBWAITIO"),(:libwaitio_mpi,"REFERENCE_LIBWAITIO_MPI"))
    realpath(getfield(config,field))==realpath(ENV[env]) || error("C and Julia library paths differ: $field")
end
# Match the C peer's preflight before either side enters native initialization.
# Otherwise a missing symbol on one peer leaves the other waiting for a partner.
W.check_library()
required=name=="p2p" ? (:waitio_isend,:waitio_irecv,:waitio_wait) : (Symbol("waitio_mpi_",name),)
for symbol in required
    try
        W.API.function_pointer(symbol)
    catch err
        err isa W.UnsupportedFeatureError || rethrow()
        println(stderr,"MISSING_SYMBOL ",symbol)
        exit(77)
    end
end
W.Init()
g=W.Comm_world(); rank=W.Comm_rank(g); size=W.Comm_size(g)
size==2 || error("This fixture requires exactly two ranks")
root=parse(Int,rootarg); root==-1 && (root=size-1)
s=T[input(rank,i) for i in 0:n-1]; r=fill(T(7),size*n)
op=Dict("sum"=>W.SUM,"min"=>W.MIN,"max"=>W.MAX)[opname]
dt=W.native_code(W.Datatype(T)); opcode=W.native_code(op)
rc=0; out=T[]; status=Cint[]
# Standard operations exercise the user-facing API. Algorithm variants and
# status arrays exercise API directly because there is no high-level equivalent.
if endswith(casekind,"-wide")
    wide=Int64.(s); result=zeros(Int64,n)
    name=="allreduce" ? W.Allreduce!(wide,result,op,g) : W.Reduce!(wide,result,op,g;root)
    out=T[x % T for x in result]
    name=="reduce" && rank!=root && empty!(out)
elseif name=="allreduce"
    out=fill(T(7),n); W.Allreduce!(s,out,op,g)
elseif name=="reduce"
    out=fill(T(7),n); W.Reduce!(s,out,op,g;root); rank==root || empty!(out)
elseif name=="bcast"
    out=copy(s); W.Bcast!(out,g;root)
elseif name=="gather"
    W.Gather!(s,r,g;root); out=rank==root ? r : T[]
elseif name=="allgather"
    W.Allgather!(s,r,g); out=r
elseif name=="scatter"
    s=T[input(dest,i) for dest in 0:size-1 for i in 0:n-1]
    out=fill(T(7),n); W.Scatter!(s,out,g;root)
elseif name=="p2p"
    out=fill(T(7),n)
    requests=[W.Irecv!(out,g;source=1-rank,tag=91),W.Isend(s,g;dest=1-rank,tag=91)]
    W.Waitall(requests)
elseif name=="waitall"
    out=fill(T(7),n); status=Cint[-777,-777]
    stride=W.API.request_size(); requests=zeros(UInt8,2stride)
    GC.@preserve s out status requests begin
        q=Ptr{Cvoid}(pointer(requests))
        W.API.waitio_mpi_irecv(out,n,dt,1-rank,91,g.handle,q)==0 || error("irecv failed")
        W.API.waitio_mpi_isend(s,n,dt,1-rank,91,g.handle,q+stride)==0 || error("isend failed")
        rc=W.API.waitio_mpi_waitall(2,q,status)
    end
else
    f=getfield(W.API,Symbol("waitio_mpi_",name))
    GC.@preserve s r begin
        if startswith(name,"bcast")
            rc=f(s,n,dt,root,g.handle); out=s
        elseif startswith(name,"allreduce")
            rc=f(s,r,n,dt,opcode,g.handle); out=r[1:n]
        elseif startswith(name,"reduce")
            rc=f(s,r,n,dt,opcode,root,g.handle); out=rank==root ? r[1:n] : T[]
        elseif startswith(name,"allgather")
            rc=f(s,r,n,dt,g.handle); out=r
        elseif startswith(name,"gather")
            rc=f(s,r,n,dt,root,g.handle); out=rank==root ? r : T[]
        elseif startswith(name,"scatter")
            s=T[input(dest,i) for dest in 0:size-1 for i in 0:n-1]
            GC.@preserve s rc=f(s,n,dt,r,n,dt,root,g.handle)
            out=r[1:n]
        else
            error("unknown operation $name")
        end
    end
end
# Int8/UInt8 string representations are not all decimal in Julia.
values=join((x isa Integer ? string(Int64(x)) : string(x) for x in out),",")
println("RESULT\t$id\t$rank\t$size\t$rc\t$values\t",join(status,",")); flush(stdout)
rc==0 || error("native call returned $rc")
W.Finalize()
