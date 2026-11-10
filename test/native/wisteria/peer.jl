using WaitIO, Test
const W=WaitIO

module ObjectMessages
struct Batch
    label::String
    values::Matrix{Float64}
    metadata::Dict{Symbol,Any}
end
mutable struct Node
    value::Int
    next::Any
end
end

println("peer_boot machine=$(Sys.MACHINE) pb=$(ENV["WAITIO_PBID"])"); flush(stdout)
W.Init()
println("peer_initialized pb=$(ENV["WAITIO_PBID"])"); flush(stdout)
comm=W.Comm_world(); rank=W.Comm_rank(comm); peer=1-rank
@testset "Wisteria Julia native communication rank=$rank" begin
    @test W.Comm_size(comm)==2
    @test W.PB_size()==2
    @test W.library_info().abi["recognized_profile"]=="wisteria-352"
    @test W.API.request_size()==352
    @test !W.library_info().abi["compiler_invoked"]
    @test W.library_info().source.path==abspath("config-$rank.toml")
    for T in (Int32,Int64,UInt8,Float32,Float64), n in (1,4096,131072)
        sent=T[mod(i+rank,100) for i in 1:n]; received=zeros(T,n)
        requests=[W.Irecv!(received;source=peer,tag=10),W.Isend(sent;dest=peer,tag=10)]
        GC.gc(false); W.Waitall(requests)
        @test received==T[mod(i+peer,100) for i in 1:n]
        @test W.pending_count()==0
    end
    for root in 0:1
        values=fill(rank==root ? 12.0 : 0.0,8)
        W.Bcast!(values;root); @test values==fill(12.0,8)
        result=zeros(1)
        W.Reduce!([Float64(rank+1)],result,W.SUM;root)
        rank==root && (@test result==[3.])
        W.Allreduce!([Float64(rank+1)],result,W.SUM); @test result==[3.]
        gathered=zeros(2)
        W.Gather!([Float64(rank+1)],rank==root ? gathered : nothing;root)
        rank==root && (@test gathered==[1.,2.])
        W.Scatter!(rank==root ? [4.,5.] : nothing,result;root)
        @test result==[rank+4.]
    end
    # 2.4 MB custom object, snapshot semantics, cyclic references, both roots.
    batch=ObjectMessages.Batch("rank$rank",reshape(collect(1.:300000.).+rank,3,:),
        Dict{Symbol,Any}(:rank=>rank,:labels=>["He","日本語"]))
    req=W.isend(batch;dest=peer,tag=201)
    fill!(batch.values,-1)
    received=W.recv(;source=peer,tag=201); W.Wait(req)
    @test received isa ObjectMessages.Batch
    @test received.label=="rank$peer"
    @test received.values==reshape(collect(1.:300000.).+peer,3,:)
    @test received.metadata==Dict{Symbol,Any}(:rank=>peer,:labels=>["He","日本語"])
    node=ObjectMessages.Node(rank,nothing); node.next=node
    req=W.isend(node;dest=peer,tag=202)
    received=W.recv(;source=peer,tag=202); W.Wait(req)
    @test received.value==peer && received.next===received
    for root in 0:1
        value=W.bcast(rank==root ? (root=root,values=[1.,2.]) : nothing;root)
        @test value==(root=root,values=[1.,2.])
        values=W.gather((rank=rank,values=[rank]);root)
        if rank==root
            @test values==[(rank=0,values=[0]),(rank=1,values=[1])]
        else
            @test values===nothing
        end
    end
    @test W.pending_count()==0
end
W.Barrier(); W.Finalize()
println("wisteria_native_completed rank=$rank normal_exit=yes")
