# Arrays with pointer-free elements have a well-defined byte representation.
# Noncontiguous and device arrays use host staging through Array/copyto!.
struct Buffer{A,W}
    data::A
    count::Int
    offset::Int
    wire::W
end
function _host_contiguous(data)
    data isa StridedArray || return false
    expected=1
    for d in 1:ndims(data)
        size(data,d)>1 && stride(data,d)!=expected && return false
        expected*=size(data,d)
    end
    try
        pointer(data) isa Ptr
    catch
        false
    end
end
function Buffer(data::AbstractArray{T};count::Integer=length(data),offset::Integer=0) where T
    isbitstype(T) || throw(ArgumentError("array elements contain references; use send/recv for serialized Julia objects"))
    0<=offset<=length(data) && 0<=count<=length(data)-offset || throw(BoundsError(data,(offset,count)))
    wire=_host_contiguous(data) ? data : Array(data)
    Buffer{typeof(data),typeof(wire)}(data,Int(count),Int(offset),wire)
end
Buffer(data;kwargs...) = throw(ArgumentError("expected an AbstractArray; use send/recv for Julia objects"))
function Buffer(b::Buffer)
    b.wire===b.data || copyto!(b.wire,Array(b.data))
    b
end
Base.eltype(b::Buffer) = eltype(b.data)
_nbytes(b::Buffer) = Base.checked_mul(b.count,sizeof(eltype(b)))
_pointer(b::Buffer) = Ptr{Cvoid}(pointer(b.wire) + Base.checked_mul(b.offset,sizeof(eltype(b))))
function _writeback!(b::Buffer)
    b.wire===b.data || copyto!(vec(b.data),firstindex(b.data)+b.offset,vec(b.wire),firstindex(b.wire)+b.offset,b.count)
    b
end
_snapshot(b::Buffer) = Buffer(copy(vec(b.wire)[b.offset+1:b.offset+b.count]))
# An overlap is handled by preserving the input before native code can overwrite it.
_input(s::Buffer,r::Buffer) = _overlap(s,r) ? _snapshot(s) : s

struct UBuffer{B}
    buffer::B
    count::Int
    UBuffer{B}(buffer::B,count::Int) where B = new{B}(buffer,count)
end
function UBuffer(data,count::Integer)
    count>=0 || throw(ArgumentError("negative uniform count"))
    UBuffer{typeof(Buffer(data))}(Buffer(data),Int(count))
end
struct VBuffer{B}
    buffer::B
    counts::Vector{Cint}
    displacements::Vector{Cint}
end
function VBuffer(data,counts;displacements=nothing)
    c=_count.(collect(counts)); d=Vector{Cint}(undef,length(c))
    if displacements===nothing
        offset=0
        for i in eachindex(c)
            d[i]=_count(offset); offset=Base.checked_add(offset,Int(c[i]))
        end
    else
        length(displacements)==length(c) || throw(DimensionMismatch("counts/displacements differ"))
        d.=_count.(displacements)
    end
    b=Buffer(data)
    all(Int(d[i])+Int(c[i])<=b.count for i in eachindex(c)) || throw(DimensionMismatch("variable buffer too small"))
    VBuffer(b,c,d)
end

struct Datatype
    name::Symbol
end
struct Op{F}
    name::Symbol
    function_::F
end
Op(name::Symbol)=Op(name,nothing)
"A Julia binary reduction function, applied in logical rank order."
Op(f)=Op(:CUSTOM,f)
"Value and user-supplied location for MAXLOC/MINLOC; ties choose the smaller location."
struct ValueLoc{T<:Real,I<:Integer}
    value::T
    location::I
end

