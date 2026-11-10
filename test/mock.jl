# Julia test double for the installed native library. This is never package code.
# Request state lives outside the opaque allocation; the final byte is a guard
# against wrong allocation sizes and request-array strides.
module NativeMock
using WaitIO
const W=WaitIO
const initialized=Ref(false)
const threadlevel=Ref(Cint(2))
const maxthreadlevel=Ref(Cint(3))
const finalized=Ref(false)
const request_bytes=Ref(648)
const fail_tag=Ref{Culong}(999)
mutable struct Request
    buffer::Ptr{Cvoid}
    bytes::Int
    tag::Culong
    receive::Bool
    done::Bool
    consumed::Bool
end
const queue=Dict{Ptr{Cvoid},Request}()
put(p,n)=(unsafe_store!(p,Cint(n)); Cint(0))
mpi_initialized(p)=put(p,initialized[])
mpi_finalized(p)=put(p,finalized[])
mpi_start(a,b,c,p)=(initialized[]=true; threadlevel[]=min(c,maxthreadlevel[]); put(p,threadlevel[]))
query_thread(p)=put(p,threadlevel[])
mpi_stop()=(finalized[]=true; Cint(0))
one(p)=put(p,1)
zero(p)=put(p,0)
truef(p,n)=Cint(1)
headf(p,n)=Cint(n==0)
create(gid,f,o)=Ptr{Cvoid}(UInt(gid+1))
universe(p)=(unsafe_store!(p,Ptr{Cvoid}(UInt(1))); Cint(0))
rank(g,p)=put(p,0)
size(g,p)=put(p,1)
member(g)=Cint(1)
init(t)=Cint(0)
finish()=Cint(0)
barrier(g)=Cint(0)
function post(b,n,t,r,receive)
    unsafe_store!(Ptr{UInt8}(r),0x2a,request_bytes[])
    queue[r]=Request(b,Int(n),t,receive,false,false)
    t==fail_tag[] ? Cint(-77) : Cint(0)
end
send(g,p,b,n,t,r)=post(b,n,t,r,false)
recv(g,p,b,n,t,r)=post(b,n,t,r,true)
function test(r)
    q=get(queue,r,nothing)
    q===nothing && return Cint(-91)
    unsafe_load(Ptr{UInt8}(r),request_bytes[])==0x2a || return Cint(-92)
    q.consumed && return Cint(-88)
    if !q.done
        for (ptr,p) in queue
            ptr==r && continue
            if !p.consumed && !p.done && p.tag==q.tag && p.receive!=q.receive
                p.bytes==q.bytes || return Cint(-89)
                dest,src=q.receive ? (q.buffer,p.buffer) : (p.buffer,q.buffer)
                unsafe_copyto!(Ptr{UInt8}(dest),Ptr{UInt8}(src),q.bytes)
                p.done=q.done=true
                break
            end
        end
        return Cint(1)
    end
    q.consumed=true
    Cint(0)
end
function wait(r)
    # A bounded fixture failure is easier to diagnose than a hanging test.
    for _ in 1:10000
        rc=test(r); rc==1 || return rc
        yield()
    end
    Cint(-93)
end
function allreduce(s,r,n,d,op,g)
    unsafe_copyto!(Ptr{UInt8}(r),Ptr{UInt8}(s),Int(n)*W._jl_dtypesize(d))
    Cint(0)
end
typesize(d,p)=put(p,W._jl_dtypesize(d))
register(b,n,p)=(unsafe_store!(p,Libc.malloc(1)); nothing)
unregister(p)=(Libc.free(p); nothing)
const entries=(
    (:MPI_Finalized,Cint,(Ptr{Cint},),:mpi_finalized),
    (:MPI_Initialized,Cint,(Ptr{Cint},),:mpi_initialized),
    (:MPI_Init_thread,Cint,(Ptr{Cint},Ptr{Ptr{Ptr{UInt8}}},Cint,Ptr{Cint}),:mpi_start),
    (:MPI_Query_thread,Cint,(Ptr{Cint},),:query_thread),
    (:MPI_Is_thread_main,Cint,(Ptr{Cint},),:one),
    (:MPI_Finalize,Cint,(),:mpi_stop),
    (:waitio_init,Cint,(Cint,),:init),
    (:waitio_finalize,Cint,(),:finish),
    (:waitio_create_universe,Cint,(Ptr{Ptr{Cvoid}},),:universe),
    (:waitio_create_group,Ptr{Cvoid},(Cint,Ptr{Ptr{Cvoid}},Ptr{Cint}),:create),
    (:truef,Cint,(Cint,Cint),:truef),
    (:headf,Cint,(Cint,Cint),:headf),
    (:waitio_pb_rank,Cint,(Ptr{Cint},),:zero),
    (:waitio_pb_size,Cint,(Ptr{Cint},),:one),
    (:waitio_get_nprocs,Cint,(Ptr{Cint},),:one),
    (:waitio_group_rank,Cint,(Ptr{Cvoid},Ptr{Cint}),:rank),
    (:waitio_group_size,Cint,(Ptr{Cvoid},Ptr{Cint}),:size),
    (:waitio_group_ismember,Cint,(Ptr{Cvoid},),:member),
    (:waitio_isend,Cint,(Ptr{Cvoid},Cint,Ptr{Cvoid},Csize_t,Culong,Ptr{Cvoid}),:send),
    (:waitio_irecv,Cint,(Ptr{Cvoid},Cint,Ptr{Cvoid},Csize_t,Culong,Ptr{Cvoid}),:recv),
    (:waitio_test,Cint,(Ptr{Cvoid},),:test),
    (:waitio_wait,Cint,(Ptr{Cvoid},),:wait),
    (:waitio_mpi_barrier,Cint,(Ptr{Cvoid},),:barrier),
    (:waitio_mpi_allreduce,Cint,(Ptr{Cvoid},Ptr{Cvoid},Cint,Cint,Cint,Ptr{Cvoid}),:allreduce),
    (:waitio_mpi_type_size,Cint,(Cint,Ptr{Cint}),:typesize),
    (:waitio_register_mem,Cvoid,(Ptr{Cvoid},Cint,Ptr{Ptr{Cvoid}}),:register),
    (:waitio_unregister_mem,Cvoid,(Ptr{Cvoid},),:unregister))
for (name,result,types,fn) in entries
    @eval pointer_for(::Val{$(QuoteNode(name))})=@cfunction($fn,$result,$(Expr(:tuple,types...)))
end
function install(;bytes=648,compat=false,fixes=false)
    initialized[]=finalized[]=false; request_bytes[]=bytes; empty!(queue)
    c=W.LibraryConfig(miyabi_compat=compat,native_fixes=fixes)
    pointers=Dict(name=>pointer_for(Val(name)) for (name,_,_,_) in entries)
    info=Dict{String,Any}("implementation"=>"julia","request_bytes"=>bytes,
        "request_alignment"=>8,"group_limit"=>64,"pb_limit"=>64,
        "constants"=>[101,102,103,104,105,106,201,202,203,204,205],
        "test_pending"=>1,"compiler_invoked"=>false)
    W._config[]=c
    W._library[]=W.LibraryState(c,C_NULL,C_NULL,pointers,Dict(),info)
end
end
