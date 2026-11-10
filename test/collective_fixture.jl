# Test transport algorithms, NOT installed WaitIO algorithms or a C reference.
module CollectiveFixture
using WaitIO
const W=WaitIO
using WaitIO: API, _jl_alloc, _jl_free, _jl_dtypesize, _jl_constant, _jl_request_size
struct _JLNativeError <: Exception
    code::Cint
end
_jcheck(rc)=(rc==0 || throw(_JLNativeError(Cint(rc))); nothing)
_jbad(ok)=ok || throw(_JLNativeError(Cint(-10100)))
const _JCTAG=Culong(0x574a4c00)
function _jbytes(n,d)
    size=_jl_dtypesize(d)
    _jbad(n>=0 && size>0 && UInt(n)<=UInt(typemax(Int))÷UInt(size))
    Int(n)*size
end
function _jgroup(g)
    rank=Ref{Cint}(0); size=Ref{Cint}(0)
    _jcheck(API.waitio_group_rank(g,rank)); _jcheck(API.waitio_group_size(g,size))
    _jbad(size[]>0 && 0<=rank[]<size[])
    Int(rank[]),Int(size[])
end
function _jtransfer(p,n,peer,tag,g,receive)
    req=_jl_alloc(); req!=C_NULL || throw(OutOfMemoryError())
    # As in high-level requests, an uncertain native failure must not free a
    # possibly active request. Success is the only path that releases storage.
    rc=receive ? API.waitio_irecv(g,peer,p,n,tag,req) : API.waitio_isend(g,peer,p,n,tag,req)
    _jcheck(rc); _jcheck(API.waitio_wait(req)); _jl_free(req)
    0
end
_jsend(p,n,peer,tag,g)=_jtransfer(p,n,peer,tag,g,false)
_jrecv(p,n,peer,tag,g)=_jtransfer(p,n,peer,tag,g,true)
_jcopy(dst,src,n)=(n>0 && ccall(:memmove,Ptr{Cvoid},(Ptr{Cvoid},Ptr{Cvoid},Csize_t),dst,src,n); nothing)
function _jtemporary(f,n)
    p=Libc.malloc(max(n,1)); p!=C_NULL || throw(OutOfMemoryError())
    try f(p) finally Libc.free(p) end
end
function _jtype_size(d,out)
    _jbad(out!=C_NULL && _jl_dtypesize(d)>0)
    unsafe_store!(out,Cint(_jl_dtypesize(d))); 0
end
_jisend(s,n,d,dst,tag,g,q)=API.waitio_isend(g,dst,s,_jbytes(n,d),Culong(tag),q)
_jirecv(r,n,d,src,tag,g,q)=API.waitio_irecv(g,src,r,_jbytes(n,d),Culong(tag),q)
_jtyped_send(s,n,d,dst,tag,g)=_jsend(s,_jbytes(n,d),dst,Culong(tag),g)
_jtyped_recv(r,n,d,src,tag,g)=_jrecv(r,_jbytes(n,d),src,Culong(tag),g)
function _jwaitall(n,r,status)
    _jbad(n>=0 && (n==0 || r!=C_NULL))
    first=0
    for i in 0:n-1
        rc=API.waitio_wait(r+i*_jl_request_size())
        status==C_NULL || unsafe_store!(status,Cint(rc),i+1)
        first==0 && (first=rc)
    end
    first
end
function _jbcast(buf,n,d,root,g)
    rank,size=_jgroup(g); nb=_jbytes(n,d); _jbad(0<=root<size)
    rank!=root && return _jrecv(buf,nb,root,_JCTAG,g)
    for i in 0:size-1
        i==root || _jsend(buf,nb,i,_JCTAG,g)
    end
    0
