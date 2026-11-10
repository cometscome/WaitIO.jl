using WaitIO, Test
const W=WaitIO
include("mock.jl")
include("collective_fixture.jl")
mode=ARGS[1]; bytes=parse(Int,ARGS[2])
NativeMock.install(;bytes)
mode=="fixture" && CollectiveFixture.install()
@test W.API.request_size()==bytes
W.Init()
comm=W.Comm_world()
@test W.Comm_rank(comm)==0
@test W.Comm_size(comm)==1
for (i,T) in enumerate((Int32,Int64,UInt8,Float32,Float64))
    s=T[1,2,3]; r=zeros(T,3)
    q=W.Irecv!(r,comm;source=0,tag=i)
    p=W.Isend(s,comm;dest=0,tag=i)
    GC.gc(true); W.Waitall([q,p]); @test s==r
end
struct Sample
    x::Matrix{Float64}
    label::String
end
x=Sample(reshape(collect(1.:12.),3,4),"Julia")
q=W.isend(x,comm;dest=0,tag=30); y=W.recv(comm;source=0,tag=30); W.Wait(q)
@test y.x==x.x && y.label==x.label
for selection in ([:all],[:head],[:none])
    g=W.Create_group(length(W._jl_group_filters)+1;selection)
    @test g isa W.Comm
end
# Ordinary groups forward PB ordering unchanged and retain native ranks.
const seen_order=Ref{Vector{Cint}}(Cint[])
function two_pbs(p); unsafe_store!(p,Cint(2)); Cint(0); end
function record_group(gid,filters,order)
    seen_order[]=copy(unsafe_wrap(Vector{Cint},order,2))
    Ptr{Cvoid}(UInt(gid+1))
end
function native_barrier_marker(g); Cint(-4321); end
if mode=="plain"
    pointers=W._library[].pointers
    oldsize=pointers[:waitio_pb_size]; oldcreate=pointers[:waitio_create_group]
    pointers[:waitio_pb_size]=@cfunction(two_pbs,Cint,(Ptr{Cint},))
    pointers[:waitio_create_group]=@cfunction(record_group,Ptr{Cvoid},(Cint,Ptr{Ptr{Cvoid}},Ptr{Cint}))
    group=W.Create_group(20;selection=[:all,:all],order=[1,0])
    @test seen_order[]==Cint[1,0]
    @test group.rankmap===nothing
    @test W.Comm_rank(group)==0 # native mock rank, not logical rank 1
    pointers[:waitio_pb_size]=oldsize; pointers[:waitio_create_group]=oldcreate
    oldbarrier=pointers[:waitio_mpi_barrier]
    pointers[:waitio_mpi_barrier]=@cfunction(native_barrier_marker,Cint,(Ptr{Cvoid},))
    @test_throws W.WaitIOError W.Barrier(comm) # must not silently call allreduce
    pointers[:waitio_mpi_barrier]=oldbarrier
end
for (constant,expected) in ((W.INT,101),(W.LONG,102),(W.DOUBLE,105),(W.DOUBLE_INT,106),(W.SUM,201),(W.MAXLOC,204))
    @test W.native_code(constant)==expected
end
# Exact native CHAR forwarding; portable integer math is explicitly an extension.
function char_only_allreduce(s,r,n,d,op,g)
    d==W.native_code(W.CHAR) || return Cint(-998)
    NativeMock.allreduce(s,r,n,d,op,g)
end
if mode=="plain"
    old=W._library[].pointers[:waitio_mpi_allreduce]
    W._library[].pointers[:waitio_mpi_allreduce]=@cfunction(char_only_allreduce,Cint,(Ptr{Cvoid},Ptr{Cvoid},Cint,Cint,Cint,Ptr{Cvoid}))
    for s in (UInt8[0,128,255],Int8[-128,-1,127]), op in (W.SUM,W.MIN,W.MAX)
        r=similar(s); W.Allreduce!(s,r,op,comm); @test r==s
    end
    W._library[].pointers[:waitio_mpi_allreduce]=old
end
if mode=="fixture"
    for T in (Int32,Int64,UInt8,Float32,Float64), op in (W.SUM,W.MIN,W.MAX)
        s=T[1,2,3]; r=zeros(T,3)
        W.Allreduce!(s,r,op,comm); @test r==s
        W.Reduce!(s,r,op,comm;root=0); @test r==s
        W.Scan!(s,r,op,comm); @test r==s
    end
    gathered=zeros(3); W.Gather!([1.,2.,3.],gathered,comm;root=0); @test gathered==[1,2,3]
    W.Allgather!([4.,5.,6.],gathered,comm); @test gathered==[4,5,6]
    piece=zeros(3); W.Scatter!([1.,2.,3.],piece,comm;root=0); @test piece==[1,2,3]
    sparse=fill(-99.,5); W.Allgatherv!([1.,2.],W.VBuffer(sparse,[2];displacements=[1]),comm)
    @test sparse==[-99,1,2,-99,-99]
    W.Alltoall!(W.UBuffer([7.,8.,9.],3),W.UBuffer(piece,3),comm); @test piece==[7,8,9]
    # Native waitall uses a contiguous request array: stride must match the ABI.
    request_stride=W.API.request_size()
    raw=ccall(:calloc,Ptr{Cvoid},(Csize_t,Csize_t),1,2*request_stride+16)
    for i in 1:16; unsafe_store!(Ptr{UInt8}(raw+2*request_stride),0xa5,i); end
    sbuf=Int64[1<<40]; rbuf=Int64[0]; status=Cint[-7,-7]
    GC.@preserve sbuf rbuf status begin
        @test W.API.waitio_mpi_irecv(rbuf,1,102,0,71,comm.handle,raw)==0
        @test W.API.waitio_mpi_isend(sbuf,1,102,0,71,comm.handle,raw+request_stride)==0
        @test W.API.waitio_mpi_waitall(2,raw,status)==0
    end
    @test status==[0,0] && sbuf==rbuf
    @test all(unsafe_load(Ptr{UInt8}(raw+2*request_stride),i)==0xa5 for i in 1:16)
    Base.Libc.free(raw)
    @test W.API.waitio_mpi_waitall(-1,C_NULL,C_NULL)==-10100
    datatype_size=Ref{Cint}(0); @test W.API.waitio_mpi_type_size(102,datatype_size)==0 && datatype_size[]==8
    @test W.API.waitio_mpi_type_size(-42,datatype_size)==-10100
end
if mode=="fixture"
    @test W.API.waitio_mpi_barrier(comm.handle)==0
end
W.Barrier(comm)
W.Finalize()
@test W.Finalized()
println("Compiler-free worker PASS: ",mode)
