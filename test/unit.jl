@testset "configuration and buffers without loaded libraries" begin
    @test !W.library_info().loaded
    @test !W.Initialized()
    @test length(W.API.SIGNATURES)==80
    @test all(isdefined(W.API,k) for k in keys(W.API.SIGNATURES))
    @test_throws ArgumentError W.configure!(unknown="x")
    mktempdir() do dir
        c=W.LibraryConfig(libwaitio="/example/core.so",libwaitio_mpi="/example/collective.so",include_dir="/example/include",abi_profile="miyabi-88")
        file=joinpath(dir,"site.toml"); W.save_config(file,c)
        @test W.load_config(file).libwaitio==c.libwaitio
        @test W.load_config(file).abi_profile=="miyabi-88"
        @test haskey(W.TOML.parsefile(file), "WaitIO")
        legacy=joinpath(dir,"legacy.toml")
        write(legacy, "[WAITIO]\nlibwaitio = \"/legacy/core.so\"\nlibwaitio_mpi = \"/legacy/collective.so\"\ninclude_dir = \"/legacy/include\"\n[OtherPackage]\nenabled = true\n")
        @test W.load_config(legacy).libwaitio=="/legacy/core.so"
        withenv("WAITIO_JL_CONFIG"=>legacy) do
            @test W.configuration().libwaitio=="/legacy/core.so"
        end
        @test W._config_section(W.TOML.parsefile(legacy))["libwaitio"]=="/legacy/core.so"
        @test isempty(W._config_section(Dict("OtherPackage"=>Dict("enabled"=>true))))
        write(legacy, read(legacy,String)*"[WaitIO]\nlibwaitio = \"/new/core.so\"\n")
        @test W.load_config(legacy).libwaitio=="/new/core.so"
        W.save_config(legacy,c)
        saved=W.TOML.parsefile(legacy)
        @test !haskey(saved,"WAITIO")
        @test saved["OtherPackage"]["enabled"]
        @test W.load_config(legacy).libwaitio==c.libwaitio
        flat=joinpath(dir,"flat.toml")
        write(flat,"libwaitio = \"/flat/core.so\"\n")
        @test W.load_config(flat).libwaitio=="/flat/core.so"
        withenv("WAITIO_JL_CONFIG"=>file,"WAITIO_JL_LIBWAITIO"=>"/override/core.so") do
            @test W.configuration().libwaitio=="/override/core.so"
        end
    end
    a=reshape(collect(1.:12.),3,4)
    @test W.Buffer(a).count==12
    @test W.Buffer(@view(a[:,2:3])).count==6
    @test W.Buffer(@view(a[1,:])).wire==a[1,:]
    @test_throws ArgumentError W.Buffer(["string"])
    @test_throws BoundsError W.Buffer(a;count=13)
    @test W._nbytes(W.Buffer(a;count=2,offset=3))==16
    @test W.VBuffer(a,[2,3]).displacements==[0,2]
    @test W.UBuffer(a,2).buffer isa W.Buffer
    @test_throws ArgumentError W.UBuffer(a,-1)
    @test_throws DimensionMismatch W.VBuffer(a,[13])
    @test_throws ArgumentError W.VBuffer(a,[-1])
end
include("mock.jl")
NativeMock.install()
@testset "Julia runtime" begin
    W.Init(); comm=W.Comm_world()
    @testset "runtime and native calls" begin
        @test W.Initialized() && !W.Finalized()
        @test W.Comm_rank(comm)==0 && W.Comm_size(comm)==1
        @test W.PB_nprocs()==[1]
        @test_throws ArgumentError W.PB_hostinfo(0,1)
        @test W.Ismember(comm)
        @test W.Type_size(W.DOUBLE)==8
        @test W.Create_group(2).gid==2
        @test_throws ArgumentError W.Create_group(2)
        @test_throws ArgumentError W.Isend([1.];dest=1)
        @test_throws ArgumentError W.Isend([1.];dest=0,tag=-1)
        @test_throws ArgumentError W.Allreduce!([1.],[0.],W.MAXLOC)
        a=[1.]; @test W.Allreduce!(a,a,W.SUM)===a
        @test a==[1.]
        out=zeros(2); W.Allreduce!([2.,3.],out,W.SUM); @test out==[2.,3.]
        @test W.Barrier()===nothing
    end
    @testset "asynchronous ownership and completion" begin
        recv=zeros(2); r=W.Irecv!(recv;source=0,tag=1)
        @test !W.Test(r)
        @test_throws W.PendingRequestsError W.Finalize()
        s=W.Isend([5.,6.];dest=0,tag=1)
        @test r.native!=s.native
        GC.gc(true); W.Waitall([r,s])
        @test recv==[5.,6.]
        @test W.Test(r) && W.Test(s)
        @test W.pending_count()==0
        @test W.Testany([r,s])==(true,nothing)
        @test W.Testsome([r,s])===nothing
        @test_throws ArgumentError W.Waitall([r,r])
        a=zeros(1); b=zeros(1)
        r1=W.Irecv!(a;source=0,tag=2); s1=W.Isend([2.];dest=0,tag=2)
        r2=W.Irecv!(b;source=0,tag=3)
        for _ in 1:3; @test !W.Testall([r1,s1,r2]); end
        @test r1.state==:observed && r1.buffer!==nothing
        s2=W.Isend([3.];dest=0,tag=3)
        W.Waitall([r1,s1,r2,s2]); @test a==[2.] && b==[3.]
        out=zeros(2); W.Irecv!(out;source=0,tag=4); W.Isend([7.,8.];dest=0,tag=4)
        GC.gc(true); @test W.pending_count()==2
        W.Drain(); @test out==[7.,8.]
        a=zeros(1); r=W.Irecv!(a;source=0,tag=5); s=W.Isend([9.];dest=0,tag=5)
        @test W.Waitany([r,s]) in (1,2)
        W.Waitall([r,s]); @test a==[9.]
        a=zeros(1); r=W.Irecv!(a;source=0,tag=6); s=W.Isend([10.];dest=0,tag=6)
        @test !isempty(W.Waitsome([r,s])); W.Waitall([r,s]); @test a==[10.]
    end
    @testset "registration ownership" begin
        a=[11.,12.]; m=W.Register!(a); s=W.Isend(a;dest=0,tag=8)
        @test_throws ArgumentError W.Unregister!(m)
        out=zeros(2); r=W.Irecv!(out;source=0,tag=8)
        W.Waitall([s,r]); W.Unregister!(m)
        @test !m.active && out==a
    end
    include("objects.jl")
    W.Finalize()
    @test W.Finalized()
    @test_throws ArgumentError W.Init()
    @test_throws ArgumentError W.Comm_rank(comm)
    flag=Ref{Cint}(0)
    @test ccall(W._mpi_symbol(:MPI_Finalized),Cint,(Ref{Cint},),flag)==0
    @test flag[]==1
end
