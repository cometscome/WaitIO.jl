using WaitIO, Test, TOML
const W = WaitIO
mark(s) = (println(s); flush(stdout))
const caps_g=TOML.parsefile("capabilities-g.toml")
const caps_c=TOML.parsefile("capabilities-c.toml")
function available(name)
    ok=get(caps_g,name,false) && get(caps_c,name,false)
    ok || mark("UNSUPPORTED $name: missing in installed Miyabi WaitIO; not a communication pass")
    ok
end
W.Init()
c = W.Comm_world()
r = W.Comm_rank(c)
peer = 1-r
mark("initialized rank=$r Julia=$VERSION arch=$(Sys.ARCH) request_bytes=$(W.library_info().abi["request_bytes"])")
@testset "Miyabi G/C WaitIO.jl real communication rank=$r" begin
    @test W.Comm_size(c) == 2
    @test W.PB_rank() == r
    @test W.PB_size() == 2
    @test W.PB_nprocs() == [1,1]
    @test W.Ismember(c)
    @testset "typed array roundtrips" begin
        for T in (Int32, Int64, Float32, Float64, UInt8)
            for n in (1,64,4096,131072)
                tx = T[mod(i+17r,100) for i in 1:n]
                rx = zeros(T,n)
                expected = T[mod(i+17peer,100) for i in 1:n]
                reqs = [W.Irecv!(rx,c;source=peer,tag=10), W.Isend(tx,c;dest=peer,tag=10)]
                W.Waitall(reqs)
                @test rx == expected
                @test W.pending_count() == 0
            end
            mark("typed_arrays_PASS rank=$r type=$T")
        end
    end
    @testset "multiple requests and GC ownership" begin
        tx = [fill(Float64(100r+i),1024) for i in 1:8]
        rx = [zeros(1024) for _ in 1:8]
        for i in 1:8
            W.Irecv!(rx[i],c;source=peer,tag=20+i)
            W.Isend(tx[i],c;dest=peer,tag=20+i)
        end
        GC.gc(true)
        W.Drain()
        for i in 1:8
            @test rx[i] == fill(Float64(100peer+i),1024)
        end
        @test W.pending_count() == 0
    end
    mark("async_GC_PASS rank=$r")
    @testset "collectives both roots" begin
        for root in (0,1)
            x = [Float64(r+1)]
            recv = zeros(1)
            b = [r == root ? 42.0 : 0.0]
            W.Barrier(c)
            W.Bcast!(b,c;root); @test b == [42.]
            W.Reduce!(x,r==root ? recv : nothing,W.SUM,c;root)
            r==root && (@test recv == [3.])
            all = zeros(2)
            if available("waitio_mpi_gather")
                W.Gather!(x,r==root ? all : nothing,c;root)
                r==root && (@test all == [1.,2.])
            else
                @test_skip W.Gather!(x,all,c;root)
            end
            if available("waitio_mpi_scatter")
                W.Scatter!(r==root ? [10.,20.] : nothing,recv,c;root)
                @test recv == [10.0*(r+1)]
            else
                @test_skip W.Scatter!([10.,20.],recv,c;root)
            end
            v = r==0 ? [1.] : [2.,3.]
            variable = zeros(3)
            W.Gatherv!(v,r==root ? W.VBuffer(variable,[1,2]) : nothing,c;root)
            r==root && (@test variable == [1.,2.,3.])
            W.Scatterv!(r==root ? W.VBuffer([10.,20.,30.],[1,2]) : nothing,v,c;root)
            @test v == (r==0 ? [10.] : [20.,30.])
            mark("root_collectives_PASS rank=$r root=$root")
        end
        x=[Float64(r+1)]; recv=zeros(1); all=zeros(2)
        W.Allreduce!(x,recv,W.SUM,c); @test recv == [3.]
        if available("waitio_mpi_allgather")
            W.Allgather!(x,all,c); @test all == [1.,2.]
        else
            @test_skip W.Allgather!(x,all,c)
        end
        variable=zeros(3)
        if available("waitio_mpi_allgatherv")
            W.Allgatherv!(r==0 ? [1.] : [2.,3.],W.VBuffer(variable,[1,2]),c)
            @test variable == [1.,2.,3.]
        else
            @test_skip W.Allgatherv!(x,W.VBuffer(variable,[1,2]),c)
        end
        if available("waitio_mpi_scan")
            W.Scan!(x,recv,W.SUM,c); @test recv == [r==0 ? 1. : 3.]
        else
            @test_skip W.Scan!(x,recv,W.SUM,c)
        end
        if available("waitio_mpi_exscan")
            W.Exscan!(x,recv,W.SUM,c); r==1 && (@test recv == [1.])
        else
            @test_skip W.Exscan!(x,recv,W.SUM,c)
        end
        if available("waitio_mpi_alltoall")
            W.Alltoall!(W.UBuffer(r==0 ? [10.,20.] : [30.,40.],1),W.UBuffer(all,1),c)
            @test all == (r==0 ? [10.,30.] : [20.,40.])
        else
            @test_skip W.Alltoall!(W.UBuffer(x,1),W.UBuffer(all,1),c)
        end
    end
    mark("collectives_PASS rank=$r")
    second=W.Create_group(2)
    @test W.Comm_rank(second)==r
    @test W.Comm_size(second)==2
    W.Barrier(c); W.Barrier(second)
    @test W.pending_count()==0
    W.Finalize()
    @test W.Finalized()
end
GC.gc(true)
mark("julia_real_communication_PASS normal_exit=yes rank=$r")
