# Run one Julia process in each of two PBs, with the site's MPI launcher and
# WAITIO_JL_CONFIG. This tests high-level extensions, not native C equivalence.
using WaitIO, Test
const W=WaitIO
W.Init()
world=W.Comm_world(); rank=W.Comm_rank(world); peer=1-rank
@test W.Comm_size(world)==2
@test W.PB_nprocs()==[1,1]
@testset "extended two-PB communication" begin
    for T in (Int8,UInt8,Int16,UInt16,UInt32,UInt64,Int128,Float16,ComplexF64)
        a=T[rank+1,rank+2]
        W.Extensions.Allreduce!(W.IN_PLACE,a,W.SUM,world)
        @test a==T[3,5]
    end
    loc=[W.ValueLoc(2.,Int32(1-rank))]
    W.Extensions.Allreduce!(loc,W.MAXLOC,world)
    @test loc[1].value==2. && loc[1].location==0
    a=reshape(Int64.(1:12).+100rank,3,4); b=fill(Int64(-1),3,4)
    requests=[W.Irecv!(@view(b[2,:]),world;source=peer,tag=typemax(Culong)),
              W.Isend(@view(a[1,:]),world;dest=peer,tag=typemax(Culong))]
    W.Waitall(requests)
    @test b[2,:]==Int64[1,4,7,10].+100peer
    @test all(==(-1),b[[1,3],:])
    queued=[W.isend((rank=rank,sequence=i);dest=peer,tag=70) for i in 1:4]
    for i in 1:4
        @test W.recv(;source=peer,tag=70)==(rank=peer,sequence=i)
    end
    W.Waitall(queued)
    @test W.bcast(rank==1 ? (a=[3,4],) : nothing;root=1)==(a=[3,4],)
    gathered=W.gather((rank=rank,);root=1)
    @test rank==1 ? gathered==[(rank=0,),(rank=1,)] : gathered===nothing
    reversed=W.Extensions.Create_group(14;order=[1,0]); W.Extensions.Barrier(world)
    logical=1-rank
    @test W.Comm_rank(reversed)==logical
    a=Int64[logical+1]; W.Extensions.Scan!(a,W.SUM,reversed)
    @test a==[logical==0 ? 1 : 3]
    a=zeros(Int64,2); W.Extensions.Allgather!(Int64[logical],a,reversed)
    @test a==[0,1]
    W.Extensions.Barrier(reversed)
end
W.Finalize()
println("two-PB extensions PASS rank=",rank)
