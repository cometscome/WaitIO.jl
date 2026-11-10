# Compiler-free bindings for reviewed LP64 Linux WaitIO ABIs. No C parser or
# compiler is invoked. Unknown request layouts are never inferred from symbols.
const _layout_headers = Dict(
    "miyabi-dev-360" => (360, Dict(
        "waitio.h"=>"2108ca40f86788a21726ed8d3c4fec38a11db844a85a13a5fba0d597ba24dc99",
        "waitio_mpi.h"=>"8f592ab1acc9b7e64b091124e75a7e8e83160d43b8ed34e654fc9be8f4a00519",
        "waitio-lib.h"=>"4763919f8a1e4fbcfcaa577ba281a23a77d9907df8c010465a3119d7e8395890")),
    "wisteria-352" => (352, Dict(
        "waitio.h"=>"89e168bd25acec5b8657ca18fc27bcb4a17765941e749a6240d0c86458df8a0d",
        "waitio_mpi.h"=>"29407d25d8cd308d3ae998ba78232580723ad5944920f9ae982bb8d61bf2d534",
        "waitio-lib.h"=>"5b0bfb757cd4edc0da16a5d099fbbe9bd159e81e502ffd7eeaa40bcbcc63e179")),
    "miyabi-88" => (88, Dict(
        "waitio.h"=>"7ed293564dada282679e9cab1b55b36fe3624f8a4dcd5536918f0f41ab1cd063",
        "waitio_mpi.h"=>"5387de0bed460fd8f9407ab6fdfd9c38fe574b78cea413ac5b0895de92fecac2",
        "waitio-lib.h"=>"e2676b94df012ccac5e4572ed5584656e9b52cb09cb0a0dc1597a636a949bfdf")))
const _known_library_pairs = Dict(
    # Miyabi development installation, 2026-11-10: C sizeof/alignment = 360/8.
    ("b283dcb681619be8212e57e552dd1d7bbd1fc58166f841f7b9e6b61a3610a6f0",
     "86348904ef7fa97a5d991405f41269fe9696b925946518f7dc3e24ef507d97a1")=>"miyabi-dev-360",
    ("f90a35f21d2d0e66dc7a8887bfd0567cb430520488e15969ef62db4524b50724",
     "1b5af4beb7ae693725a64bebd14aa7e0856893c733cca3cec7ab104e2b43d12b")=>"miyabi-dev-360",
    # Wisteria A64FX: matching reviewed headers; DWARF confirms PBreqQue=352.
    ("3bdc8e682567c12638c2bdd127936f990b964bb964c4367584ebeab50ecd0ad6",
     "42b159c517bf7579e5efbdcf0056ef6bac372d60acf82b8dad01ee6bd5bc90fa")=>"wisteria-352",
    ("5b1555bd1bb4241dcafa12e6358f8f1802db17815b0f485e9dc1f9154b0832e8",
     "7023c7883cef8c4aef53dfd865cfb4ec17ea423d986c994e90bc99464bd010df")=>"wisteria-352",
    ("7669e08b0d0b716a9d6382415a2451dab8da7c3569fd993eeccfdfb4df0f5f1c",
     "7a2b2c70fd166c76ffecdac5ec9f784efb5dad69a8c1c6a537aedf850804848e")=>"miyabi-88",
    ("33ffbed7f96c19650e913b5e44eb2862b85a7c307c7a5c22a1de1d88c9779335",
     "21c461af656487e56d3c88fa3ed846256123bfad284c51a13822b3d7da68c8e2")=>"miyabi-88")