const INT=Datatype(:INT); const LONG=Datatype(:LONG); const CHAR=Datatype(:CHAR)
const FLOAT=Datatype(:FLOAT); const DOUBLE=Datatype(:DOUBLE); const DOUBLE_INT=Datatype(:DOUBLE_INT)
const SUM=Op(:SUM); const MAX=Op(:MAX); const MIN=Op(:MIN)
const MAXLOC=Op(:MAXLOC); const MINLOC=Op(:MINLOC)
const _constant_ids=Dict(:INT=>1,:LONG=>2,:CHAR=>3,:FLOAT=>4,:DOUBLE=>5,:DOUBLE_INT=>6,
                        :SUM=>7,:MAX=>8,:MIN=>9,:MAXLOC=>10,:MINLOC=>11)
function _code(x::Union{Datatype,Op})
    id=get(_constant_ids,x.name,0)
    id>0 || throw(ArgumentError("unknown WaitIO constant: $(x.name)"))
    code=ccall(_symbol(:wjl_constant),Cint,(Cint,),id)
    code>=0 || throw(UnsupportedFeatureError(Symbol("WAITIO_MPI_",x.name)))
    code
end
"Return the selected header's integer constant for use with WaitIO.API. Not an MPI.jl handle."
native_code(x::Union{Datatype,Op}) = _code(x)
function Type_size(dt::Datatype)
    _rt()
    result=Ref{Cint}(0)
    _check(:waitio_mpi_type_size,API.waitio_mpi_type_size(_code(dt),result))
    Int(result[])
end
function _native_datatype(::Type{T}) where T
    T===Int32 && return INT
    T===Int64 && return LONG
    T in (Int8,UInt8) && return CHAR
    T===Float32 && return FLOAT
    T===Float64 && return DOUBLE
    nothing
end
function Datatype(::Type{T}) where T
    T===ValueLoc{Float64,Int32} && return DOUBLE_INT
    dt=_native_datatype(T)
    dt===nothing && throw(ArgumentError("WaitIO has no native datatype for $T; array transfers use CHAR byte counts"))
    dt
end
_wireunits(b::Buffer) = _native_datatype(eltype(b))===nothing ? sizeof(eltype(b)) : 1
function _typed(b::Buffer)
    dt=_native_datatype(eltype(b))
    if dt===nothing
        Type_size(CHAR)==1 || throw(ArgumentError("native CHAR size mismatch"))
        return _count(_nbytes(b)),_code(CHAR)
    end
    Type_size(dt)==sizeof(eltype(b)) || throw(ArgumentError("native datatype size mismatch"))
    _count(_nbytes(b))
    _count(b.count),_code(dt)
end
_wirecounts(v::VBuffer) = _count.([Base.checked_mul(Int(n),_wireunits(v.buffer)) for n in v.counts])
_wiredisplacements(v::VBuffer) = _count.([Base.checked_mul(Int(n),_wireunits(v.buffer)) for n in v.displacements])
function _same_type(a::Buffer,b::Buffer)
    eltype(a)===eltype(b) || throw(ArgumentError("send and receive element types must match"))
end

struct InPlace end
const IN_PLACE=InPlace()
_slice(b::Buffer,offset,count)=Buffer(b.wire;offset=b.offset+offset,count)
_locparts(x::ValueLoc)=(x.value,x.location)
_locparts(x::Tuple{<:Real,<:Integer})=x
_locparts(x::NamedTuple{(:value,:location),<:Tuple{<:Real,<:Integer}})=(x.value,x.location)
function _validate_reduction(T,op)
    op.name in (:SUM,:MIN,:MAX,:MAXLOC,:MINLOC,:CUSTOM) || throw(ArgumentError("unknown reduction operation $(op.name)"))
    if op.name in (:MIN,:MAX)
        T<:Complex && throw(ArgumentError("complex numbers have no MIN/MAX ordering; supply Op(f) with the intended ordering"))
    elseif op.name in (:MINLOC,:MAXLOC)
        hasmethod(_locparts,Tuple{T}) || throw(ArgumentError("MAXLOC/MINLOC require ValueLoc(value, location) or a (value, integer_location) tuple"))
    end
end
