using WaitIO, Test
const W=WaitIO

module MiyabiObjectMessages
export TrainingBatch, LinkedNode
struct TrainingBatch{T}
    label::String
    coordinates::Matrix{T}
    metadata::Dict{Symbol,Any}
end
mutable struct LinkedNode
    name::String
    next::Any
end
end
using .MiyabiObjectMessages

W.Init()
c=W.Comm_world(); rank=W.Comm_rank(c); peer=1-rank
println("objects_start rank=$rank Julia=$VERSION arch=$(Sys.ARCH)"); flush(stdout)
batch(r,n)=TrainingBatch("学習用座標・ランク$r",reshape(collect(1.0:3n).+1000r,3,n),
    Dict{Symbol,Any}(:rank=>r,:species=>["He","日本語"],:options=>(step=12,weights=[0.25,0.75])))
function check_batch(obj,r,n)
    @test obj isa TrainingBatch{Float64}
    @test obj.label=="学習用座標・ランク$r"
    @test size(obj.coordinates)==(3,n)
    @test obj.coordinates==reshape(collect(1.0:3n).+1000r,3,n)
    @test obj.metadata==Dict{Symbol,Any}(:rank=>r,:species=>["He","日本語"],:options=>(step=12,weights=[0.25,0.75]))
end
@testset "Miyabi Julia objects rank=$rank" begin
    @test W.Comm_size(c)==2
    localinfo=(version=string(VERSION),arch=string(Sys.ARCH),wordsize=Sys.WORD_SIZE)
    request=W.isend(localinfo,c;dest=peer,tag=201)
    remote=W.recv(c;source=peer,tag=201); W.Wait(request)
    println("peer_information=",remote); flush(stdout)
    @test remote.wordsize==64
    @test remote.arch!=localinfo.arch

    # Serialize immediately, then mutate the source and force GC while sending.
    obj=batch(rank,100000)
    request=W.isend(obj,c;dest=peer,tag=202)
    fill!(obj.coordinates,-99); push!(obj.metadata[:species],"changed after isend")
    GC.gc(true)
    received=W.recv(c;source=peer,tag=202); W.Wait(request)
    check_batch(received,peer,100000)
    @test W.pending_count()==0
    println("custom_batch_bidirectional_pass bytes_of_matrix=2400000"); flush(stdout)

    node=LinkedNode("rank$rank",nothing); node.next=node
    request=W.isend((node=node,empty=nothing,integers=Int64[1<<40,rank]),c;dest=peer,tag=203)
    received=W.recv(c;source=peer,tag=203); W.Wait(request)
    @test received.node isa LinkedNode
    @test received.node.name=="rank$peer"
    @test received.node.next===received.node
    @test received.empty===nothing
    @test received.integers==Int64[1<<40,peer]

    for root in (0,1)
        received=W.bcast(rank==root ? batch(root,7) : nothing,c;root)
        check_batch(received,root,7)
        gathered=W.gather(batch(rank,rank+1),c;root)
        if rank==root
            @test length(gathered)==2
            for i in 0:1; check_batch(gathered[i+1],i,i+1); end
        else
            @test gathered===nothing
        end
        println("custom_object_collectives_pass root=$root"); flush(stdout)
    end
    @test W.pending_count()==0
end
W.Barrier(c); W.Finalize(); GC.gc(true)
println("objects_completed rank=$rank normal_exit=yes")
