# Included in each four-process worker. Communication crosses independent Julia
# processes; expected values below are calculated without calling WaitIO.
struct PlainRecord
    id::Int32
    value::Float64
end
Base.:(==)(a::PlainRecord,b::PlainRecord)=a.id==b.id && a.value==b.value

# A device-like array: only bulk transfers are allowed, never scalar indexing.
# This checks staging without pretending that a GPU was tested.
struct BulkArray{T} <: AbstractVector{T}
    host::Vector{T}
end
Base.size(a::BulkArray)=size(a.host)
Base.getindex(::BulkArray,i::Int)=error("scalar device access")
Base.setindex!(::BulkArray,x,i::Int)=error("scalar device access")
Base.Array(a::BulkArray)=copy(a.host)
function Base.copyto!(a::BulkArray,d::Integer,b::AbstractVector,s::Integer,n::Integer)
    copyto!(a.host,d,b,s,n); a
end

@testset "extended arrays and collectives rank=$rank" begin
    for T in (Int16,UInt16,UInt32,UInt64,Int128,Float16,ComplexF64,Bool,PlainRecord)
        make(r)=T==PlainRecord ? PlainRecord(Int32(r),r+0.5) : T==Bool ? isodd(r) : T(r+1)
        x=[make(rank)]
        W.Extensions.Bcast!(x,g;root=3); @test x==[make(3)]
        out=Vector{T}(undef,4)
        W.Extensions.Allgather!([make(rank)],out,g); @test out==[make(i) for i in 0:3]
        piece=Vector{T}(undef,1)
        W.Extensions.Scatter!([make(i) for i in 0:3],piece,g;root=2); @test piece==[make(rank)]
        sparse=fill(make(7),8)
        W.Extensions.Allgatherv!([make(rank)],W.VBuffer(sparse,ones(Int,4);displacements=[0,2,4,6]),g)
        @test sparse[1:2:7]==[make(i) for i in 0:3]
        @test sparse[2:2:8]==fill(make(7),4)
        W.Extensions.Scatterv!(W.VBuffer([make(i) for i in 0:7],ones(Int,4);displacements=[0,2,4,6]),piece,g;root=1)
        @test piece==[make(2rank)]
    end
    for T in (Int16,UInt16,UInt32,UInt64,Int128,Float16,ComplexF64)
        s=T[rank+1]; out=zeros(T,1)
        W.Extensions.Allreduce!(s,out,W.SUM,g); @test out==T[10]
        inplace=T[rank+1]
        @test W.Extensions.Allreduce!(inplace,W.SUM,g)===inplace
        @test inplace==T[10]
        W.Extensions.Scan!(s,out,W.SUM,g); @test out==T[(rank+1)*(rank+2)÷2]
    end
    for op in (W.MIN,W.MAX)
        values=UInt64[typemax(UInt64)-r for r in 0:3]
        out=UInt64[0]; W.Extensions.Allreduce!([values[rank+1]],out,op,g)
        @test out==[op===W.MIN ? minimum(values) : maximum(values)]
    end
    out=UInt64[0]
    W.Extensions.Allreduce!(UInt64[typemax(UInt64)],out,W.SUM,g)
    @test out==UInt64[typemax(UInt64)-3]
    loc=W.ValueLoc(Float64(rank%2),Int32(10-rank))
    for (op,answer) in ((W.MAXLOC,W.ValueLoc(1.,Int32(7))),(W.MINLOC,W.ValueLoc(0.,Int32(8))))
        output=[loc]; W.Extensions.Allreduce!([loc],output,op,g)
        @test output[1].value==answer.value && output[1].location==answer.location
    end
    tuples=[(Float64(rank%2),Int32(10-rank))]
    W.Extensions.Allreduce!(W.IN_PLACE,tuples,W.MAXLOC,g); @test tuples==[(1.,Int32(7))]
    custom=PlainRecord[PlainRecord(rank,1.)]
    W.Extensions.Allreduce!(custom,W.Op((a,b)->PlainRecord(a.id+b.id,a.value+b.value)),g)
    @test custom==[PlainRecord(6,4.)]

    # Noncontiguous send/receive and preservation of unrelated destination data.
    a=reshape(Float64.(1:12).+rank*100,3,4); b=fill(-99.,3,4)
    dest=mod(rank+1,4); source=mod(rank-1,4)
    rq=W.Irecv!(@view(b[2,:]),g;source,tag=400)
    sq=W.Isend(@view(a[1,:]),g;dest,tag=400)
    b[1,:].=77
    W.Waitall([rq,sq])
    @test b[2,:]==Float64[1,4,7,10].+source*100
    @test b[1,:]==fill(77.,4) && b[3,:]==fill(-99.,4)
    viewdata=@view(a[2,:]); W.Extensions.Allreduce!(viewdata,viewdata,W.SUM,g)
    @test a[2,:]==Float64[608,620,632,644]

    device=BulkArray(Float64[rank+1,rank+2]); result=BulkArray(zeros(2))
    W.Extensions.Allreduce!(device,result,W.SUM,g); @test result.host==[10,14]
    rq=W.Irecv!(result,g;source,tag=UInt64(1)<<63)
    sq=W.Isend(device,g;dest,tag=UInt64(1)<<63)
    W.Waitall([rq,sq]); @test result.host==[source+1,source+2]

    gathered=zeros(Int16,4); gathered[rank+1]=rank+1
    W.Extensions.Allgather!(W.IN_PLACE,gathered,g); @test gathered==Int16[1,2,3,4]
    exchange=Int32[100rank+peer for peer in 0:3]
    W.Extensions.Alltoall!(W.IN_PLACE,W.UBuffer(exchange,1),g)
    @test exchange==Int32[100peer+rank for peer in 0:3]
