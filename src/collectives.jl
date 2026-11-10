"Call the installed native WaitIO barrier with its native semantics."
@locked function Barrier(c::Comm=Comm_world())
    _native_collective_comm(c)
    _check(:waitio_mpi_barrier,API.waitio_mpi_barrier(_comm(c)))
    nothing
end
function _native_collective_comm(c)
    _reordered(c) && throw(ArgumentError("this is an Extensions logical-rank communicator; use WaitIO.Extensions collectives with its agreed protocol"))
    _comm(c)
end

@locked function Bcast!(data,c::Comm=Comm_world();root::Integer=0)
    handle=_native_collective_comm(c); rank=_rank(c,root); b=Buffer(data); count,dt=_typed(b)
    code=GC.@preserve b API.waitio_mpi_bcast(_pointer(b),count,dt,rank,handle)
    _check(:waitio_mpi_bcast,code)
    _writeback!(b)
    data
end
@locked function _reduction(send,recv,op::Op,c,kind,root)
    handle=_native_collective_comm(c); s=Buffer(send)
    native=Datatype(eltype(s)) # Reductions need a native datatype, not a byte fallback.
    Type_size(native)==sizeof(eltype(s)) || throw(ArgumentError("native reduction datatype size differs from the Julia element layout"))
    _count(_nbytes(s)); count,dt=_count(s.count),_code(native)
    _validate_reduction(eltype(s),op)
    r=recv===nothing ? nothing : Buffer(recv)
    needed=kind!=:reduce || Comm_rank(c)==root
    needed && r===nothing && throw(ArgumentError("receive buffer required on this rank"))
    # Native N-nary reduction uses recvbuf as working storage on non-root ranks too.
    r===nothing && (r=Buffer(Vector{eltype(s)}(undef,s.count)))
    if r!==nothing
        _same_type(s,r); r.count==s.count || throw(DimensionMismatch("reduction counts differ"))
        s=_input(s,r)
    end
    rank=kind==:reduce ? _rank(c,root) : Cint(0)
    rp=r===nothing ? C_NULL : _pointer(r)
    code=GC.@preserve s r begin
        kind==:reduce ? API.waitio_mpi_reduce(_pointer(s),rp,count,dt,_code(op),rank,handle) :
        kind==:allreduce ? API.waitio_mpi_allreduce(_pointer(s),rp,count,dt,_code(op),handle) :
        kind==:scan ? API.waitio_mpi_scan(_pointer(s),rp,count,dt,_code(op),handle) :
        API.waitio_mpi_exscan(_pointer(s),rp,count,dt,_code(op),handle)
    end
    _check(Symbol(:waitio_mpi_,kind),code)
    needed && _writeback!(r)
    recv
end
Reduce!(s,r,op::Op,c::Comm=Comm_world();root::Integer=0) = _reduction(s,r,op,c,:reduce,root)
Allreduce!(s,r,op::Op,c::Comm=Comm_world()) = _reduction(s,r,op,c,:allreduce,0)
Scan!(s,r,op::Op,c::Comm=Comm_world()) = _reduction(s,r,op,c,:scan,0)
Exscan!(s,r,op::Op,c::Comm=Comm_world()) = _reduction(s,r,op,c,:exscan,0)

@locked function _gather(send,recv,c,root,all)
    h=_native_collective_comm(c); s=Buffer(send); count,dt=_typed(s); n=Comm_size(c)
    rootrank=all ? Cint(0) : _rank(c,root)
    needed=all || Comm_rank(c)==root
    r=recv===nothing ? nothing : recv isa UBuffer ? Buffer(recv.buffer) : Buffer(recv)
    needed && r===nothing && throw(ArgumentError("receive buffer required"))
    # N-nary gather uses a full receive workspace on every rank.
    r===nothing && (r=Buffer(Vector{eltype(s)}(undef,Base.checked_mul(n,s.count))))
    if r!==nothing
        _same_type(s,r)
        _typed(r)
        r.count==Base.checked_mul(n,s.count) || throw(DimensionMismatch("gather receive count must be nranks * sendcount"))
        recv isa UBuffer && recv.count!=s.count && throw(DimensionMismatch("uniform count mismatch"))
        s=_input(s,r)
    end
    rp=r===nothing ? C_NULL : _pointer(r)
    code=GC.@preserve s r begin
        all ? API.waitio_mpi_allgather(_pointer(s),rp,count,dt,h) : API.waitio_mpi_gather(_pointer(s),rp,count,dt,rootrank,h)
    end
    _check(all ? :waitio_mpi_allgather : :waitio_mpi_gather,code)
    needed && _writeback!(r)
    recv
end
Gather!(s,r,c::Comm=Comm_world();root::Integer=0) = _gather(s,r,c,root,false)
Allgather!(s,r,c::Comm=Comm_world()) = _gather(s,r,c,0,true)