# Only integer literals, macro names, parentheses, and bitwise OR are accepted.
# Never eval header text, run a preprocessor, or guess a missing required constant.
function _header_constant(text, name, seen=Set{String}())
    name in seen && throw(ArgumentError("recursive C constant: $name"))
    definitions=collect(eachmatch(Regex("(?m)^\\s*#define\\s+" * name * "[ \\t]+([^\\r\\n]+)"),text))
    length(definitions)==1 || throw(ArgumentError("expected one definition of $name"))
    value=first(split(first(split(definitions[1].captures[1],"/*")),"//"))
    value=replace(value,'('=>"",')'=>"")
    result=0
    for term in split(value,'|')
        term=strip(term)
        n=if occursin(r"^(0[xX][0-9a-fA-F]+|[0-9]+)[uUlL]*$",term)
            parse(Int,replace(term,r"[uUlL]+$"=>""))
        elseif occursin(r"^[A-Za-z_][A-Za-z_0-9]*$",term)
            _header_constant(text,term,union(seen,Set([name])))
        else
            throw(ArgumentError("unsupported C constant expression for $name"))
        end
        result |= n
    end
    result
end
function _julia_metadata(c)
    isempty(c.machine) || c.machine==Sys.MACHINE ||
        throw(ArgumentError("WaitIO configuration targets $(c.machine), but this Julia runs on $(Sys.MACHINE); select the matching WAITIO_JL_CONFIG"))
    Sys.islinux() && Sys.WORD_SIZE==64 && sizeof(Clong)==8 && Base.ENDIAN_BOM==0x04030201 ||
        throw(ArgumentError("compiler-free profiles currently require little-endian LP64 Linux"))
    Sys.ARCH in (:x86_64,:aarch64) || throw(ArgumentError("unsupported CPU architecture"))
    for p in (c.libwaitio,c.libwaitio_mpi)
        isabspath(p) && isfile(p) || throw(ArgumentError("set absolute paths to installed WaitIO libraries"))
    end
    isabspath(c.include_dir) && isdir(c.include_dir) || throw(ArgumentError("set include_dir to the site's headers"))
    for name in ("waitio.h","waitio_mpi.h","waitio-lib.h")
        isfile(joinpath(c.include_dir,name)) || throw(ArgumentError("missing $name in include_dir=$(c.include_dir); select the matching WaitIO headers"))
    end
    headers=Dict(n=>_hash(joinpath(c.include_dir,n)) for n in ("waitio.h","waitio_mpi.h","waitio-lib.h"))
    pair=(_hash(c.libwaitio),_hash(c.libwaitio_mpi))
    profile=""; bytes=0; alignment=8; group_limit=64; pb_limit=64
    if isabspath(c.abi_profile)
        p=TOML.parsefile(c.abi_profile)
        p["headers"]==headers || throw(ArgumentError("custom ABI profile headers do not match"))
        p["machine"]==Sys.MACHINE || throw(ArgumentError("custom ABI profile CPU does not match"))
        (p["libwaitio_sha256"],p["libwaitio_mpi_sha256"])==pair ||
            throw(ArgumentError("custom ABI profile library hashes do not match"))
        profile="custom:" * basename(c.abi_profile)
        bytes=Int(p["request_bytes"]); alignment=Int(p["request_alignment"])
        group_limit=Int(p["group_limit"]); pb_limit=Int(p["pb_limit"])
    else
        for (name,(n,expected)) in _layout_headers
            headers==expected || continue
            profile=name; bytes=n; break
        end
        isempty(profile) && throw(ArgumentError("unknown WaitIO request ABI; add a reviewed ABI profile (no compiler fallback)"))
        isempty(c.abi_profile) || c.abi_profile==profile || throw(ArgumentError("selected ABI profile does not match headers"))
        known=get(_known_library_pairs,pair,"")
        isempty(known) || known==profile || throw(ArgumentError("library/header ABI mismatch"))
        limits=read(joinpath(c.include_dir,"waitio-lib.h"),String)
        group_limit=_header_constant(limits,"NPBGMAX")
        pb_limit=_header_constant(limits,"NPBMAX")
    end
    bytes>0 && alignment in (1,2,4,8,16) && bytes%alignment==0 && group_limit>0 && pb_limit>0 ||
        throw(ArgumentError("invalid ABI profile sizes or limits"))
    text=read(joinpath(c.include_dir,"waitio_mpi.h"),String)
    constants=Int[]
    for name in ("INT","LONG","CHAR","FLOAT","DOUBLE","DOUBLE_INT","SUM","MAX","MIN","MAXLOC","MINLOC")
        key="WAITIO_MPI_" * name
        if name in ("DOUBLE_INT","MAXLOC","MINLOC") && !occursin(Regex("(?m)^\\s*#define\\s+"*key*"\\s"),text)
            push!(constants,-1)
        else
            push!(constants,_header_constant(text,key))
        end
    end
    Dict{String,Any}("implementation"=>"julia", "recognized_profile"=>profile,
        "request_bytes"=>bytes,"request_alignment"=>alignment,"group_limit"=>group_limit,"pb_limit"=>pb_limit,
        "headers"=>headers,"libwaitio_sha256"=>pair[1],"libwaitio_mpi_sha256"=>pair[2],
        "known_library_pair"=>get(_known_library_pairs,pair,"")==profile,
        "machine"=>Sys.MACHINE,"constants"=>constants,"compiler_invoked"=>false)