end

@testset "reordered PB groups rank=$rank" begin
    c=W.Extensions.Create_group(15;order=[3,1,0,2])
    logical=findfirst(==(rank),[3,1,0,2])-1
    @test W.Comm_rank(c)==logical
    @test W.Comm_size(c)==4
    W.Extensions.Barrier(g)
    peer=mod(logical+1,4); previous=mod(logical-1,4)
    received=Int32[-1]
    rq=W.Irecv!(received,c;source=previous,tag=55)
    sq=W.Isend(Int32[logical],c;dest=peer,tag=55)
    W.Waitall([rq,sq]); @test received==[previous]
    x=Int32[logical]; W.Extensions.Bcast!(x,c;root=2); @test x==[2]
    x=zeros(Int32,4); W.Extensions.Allgather!(Int32[logical],x,c); @test x==[0,1,2,3]
    out=Int32[0]; W.Extensions.Scan!(Int32[logical+1],out,W.SUM,c)
    @test out==[(logical+1)*(logical+2)÷2]
    out[1]=-99; W.Extensions.Exscan!(Int32[logical+1],out,W.SUM,c)
    @test out==[logical==0 ? -99 : logical*(logical+1)÷2]
    W.Extensions.Reduce!(Int32[logical+1],out,W.SUM,c;root=3)
    logical==3 && (@test out==[10])
    W.Extensions.Scatter!(Int32[10,11,12,13],out,c;root=1); @test out==[10+logical]
    sparse=fill(Int16(-1),8)
    W.Extensions.Allgatherv!(Int16[logical],W.VBuffer(sparse,ones(Int,4);displacements=[0,2,4,6]),c)
    @test sparse==Int16[0,-1,1,-1,2,-1,3,-1]
    W.Extensions.Scatterv!(W.VBuffer(Int32.(10:17),ones(Int,4);displacements=[0,2,4,6]),out,c;root=2)
    @test out==[10+2logical]
    exchange=Int32[100logical+peer for peer in 0:3]
    W.Extensions.Alltoall!(W.IN_PLACE,W.UBuffer(exchange,1),c)
    @test exchange==Int32[100peer+logical for peer in 0:3]
    W.Extensions.Barrier(c)
end

@testset "in-place roots and refreshed staging rank=$rank" begin
    root=2
    for T in (Int16,PlainRecord)
        make(i)=T==PlainRecord ? PlainRecord(Int32(i),i+0.5) : T(i)
        data=[make(i) for i in 0:3]
        recv=Vector{T}(undef,1)
        W.Extensions.Scatter!(rank==root ? data : nothing,rank==root ? W.IN_PLACE : recv,g;root)
        @test rank==root ? data==[make(i) for i in 0:3] : recv==[make(rank)]
        var=rank==root ? W.VBuffer(data,ones(Int,4)) : nothing
        W.Extensions.Scatterv!(var,rank==root ? W.IN_PLACE : recv,g;root)
        @test rank==root ? data==[make(i) for i in 0:3] : recv==[make(rank)]
        out=rank==root ? [make(7) for i in 1:4] : nothing
        rank==root && (out[root+1]=make(root))
        W.Extensions.Gather!(rank==root ? W.IN_PLACE : [make(rank)],out,g;root)
        rank==root && (@test out==[make(i) for i in 0:3])
        var=rank==root ? W.VBuffer(out,ones(Int,4)) : nothing
        W.Extensions.Gatherv!(rank==root ? W.IN_PLACE : [make(rank)],var,g;root)
        rank==root && (@test out==[make(i) for i in 0:3])
    end
    device=BulkArray(zeros(Int32,4)); uniform=W.UBuffer(device,1)
    device.host.=Int32[10rank+peer for peer in 0:3]
    W.Extensions.Alltoall!(W.IN_PLACE,uniform,g)
    @test device.host==Int32[10peer+rank for peer in 0:3]
    device.host.=0; device.host[rank+1]=rank+1
    W.Extensions.Allgather!(W.IN_PLACE,uniform,g); @test device.host==[1,2,3,4]
    variable=W.VBuffer(device,ones(Int,4))
    device.host.=0; device.host[rank+1]=rank+5
    W.Extensions.Allgatherv!(W.IN_PLACE,variable,g); @test device.host==[5,6,7,8]
end