end
function _jgather(s,r,n,d,root,g)
    rank,size=_jgroup(g); nb=_jbytes(n,d); _jbad(0<=root<size && nb<=typemax(Int)÷size)
    rank!=root && return _jsend(s,nb,root,_JCTAG+1,g)
    for i in 0:size-1
        dst=r+nb*i
        i==root ? _jcopy(dst,s,nb) : _jrecv(dst,nb,i,_JCTAG+1,g)
    end
    0
end
function _jallgather(s,r,n,d,g)
    rank,size=_jgroup(g); _jbad(0<=n<=typemax(Cint)÷size)
    _jgather(s,r,n,d,0,g); _jbcast(r,n*size,d,0,g)
end
function _jscatter(s,sn,st,r,rn,rt,root,g)
    rank,size=_jgroup(g); sb=_jbytes(sn,st); rb=_jbytes(rn,rt)
    _jbad(sb==rb && 0<=root<size && sb<=typemax(Int)÷size)
    rank!=root && return _jrecv(r,rb,root,_JCTAG+2,g)
    for i in 0:size-1
        src=s+sb*i
        i==root ? _jcopy(r,src,rb) : _jsend(src,sb,i,_JCTAG+2,g)
    end
    0
end
function _jgatherv(s,sn,st,r,counts,displs,rt,root,g)
    rank,size=_jgroup(g); sb=_jbytes(sn,st); _jbad(0<=root<size)
    rank!=root && return _jsend(s,sb,root,_JCTAG+3,g)
    for i in 0:size-1
        rb=_jbytes(unsafe_load(counts,i+1),rt); offset=_jbytes(unsafe_load(displs,i+1),rt)
        if i==root
            _jbad(rb==sb); _jcopy(r+offset,s,rb)
        else
            _jrecv(r+offset,rb,i,_JCTAG+3,g)
        end
    end
    0
end
function _jscatterv(s,counts,displs,st,r,rn,rt,root,g)
    rank,size=_jgroup(g); rb=_jbytes(rn,rt); _jbad(0<=root<size)
    rank!=root && return _jrecv(r,rb,root,_JCTAG+4,g)
    for i in 0:size-1
        sb=_jbytes(unsafe_load(counts,i+1),st); offset=_jbytes(unsafe_load(displs,i+1),st)
        if i==root
            _jbad(sb==rb); _jcopy(r,s+offset,rb)
        else
            _jsend(s+offset,sb,i,_JCTAG+4,g)
        end
    end
    0
end
function _jallgatherv(s,sn,st,r,counts,displs,rt,g)
    rank,size=_jgroup(g)
    _jgatherv(s,sn,st,r,counts,displs,rt,0,g)
    for i in 1:size
        _jbcast(r+_jbytes(unsafe_load(displs,i),rt),unsafe_load(counts,i),rt,0,g)
    end
    0
end
function _jalltoall(s,sn,st,r,rn,rt,g)
    rank,size=_jgroup(g); sb=_jbytes(sn,st); rb=_jbytes(rn,rt)
    _jbad(sb==rb && sb<=typemax(Int)÷size)
    for src in 0:size-1, dst in 0:size-1
        if src==dst
            rank==src && _jcopy(r+rb*src,s+sb*dst,sb)
        elseif rank==src
            _jsend(s+sb*dst,sb,dst,_JCTAG+5,g)
        elseif rank==dst
            _jrecv(r+rb*src,rb,src,_JCTAG+5,g)
        end
    end
    0
end
function _jcombine_typed(::Type{T},s,r,n,op) where T
    a=Ptr{T}(s); b=Ptr{T}(r)
    for i in 1:n
        x=unsafe_load(a,i); y=unsafe_load(b,i)
        value=op==_jl_constant(7) ? x+y : op==_jl_constant(9) ? (x<y ? x : y) : (x>y ? x : y)
        unsafe_store!(b,value,i)
    end
end
function _jcombine(s,r,n,d,op)
    _jbad(n>=0 && op in (_jl_constant(7),_jl_constant(8),_jl_constant(9)))
    types=(Cint,Clong,Sys.ARCH==:aarch64 ? UInt8 : Int8,Cfloat,Cdouble)
    i=findfirst(k->d==_jl_constant(k),1:5); _jbad(i!==nothing)
    _jcombine_typed(types[i],s,r,n,op)
    0