end

const _jl_owner=Ref{UInt}(0)
const _jl_group_filters=Dict{Int,Vector{Ptr{Cvoid}}}()
const _jl_callback_error=Ref{Any}(nothing)
_jl_info(key)=_library[].info[key]
_jl_constant(i)=1<=i<=11 ? _jl_info("constants")[i] : -1
_jl_alloc()=ccall(:calloc,Ptr{Cvoid},(Csize_t,Csize_t),1,_jl_info("request_bytes"))
_jl_free(p)=(Libc.free(p); nothing)
_jl_thread_ok()=Int(_jl_owner[]!=0 && ccall(:pthread_equal,Cint,(UInt,UInt),_jl_owner[],ccall(:pthread_self,UInt,()))!=0)
@locked function _mpi_symbol(name)
    b=_library[]
    haskey(b.pointers,name) && return b.pointers[name]
    for lib in (b.collective,b.core)
        ptr=Libdl.dlsym(lib,name;throw_error=false)
        ptr===nothing || return (b.pointers[name]=ptr)
    end
    throw(UnsupportedFeatureError(name))
end
function _jl_mpi_finalized()
    flag=Ref{Cint}(0)
    rc=ccall(_mpi_symbol(:MPI_Finalized),Cint,(Ref{Cint},),flag)
    rc==0 ? flag[] : -1
end
function _jl_mpi_start(external,owned,provided)
    unsafe_store!(owned,Cint(0))
    _jl_mpi_finalized()==0 || return -10001
    active=Ref{Cint}(0)
    rc=ccall(_mpi_symbol(:MPI_Initialized),Cint,(Ref{Cint},),active); rc==0 || return rc
    if active[]==0
        external==0 || return -10002
        argc=Ref{Cint}(0); argv=Ref{Ptr{Ptr{UInt8}}}(C_NULL)
        rc=ccall(_mpi_symbol(:MPI_Init_thread),Cint,(Ref{Cint},Ref{Ptr{Ptr{UInt8}}},Cint,Ptr{Cint}),argc,argv,2,provided)
        rc==0 || return rc
        unsafe_store!(owned,Cint(1))
    else
        rc=ccall(_mpi_symbol(:MPI_Query_thread),Cint,(Ptr{Cint},),provided); rc==0 || return rc
    end
    main=Ref{Cint}(0)
    rc=ccall(_mpi_symbol(:MPI_Is_thread_main),Cint,(Ref{Cint},),main); rc==0 || return rc
    (unsafe_load(provided)>=2 || main[]!=0 && unsafe_load(provided)>=1) || return -10003
    _jl_owner[]=ccall(:pthread_self,UInt,())
    0
end
function _jl_mpi_stop(owned)
    owned==0 && return 0
    _jl_mpi_finalized()==0 || return -10001
    ccall(_mpi_symbol(:MPI_Finalize),Cint,())
