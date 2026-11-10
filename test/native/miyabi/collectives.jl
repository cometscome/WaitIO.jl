using WaitIO, Test
const W=WaitIO
W.Init()
g=W.Comm_world(); rank=W.Comm_rank(g); nranks=W.Comm_size(g)
@testset "Miyabi Julia collectives and raw requests rank=$rank" begin
    @test nranks==2
    @test W.library_info().abi["implementation"]=="julia"
    @test W.API.request_size()==88
    for T in (Int32,Int64,UInt8,Float32,Float64), (op,expected) in ((W.SUM,3),(W.MIN,1),(W.MAX,2))
        send=T[rank+1]; recv=zeros(T,1)
        W.Allreduce!(send,recv,op,g); @test recv[1]==expected
        for root in 0:1
            W.Reduce!(send,recv,op,g;root); rank==root && (@test recv[1]==expected)
        end
    end
    for T in (Int32,Int64,UInt8,Float32,Float64)
        send=T[rank+1]; recv=T[99]
        W.Scan!(send,recv,W.SUM,g); @test recv[1]==(rank+1)*(rank+2)÷2
        recv[1]=99; W.Exscan!(send,recv,W.SUM,g); @test recv[1]==(rank==0 ? 99 : 1)
    end
    result=zeros(Int64,1)
    W.Allreduce!([(Int64(1)<<40)+rank],result,W.SUM,g)
    @test result[1]==2*(Int64(1)<<40)+1
    for root in 0:1
        sparse=fill(-99.,8); send=Float64.(rank*10 .+ (1:rank+1))
        W.Allgatherv!(send,W.VBuffer(sparse,[1,2];displacements=[1,4]),g)
        @test sparse==[-99,1,-99,-99,11,12,-99,-99]
        whole=Float64.(root*100 .+ (1:8)); piece=zeros(rank+1)
        W.Scatterv!(W.VBuffer(whole,[1,2];displacements=[1,4]),piece,g;root)
        @test piece==whole[(rank==0 ? (2:2) : (5:6))]
        back=fill(-99.,8)
        W.Gatherv!(piece,W.VBuffer(back,[1,2];displacements=[1,4]),g;root)
        rank==root && (@test back==[-99,whole[2],-99,-99,whole[5],whole[6],-99,-99])
        W.Bcast!(Float64[],g;root)
    end
    n=40000
    send=Int64[rank*1000000+dest*100000+i for dest in 0:1 for i in 0:n-1]
    recv=similar(send)
    W.Alltoall!(W.UBuffer(send,n),W.UBuffer(recv,n),g)
    @test recv==Int64[src*1000000+rank*100000+i for src in 0:1 for i in 0:n-1]
    # Two contiguous opaque requests, plus a guard after the native allocation.
    stride=W.API.request_size()
    raw=ccall(:calloc,Ptr{Cvoid},(Csize_t,Csize_t),1,2*stride+16)
    raw==C_NULL && error("request allocation failed")
    for i in 1:16; unsafe_store!(Ptr{UInt8}(raw+2*stride),0xa5,i); end
    send=Int64[(Int64(1)<<40)+rank]; recv=Int64[0]; status=Cint[-7,-7]
    GC.@preserve send recv status begin
        @test W.API.waitio_mpi_irecv(recv,1,W.native_code(W.LONG),1-rank,71,g.handle,raw)==0
        @test W.API.waitio_mpi_isend(send,1,W.native_code(W.LONG),1-rank,71,g.handle,raw+stride)==0
        @test W.API.waitio_mpi_waitall(2,raw,status)==0
    end
    @test status==[0,0] && recv==[(Int64(1)<<40)+(1-rank)]
    @test all(unsafe_load(Ptr{UInt8}(raw+2*stride),i)==0xa5 for i in 1:16)
    Libc.free(raw)
    W.Barrier(g)
end
W.Finalize()
println("extended_collectives_completed rank=$rank normal_exit=yes")
