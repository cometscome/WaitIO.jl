# MPI-style in-place entry points. Overlap is implemented with an input snapshot.
Allreduce!(data,op::Op,c::Comm=Comm_world())=Allreduce!(data,data,op,c)
Reduce!(data,op::Op,c::Comm=Comm_world();root::Integer=0)=Reduce!(data,data,op,c;root)
Scan!(data,op::Op,c::Comm=Comm_world())=Scan!(data,data,op,c)
Exscan!(data,op::Op,c::Comm=Comm_world())=Exscan!(data,data,op,c)
Allreduce!(::InPlace,r,op::Op,c::Comm=Comm_world())=Allreduce!(r,r,op,c)
Scan!(::InPlace,r,op::Op,c::Comm=Comm_world())=Scan!(r,r,op,c)
Exscan!(::InPlace,r,op::Op,c::Comm=Comm_world())=Exscan!(r,r,op,c)
function Reduce!(::InPlace,r,op::Op,c::Comm=Comm_world();root::Integer=0)
    Comm_rank(c)==root || throw(ArgumentError("Reduce IN_PLACE is valid only on the root; other ranks must supply their input"))
    Reduce!(r,r,op,c;root)
end
function _local_chunk(r,c)
    b=r isa UBuffer ? Buffer(r.buffer) : Buffer(r)
    n=Comm_size(c)
    rem(b.count,n)==0 || throw(DimensionMismatch("receive count must be divisible by group size"))
    _slice(b,Comm_rank(c)*(b.count÷n),b.count÷n)
end
Allgather!(::InPlace,r,c::Comm=Comm_world())=Allgather!(_local_chunk(r,c),r,c)
function Gather!(::InPlace,r,c::Comm=Comm_world();root::Integer=0)
    Comm_rank(c)==root || throw(ArgumentError("Gather IN_PLACE is valid only on the root"))
    Gather!(_local_chunk(r,c),r,c;root)
end
Alltoall!(::InPlace,r::UBuffer,c::Comm=Comm_world())=Alltoall!(r,r,c)
function Allgatherv!(::InPlace,r::VBuffer,c::Comm=Comm_world())
    i=Comm_rank(c)+1
    Allgatherv!(_slice(Buffer(r.buffer),Int(r.displacements[i]),Int(r.counts[i])),r,c)
end

function Gatherv!(::InPlace,r::VBuffer,c::Comm=Comm_world();root::Integer=0)
    Comm_rank(c)==root || throw(ArgumentError("Gatherv IN_PLACE is valid only on the root"))
    i=Int(root)+1
    Gatherv!(_slice(Buffer(r.buffer),Int(r.displacements[i]),Int(r.counts[i])),r,c;root)
end
function Scatter!(s,::InPlace,c::Comm=Comm_world();root::Integer=0)
    Comm_rank(c)==root || throw(ArgumentError("Scatter IN_PLACE is valid only on the root"))
    Scatter!(s,_local_chunk(s,c),c;root)
    IN_PLACE
end
function Scatterv!(s::VBuffer,::InPlace,c::Comm=Comm_world();root::Integer=0)
    Comm_rank(c)==root || throw(ArgumentError("Scatterv IN_PLACE is valid only on the root"))
    i=Int(root)+1
    Scatterv!(s,_slice(Buffer(s.buffer),Int(s.displacements[i]),Int(s.counts[i])),c;root)
    IN_PLACE
end