end
_jl_false(pbid,n)=Cint(0)
function _jl_create_group(gid,npb,selection,order)
    0<gid<_jl_info("group_limit") && 0<npb<=_jl_info("pb_limit") && !haskey(_jl_group_filters,gid) || return C_NULL
    filters=Ptr{Cvoid}[unsafe_load(selection,i)==2 ? _symbol(:headf) :
        unsafe_load(selection,i)==1 ? _symbol(:truef) : @cfunction(_jl_false,Cint,(Cint,Cint)) for i in 1:npb]
    _jl_group_filters[gid]=filters # Keep callbacks after errors until native shutdown.
    API.waitio_create_group(gid,filters,order)
end
_jl_cleanup()=(empty!(_jl_group_filters); nothing)
function _jl_dtypesize(d)
    for (i,size) in ((1,4),(2,8),(3,1),(4,4),(5,8))
        d==_jl_constant(i) && return size
    end
    -1
end

# Generate static C-callable Julia entry points. Exceptions never unwind through
# C; integer callbacks report a failure and retain the exception for diagnostics.
const _julia_entries=Dict{Symbol,Tuple}(
    :wjl_abi_version=>(Cint,(),:(_jl_abi_version)),
    :wjl_request_size=>(Csize_t,(),:(_jl_request_size)),
    :wjl_request_alignment=>(Csize_t,(),:(_jl_request_alignment)),
    :wjl_request_alloc=>(Ptr{Cvoid},(),:(_jl_alloc)),
    :wjl_request_free=>(Cvoid,(Ptr{Cvoid},),:(_jl_free)),
    :wjl_thread_ok=>(Cint,(),:(_jl_thread_ok)),
    :wjl_mpi_finalized=>(Cint,(),:(_jl_mpi_finalized)),
    :wjl_mpi_start=>(Cint,(Cint,Ptr{Cint},Ptr{Cint}),:(_jl_mpi_start)),
    :wjl_mpi_stop=>(Cint,(Cint,),:(_jl_mpi_stop)),
    :wjl_constant=>(Cint,(Cint,),:(_jl_constant)),
    :wjl_dtypesize=>(Cint,(Cint,),:(_jl_dtypesize)),
    :wjl_group_limit=>(Cint,(),:(_jl_group_limit)),
    :wjl_pb_limit=>(Cint,(),:(_jl_pb_limit)),
    :wjl_cleanup_groups=>(Cvoid,(),:(_jl_cleanup)),
    :wjl_create_group=>(Ptr{Cvoid},(Cint,Cint,Ptr{Cint},Ptr{Cint}),:(_jl_create_group)))
_jl_abi_version()=1
_jl_request_size()=_jl_info("request_bytes")
_jl_request_alignment()=_jl_info("request_alignment")
_jl_group_limit()=_jl_info("group_limit")
_jl_pb_limit()=_jl_info("pb_limit")
function _define_julia_entry(name,result,types,fn)
    args=[Symbol(:a,i) for i in eachindex(types)]
    typed=[:($(args[i])::$(types[i])) for i in eachindex(types)]
    wrapper=Symbol(:_entry_,name)
    failure=result==Cvoid ? :(nothing) : result<:Ptr ? :(Ptr{Cvoid}(C_NULL)) : result<:Unsigned ? :($result(0)) : :($result(-10200))
    success=result==Cvoid ? :($fn($(args...)); nothing) : :($result($fn($(args...))))
    @eval function $wrapper($(typed...))
        try
            $success
        catch err
            _jl_callback_error[]=err
            $failure
        end
    end
    @eval _julia_pointer(::Val{$(QuoteNode(name))})=@cfunction($wrapper,$result,$(Expr(:tuple,types...)))
end
for (name,(result,types,fn)) in _julia_entries
    _define_julia_entry(name,result,types,fn)
end
function _julia_symbol(name)
    haskey(_julia_entries,name) && return _julia_pointer(Val(name))
    nothing
end
