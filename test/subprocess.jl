using Test, WaitIO, Libdl
const W=WaitIO
include("mock.jl")
NativeMock.install()
mode=ARGS[1]
if mode=="external"
    provided=Ref{Cint}(0)
    @test ccall(W._mpi_symbol(:MPI_Init_thread),Cint,
        (Ptr{Cint},Ptr{Ptr{Ptr{UInt8}}},Cint,Ref{Cint}),C_NULL,C_NULL,1,provided)==0
    W.Init(mpi=:external)
    @test !W._runtime[].owns_mpi
    W.Finalize()
    flag=Ref{Cint}(0)
    ccall(W._mpi_symbol(:MPI_Finalized),Cint,(Ref{Cint},),flag)
    @test flag[]==0
elseif mode=="error"
    W.Init()
    @test_throws W.WaitIOError W.Isend([1.];dest=0,tag=999)
    @test W.pending_count()==1
    req=only(keys(W._runtime[].requests))
    GC.gc(true)
    @test req.buffer.data==[1.] && req.native!=C_NULL && req.state==:error
    @test_throws W.WaitIOError W.Wait(req)
    @test_throws W.PendingRequestsError W.Finalize()
elseif mode=="missing_external"
    @test_throws W.WaitIOError W.Init(mpi=:external)
    @test_throws ArgumentError W.Init()
elseif mode=="object_error"
    W.Init()
    _,payloadtag=W._object_tags(99)
    NativeMock.fail_tag[]=payloadtag
    @test_throws W.WaitIOError W.isend((x=[1.,2.],);dest=0,tag=99)
    wrapper=only(q for q in keys(W._runtime[].requests) if q isa W.ObjectRequest)
    @test wrapper.state==:error
    @test_throws W.WaitIOError W.Wait(wrapper)
    @test_throws W.PendingRequestsError W.Finalize()
elseif mode=="thread"
    NativeMock.maxthreadlevel[]=1
    W.Init()
    failed=Ref(false)
    Threads.@threads :static for i in 1:Threads.nthreads()
        if Threads.threadid()!=1
            try W.Comm_rank() catch e; failed[]=e isa ArgumentError; end
        end
    end
    @test failed[]
    W.Finalize()
elseif mode=="external_worker"
    provided=Ref{Cint}(0)
    @test ccall(W._mpi_symbol(:MPI_Init_thread),Cint,
        (Ptr{Cint},Ptr{Ptr{Ptr{UInt8}}},Cint,Ref{Cint}),C_NULL,C_NULL,2,provided)==0
    W._library[].pointers[:MPI_Is_thread_main]=@cfunction(NativeMock.zero,Cint,(Ptr{Cint},))
    Threads.@threads :static for i in 1:Threads.nthreads()
        if i==2
            W.Init(mpi=:external)
            @test W.Comm_rank()==0
        end
    end
    W.Finalize() # External MPI ownership does not impose its finalization thread.
    @test !NativeMock.finalized[]
elseif mode=="serialized"
    W.Init()
    @test W._runtime[].threadlevel==2
    incoming=zeros(Int,1)
    Threads.@threads :static for i in 1:Threads.nthreads()
        if i==1
            W.Recv!(incoming;source=0,tag=123)
        else
            sleep(0.05)
            W.Send([42];dest=0,tag=123)
        end
    end
    @test incoming==[42]
    @test W.pending_count()==0
    W.Finalize()
else
    error("unknown test mode")
end
