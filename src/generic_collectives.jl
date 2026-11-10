# Portable reductions for Julia types/operations absent from the C datatype
# table, and logical-rank collectives for reordered groups. These protocols use
# core WaitIO byte transfers; native C algorithms remain the canonical fast path.
const _GENERIC_TAG=Culong(0x574a4c10)
function _combine(op,a,b)
    op.name==:SUM && return a+b
    op.name==:MIN && return min(a,b)
    op.name==:MAX && return max(a,b)
    op.name==:CUSTOM && return op.function_(a,b)
    av,ai=_locparts(a); bv,bi=_locparts(b)
    av==bv && return ai<=bi ? a : b
    op.name==:MAXLOC ? (av>bv ? a : b) : (av<bv ? a : b)
end
function _fold!(acc,part,op)
    for i in eachindex(acc,part)
        acc[i]=_combine(op,acc[i],part[i])
    end
    acc
end
_slice(b::Buffer,offset,count)=Buffer(b.wire;offset=b.offset+offset,count)
function _store!(b::Buffer,values)
    copyto!(vec(b.wire),b.offset+1,values,1,b.count)
    _writeback!(b)
end
function _generic_reduction(s,r,result,op,c,kind,root)
    rank=Comm_rank(c); n=Comm_size(c)
    mine=copy(vec(s.wire)[s.offset+1:s.offset+s.count])
    acc=similar(mine)
    if kind in (:scan,:exscan)
        if rank==0
            copyto!(acc,mine)
        else
            Recv!(acc,c;source=rank-1,tag=_GENERIC_TAG)
            kind==:exscan && _store!(r,acc)
            _fold!(acc,mine,op)
        end
        kind==:scan && _store!(r,acc)
        rank+1<n && Send(acc,c;dest=rank+1,tag=_GENERIC_TAG)
    else
        target=kind==:reduce ? root : 0
        if rank==target
            part=similar(mine)
            for peer in 0:n-1
                if peer==rank
                    copyto!(part,mine)
                else
                    Recv!(part,c;source=peer,tag=_GENERIC_TAG)
                end
                peer==0 ? copyto!(acc,part) : _fold!(acc,part,op)
            end
        else
            Send(mine,c;dest=target,tag=_GENERIC_TAG)
        end
        kind==:allreduce && Bcast!(acc,c;root=target)
        (kind==:allreduce || rank==target) && _store!(r,acc)
    end
    result
end

function _ordered_bcast!(b,result,c,root)
    if Comm_rank(c)==root
        for peer in 0:Comm_size(c)-1
            peer==root || Send(b,c;dest=peer,tag=_GENERIC_TAG+1)
        end
    else
        Recv!(b,c;source=root,tag=_GENERIC_TAG+1)
    end
    _writeback!(b)
    result
end
function _ordered_gather!(s,r,result,c,root,all)
    target=all ? 0 : root
    if Comm_rank(c)==target
        for peer in 0:Comm_size(c)-1
            chunk=_slice(r,peer*s.count,s.count)
            peer==target ? _store!(chunk,vec(s.wire)[s.offset+1:s.offset+s.count]) :
                Recv!(chunk,c;source=peer,tag=_GENERIC_TAG+2)
        end
        _writeback!(r)
    else
        Send(s,c;dest=target,tag=_GENERIC_TAG+2)
    end
    all && Bcast!(r,c;root=target)
    result
end
function _ordered_scatter!(s,r,result,c,root)
    if Comm_rank(c)==root
        for peer in 0:Comm_size(c)-1
            chunk=_slice(s,peer*r.count,r.count)
            peer==root ? _store!(r,vec(chunk.wire)[chunk.offset+1:chunk.offset+chunk.count]) :
                Send(chunk,c;dest=peer,tag=_GENERIC_TAG+3)
        end
    else
        Recv!(r,c;source=root,tag=_GENERIC_TAG+3)
    end
    result
end
function _ordered_gatherv!(s,v,result,c,root,all)
    target=all ? 0 : root
    if Comm_rank(c)==target
        for peer in 0:Comm_size(c)-1
            chunk=_slice(v.buffer,Int(v.displacements[peer+1]),Int(v.counts[peer+1]))
            peer==target ? _store!(chunk,vec(s.wire)[s.offset+1:s.offset+s.count]) :
                Recv!(chunk,c;source=peer,tag=_GENERIC_TAG+4)
        end
        _writeback!(v.buffer)
    else
        Send(s,c;dest=target,tag=_GENERIC_TAG+4)
    end
    # Broadcast only occupied regions, retaining each rank's gap contents.
    if all
        for i in eachindex(v.counts)
            Bcast!(_slice(v.buffer,Int(v.displacements[i]),Int(v.counts[i])),c;root=target)
        end
        _writeback!(v.buffer)
    end
    result
end
function _ordered_scatterv!(v,r,result,c,root)
    if Comm_rank(c)==root
        for peer in 0:Comm_size(c)-1
            chunk=_slice(v.buffer,Int(v.displacements[peer+1]),Int(v.counts[peer+1]))
            peer==root ? _store!(r,vec(chunk.wire)[chunk.offset+1:chunk.offset+chunk.count]) :
                Send(chunk,c;dest=peer,tag=_GENERIC_TAG+5)
        end
    else
        Recv!(r,c;source=root,tag=_GENERIC_TAG+5)
    end
    result
end
function _ordered_alltoall!(s,r,count,result,c)
    rank=Comm_rank(c)
    for source in 0:Comm_size(c)-1, dest in 0:Comm_size(c)-1
        if source==dest
            if rank==source
                part=_slice(s,dest*count,count)
                _store!(_slice(r,source*count,count),vec(part.wire)[part.offset+1:part.offset+count])
            end
        elseif rank==source
            Send(_slice(s,dest*count,count),c;dest,tag=_GENERIC_TAG+6)
        elseif rank==dest
            Recv!(_slice(r,source*count,count),c;source,tag=_GENERIC_TAG+6)
        end
    end
    _writeback!(r)
    result
end

