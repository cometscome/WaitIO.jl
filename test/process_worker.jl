using WaitIO, Test
const W=WaitIO
include("process_transport.jl")
ProcessTransport.install(ARGS[1],parse(Int,ARGS[2]))
W.check_library(); W.Init()
g=W.Comm_world(); rank=W.Comm_rank(g); nranks=W.Comm_size(g)
@test nranks==4
@test !W.library_info().abi["compiler_invoked"]
@testset "Julia socket algorithms on four Julia processes" begin
    for T in (Int32,Int64,Float32,Float64), (op,expected) in ((W.SUM,10),(W.MIN,1),(W.MAX,4))
        s=T[rank+1]; r=zeros(T,1)
        W.Allreduce!(s,r,op,g); @test r[1]==expected
        for root in 0:3
            W.Reduce!(s,r,op,g;root); rank==root && (@test r[1]==expected)
        end
    end
    for T in (Int32,Int64,Float32,Float64)
        s=T[rank+1]; r=T[99]
        W.Scan!(s,r,W.SUM,g); @test r[1]==(rank+1)*(rank+2)÷2
        r[1]=99; W.Exscan!(s,r,W.SUM,g); @test r[1]==(rank==0 ? 99 : rank*(rank+1)÷2)
    end
    r=zeros(Int64,1) # Values beyond 32 bits.
    W.Allreduce!([(Int64(1)<<40)+rank],r,W.SUM,g); @test r[1]==4*(Int64(1)<<40)+6
    counts=[1,2,3,4]; displs=[1,4,8,13]
    for root in 0:3
        s=Float64[rank+1,rank+2,rank+3,rank+4]
        r=zeros(4); W.Gather!([s[1]],r,g;root); rank==root && (@test r==[1,2,3,4])
        recv=zeros(1); W.Scatter!(s,recv,g;root); @test recv[1]==root+rank+1
        sparse=fill(-99.,20)
        W.Allgatherv!(s[1:rank+1],W.VBuffer(sparse,counts;displacements=displs),g)
        for i in 0:3
            @test sparse[displs[i+1]+1:displs[i+1]+counts[i+1]]==collect(Float64(i+1):Float64(i+counts[i+1]))
        end
        @test sparse[[1,3,8,13,20]]==fill(-99.,5)
        dense=[0,1,3,6]; whole=Float64.(root*100 .+ (0:15)); piece=zeros(rank+1)
        W.Scatterv!(W.VBuffer(whole,counts;displacements=dense),piece,g;root)
        @test piece==Float64.(root*100 .+ (dense[rank+1]:dense[rank+1]+rank))
        back=fill(-99.,16); W.Gatherv!(piece,W.VBuffer(back,counts;displacements=dense),g;root)
        rank==root && (@test back[1:10]==Float64.(root*100 .+ (0:9)))
        empty=Float64[]; W.Bcast!(empty,g;root)
    end
    n=40000
    send=Int64[rank*1000000+dest*100000+i for dest in 0:3 for i in 0:n-1]
    recv=similar(send)
    W.Alltoall!(W.UBuffer(send,n),W.UBuffer(recv,n),g)
    @test recv==Int64[src*1000000+rank*100000+i for src in 0:3 for i in 0:n-1]
    W.Barrier(g)
end
include("byte_reductions.jl")
include("extended_arrays.jl")
include("object_types.jl")
using .TestMessages
@testset "custom objects between Julia processes" begin
    value=TrainingBatch("rank-$rank",fill(Float64(rank),3,2),Dict{Symbol,Any}(:rank=>rank))
    req=W.isend(value;dest=mod(rank+1,4),tag=100)
    GC.gc(true)
    result=W.recv(;source=mod(rank-1,4),tag=100)
    W.Wait(req)
    previous=mod(rank-1,4)
    @test result isa TrainingBatch{Float64}
    @test result.label=="rank-$previous"
    @test result.coordinates==fill(Float64(previous),3,2)
    @test result.metadata[:rank]==previous
    @test W.pending_count()==0
end
@testset "queued objects and object collectives" begin
    peer=mod(rank+1,4); previous=mod(rank-1,4)
    queued=[W.isend((rank=rank,sequence=i);dest=peer,tag=typemax(Culong)) for i in 1:8]
    for i in 1:8
        @test W.recv(;source=previous,tag=typemax(Culong))==(rank=previous,sequence=i)
    end
    W.Waitall(queued)
    @test W.bcast(rank==2 ? (values=[1,2,3],) : nothing,g;root=2)==(values=[1,2,3],)
    got=W.gather((rank=rank,values=fill(rank,rank+1)),g;root=3)
    @test rank==3 ? got==[(rank=i,values=fill(i,i+1)) for i in 0:3] : got===nothing
end

W.Finalize()
println("Compiler-free four-rank oracle PASS rank=",rank)