end
function _jreduce(s,r,n,d,op,root,g)
    rank,size=_jgroup(g); nb=_jbytes(n,d)
    _jbad(0<=root<size && op in (_jl_constant(7),_jl_constant(8),_jl_constant(9)))
    rank!=root && return _jsend(s,nb,root,_JCTAG+6,g)
    _jtemporary(nb) do tmp
        _jcopy(r,s,nb)
        for i in 0:size-1
            i==root && continue
            _jrecv(tmp,nb,i,_JCTAG+6,g); _jcombine(tmp,r,n,d,op)
        end
    end
    0
end
function _jallreduce(s,r,n,d,op,g)
    _jreduce(s,r,n,d,op,0,g); _jbcast(r,n,d,0,g)
end
function _jprefix(s,r,n,d,op,g,exclusive)
    rank,size=_jgroup(g); nb=_jbytes(n,d)
    _jbad(op in (_jl_constant(7),_jl_constant(8),_jl_constant(9)))
    _jtemporary(nb) do tmp
        if rank==0
            _jcopy(tmp,s,nb); exclusive || _jcopy(r,s,nb)
        else
            _jrecv(tmp,nb,rank-1,_JCTAG+7,g)
            exclusive && _jcopy(r,tmp,nb)
            _jcombine(s,tmp,n,d,op)
            exclusive || _jcopy(r,tmp,nb)
        end
        rank+1<size && _jsend(tmp,nb,rank+1,_JCTAG+7,g)
    end
    0
end
_jscan(s,r,n,d,op,g)=_jprefix(s,r,n,d,op,g,false)
_jexscan(s,r,n,d,op,g)=_jprefix(s,r,n,d,op,g,true)
function _jbarrier(g)
    rank,size=_jgroup(g); one=Cint[1]; arrived=Cint[0]
    GC.@preserve one arrived _jallreduce(Ptr{Cvoid}(pointer(one)),Ptr{Cvoid}(pointer(arrived)),1,_jl_constant(1),_jl_constant(7),g)
    _jbad(arrived[1]==size); 0
end

const operations=Dict("type_size"=>:_jtype_size,"isend"=>:_jisend,"irecv"=>:_jirecv,
    "send"=>:_jtyped_send,"recv"=>:_jtyped_recv,"waitall"=>:_jwaitall,
    "bcast"=>:_jbcast,"gather"=>:_jgather,"allgather"=>:_jallgather,
    "scatter"=>:_jscatter,"gatherv"=>:_jgatherv,"scatterv"=>:_jscatterv,
    "allgatherv"=>:_jallgatherv,"alltoall"=>:_jalltoall,"reduce"=>:_jreduce,
    "allreduce"=>:_jallreduce,"scan"=>:_jscan,"exscan"=>:_jexscan,"barrier"=>:_jbarrier)
const entries=Dict{Symbol,Ptr{Cvoid}}()
# Keep pointer creation in functions: addresses cannot be serialized at precompile.
for (op,fn) in operations
    name=Symbol("waitio_mpi_",op)
    result,types=W.API.SIGNATURES[name]
    args=[Symbol(:a,i) for i in eachindex(types)]
    wrapper=Symbol(:fixture_,op)
    @eval function $wrapper($(args...))
        try
            Cint($fn($(args...)))
        catch err
            err isa _JLNativeError || rethrow()
            Cint(err.code)
        end
    end
    @eval pointer_for(::Val{$(QuoteNode(name))})=@cfunction($wrapper,$result,$(Expr(:tuple,types...)))
end
function install()
    for op in keys(operations)
        name=Symbol("waitio_mpi_",op)
        W._library[].pointers[name]=pointer_for(Val(name))
    end
end
end
