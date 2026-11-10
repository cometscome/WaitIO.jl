include("object_types.jl")
using .TestMessages

@testset "Julia object serialization" begin
    obj=TrainingBatch("構造データ",reshape(collect(1.:6.),3,2),Dict(:iteration=>3,:species=>["H","O"]))
    req=W.isend(obj;dest=0,tag=21)
    @test req isa W.ObjectRequest
    queued=W.isend((sequence=2,);dest=0,tag=21)
    obj.coordinates[1]=99 # Serialized data was copied before isend returned.
    GC.gc(true)
    got=W.recv(;source=0,tag=21)
    @test W.recv(;source=0,tag=21)==(sequence=2,)
    W.Waitall([req,queued])
    @test got isa TrainingBatch{Float64}
    @test got.label=="構造データ" && got.coordinates[1]==1
    @test got.metadata==obj.metadata
    @test W.Test(req)
    @test W.pending_count()==0
    cyclic=Dict{Symbol,Any}(); cyclic[:self]=cyclic
    r1=W.isend(cyclic;dest=0,tag=22); r2=W.isend(nothing;dest=0,tag=23)
    c=W.recv(;source=0,tag=22); @test c[:self]===c
    @test W.recv(;source=0,tag=23)===nothing
    W.Waitall([r1,r2])
    @test W.Testall([r1,r2])
    W.isend((message="dropped request",values=[1,2,3]);dest=0,tag=24)
    GC.gc(true)
    @test W.recv(;source=0,tag=24).values==[1,2,3]
    W.Drain(); @test W.pending_count()==0
    @test_throws ArgumentError W.isend(obj;dest=0,maxbytes=1)
    @test_throws ArgumentError W.isend(obj;dest=0,tag=-1)
    raw=zeros(1); r=W.Irecv!(raw;source=0,tag=typemax(Culong))
    s=W.Isend([1.];dest=0,tag=typemax(Culong))
    W.Waitall([s,r]); @test raw==[1.]
    large_tag=W.isend((value=42,);dest=0,tag=typemax(Culong))
    @test W.recv(;source=0,tag=typemax(Culong))==(value=42,)
    W.Wait(large_tag)
    @test W._object_length(W._object_header(3_000_000_000),W.DEFAULT_MAX_OBJECT_BYTES)==3_000_000_000
    @test_throws ArgumentError W._object_length(zeros(UInt8,16),1024)
    @test_throws ArgumentError W._object_length(W._object_header(1025),1024)
    @test_throws ArgumentError W._object_length(W._object_header(0),1024)
    @test W._object_length(W._object_header(1024),1024)==1024
end