@locked function Scatter!(send,recv,c::Comm=Comm_world();root::Integer=0)
    h=_native_collective_comm(c); rootrank=_rank(c,root); r=Buffer(recv); count,dt=_typed(r)
    s=send===nothing ? nothing : send isa UBuffer ? Buffer(send.buffer) : Buffer(send)
    Comm_rank(c)==root && s===nothing && throw(ArgumentError("root requires a send buffer"))
    s===nothing && (s=Buffer(Vector{eltype(r)}(undef,Base.checked_mul(Comm_size(c),r.count))))
    if s!==nothing
        _same_type(s,r)
        _typed(s)
        s.count==Base.checked_mul(Comm_size(c),r.count) || throw(DimensionMismatch("scatter send count mismatch"))
        send isa UBuffer && send.count!=r.count && throw(DimensionMismatch("uniform count mismatch"))
        s=_input(s,r)
    end
    sp=s===nothing ? C_NULL : _pointer(s)
    code=GC.@preserve s r API.waitio_mpi_scatter(sp,count,dt,_pointer(r),count,dt,rootrank,h)
    _check(:waitio_mpi_scatter,code)
    _writeback!(r)
    recv
end

function _variable(v::VBuffer,c)
    length(v.counts)==Comm_size(c) || throw(DimensionMismatch("one count per rank required"))
    # Revalidate mutable counts and displacements before exposing them to C.
    VBuffer(v.buffer,v.counts;displacements=v.displacements)
    _typed(v.buffer)
    v
end
@locked function _gatherv(send,recv,c,root,all)
    h=_native_collective_comm(c); s=Buffer(send); count,dt=_typed(s)
    rootrank=all ? Cint(0) : _rank(c,root)
    needed=all || Comm_rank(c)==root
    result=recv
    if !needed && recv===nothing
        # C reads recvcounts[rank] even on a non-root sender.
        counts=zeros(Cint,Comm_size(c)); counts[Comm_rank(c)+1]=s.count
        recv=VBuffer(Vector{eltype(s)}(undef,max(s.count,8)),counts;displacements=zeros(Cint,length(counts)))
    end
    recv isa VBuffer || throw(ArgumentError("receive buffer must be a VBuffer"))
    _variable(recv,c); _same_type(s,recv.buffer)
    recv.counts[Comm_rank(c)+1]==s.count || throw(DimensionMismatch("local send count mismatch"))
    s=_input(s,recv.buffer)
    recv===nothing || recv isa VBuffer || throw(ArgumentError("expected VBuffer or nothing"))
    rp=recv===nothing ? C_NULL : _pointer(recv.buffer)
    counts=_wirecounts(recv); displs=_wiredisplacements(recv)
    code=GC.@preserve s recv counts displs begin
        all ? API.waitio_mpi_allgatherv(_pointer(s),count,dt,rp,counts,displs,dt,h) :
              API.waitio_mpi_gatherv(_pointer(s),count,dt,rp,counts,displs,dt,rootrank,h)
    end
    _check(all ? :waitio_mpi_allgatherv : :waitio_mpi_gatherv,code)
    needed && _writeback!(recv.buffer)
    result
end
Gatherv!(s,r,c::Comm=Comm_world();root::Integer=0) = _gatherv(s,r,c,root,false)
Allgatherv!(s,r,c::Comm=Comm_world()) = _gatherv(s,r,c,0,true)
@locked function Scatterv!(send,recv,c::Comm=Comm_world();root::Integer=0)
    h=_native_collective_comm(c); rootrank=_rank(c,root); r=Buffer(recv); count,dt=_typed(r)
    if Comm_rank(c)!=root && send===nothing
        # C reads sendcounts[rank] even on a non-root receiver.
        counts=zeros(Cint,Comm_size(c)); counts[Comm_rank(c)+1]=r.count
        send=VBuffer(Vector{eltype(r)}(undef,max(r.count,8)),counts;displacements=zeros(Cint,length(counts)))
    end
    send isa VBuffer || throw(ArgumentError("send buffer must be a VBuffer"))
    _variable(send,c); _same_type(send.buffer,r)
    send.counts[Comm_rank(c)+1]==r.count || throw(DimensionMismatch("local receive count mismatch"))
    send=VBuffer(_input(send.buffer,r),send.counts;displacements=send.displacements)
    send===nothing || send isa VBuffer || throw(ArgumentError("expected VBuffer or nothing"))
    sp=send===nothing ? C_NULL : _pointer(send.buffer)
    counts=_wirecounts(send); displs=_wiredisplacements(send)
    code=GC.@preserve send r counts displs API.waitio_mpi_scatterv(sp,counts,displs,dt,_pointer(r),count,dt,rootrank,h)
    _check(:waitio_mpi_scatterv,code)
    _writeback!(r)
    recv
end
@locked function Alltoall!(send::UBuffer,recv::UBuffer,c::Comm=Comm_world())
    h=_native_collective_comm(c); n=Comm_size(c); s=Buffer(send.buffer); r=Buffer(recv.buffer)
    _same_type(s,r); _,dt=_typed(s); _typed(r)
    send.count==recv.count || throw(DimensionMismatch("per-rank counts must match"))
    s.count==Base.checked_mul(n,send.count) && r.count==Base.checked_mul(n,recv.count) ||
        throw(DimensionMismatch("alltoall buffer sizes must be nranks * count"))
    s=_input(s,r)
    code=GC.@preserve s r API.waitio_mpi_alltoall(_pointer(s),_count(Base.checked_mul(send.count,_wireunits(s))),dt,_pointer(r),_count(Base.checked_mul(recv.count,_wireunits(r))),dt,h)
    _check(:waitio_mpi_alltoall,code)
    _writeback!(r)
    recv
end
