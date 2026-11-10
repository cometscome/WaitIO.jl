"Paths are explicit: libwaitio_mpi is WaitIO's collective library, not libmpi."
Base.@kwdef struct LibraryConfig
    machine::String = ""
    abi_profile::String = ""
    libwaitio::String = ""
    libwaitio_mpi::String = ""
    include_dir::String = ""
    allow_unverified_abi::Bool = false
    test_pending::Int = 1
    native_fixes::Bool = false
    miyabi_compat::Bool = false
end

const _config = Ref{Union{Nothing,LibraryConfig}}(nothing)
const _config_source = Ref{Any}(nothing)
mutable struct LibraryState
    config::LibraryConfig
    core::Ptr{Cvoid}
    collective::Ptr{Cvoid}
    pointers::Dict{Symbol,Ptr{Cvoid}}
    aliases::Dict{Symbol,Symbol}
    info::Dict{String,Any}
end
const _library = Ref{Union{Nothing,LibraryState}}(nothing)

function _config_from_dict(d)
    allowed = String.(fieldnames(LibraryConfig))
    unknown = setdiff(collect(keys(d)), allowed)
    isempty(unknown) || throw(ArgumentError("unknown WaitIO configuration keys: $(join(unknown, ", "))"))
    LibraryConfig(; (Symbol(k) => v for (k,v) in d)...)
end

# Prefer the new name, but continue to accept pre-rename site settings.
_config_section(d; flat=false) = get(d, "WaitIO", get(d, "WAITIO", flat ? d : Dict{String,Any}()))

"Load [WaitIO], legacy [WAITIO], or a flat site TOML file; no library is loaded."
function load_config(path::AbstractString)
    d = TOML.parsefile(path)
    _config_from_dict(_config_section(d; flat=true))
end

"Write a site-local configuration. Absolute library paths must not be committed."
function save_config(path::AbstractString, config::LibraryConfig)
    d = isfile(path) ? TOML.parsefile(path) : Dict{String,Any}()
    pop!(d, "WAITIO", nothing)
    d["WaitIO"] = Dict(String(k) => getfield(config, k) for k in fieldnames(LibraryConfig))
    mkpath(dirname(abspath(path)))
    tmp, io = mktemp(dirname(abspath(path)))
    try
        TOML.print(io, d)
        close(io)
        mv(tmp, path; force=true)
    finally
        isopen(io) && close(io)
        isfile(tmp) && rm(tmp)
    end
    path
end

function _preferences_config()
    defaults = LibraryConfig()
    # Read only at run time: site paths must not become precompile-time constants.
    d = Dict(String(k) => Preferences.load_preference(@__MODULE__, String(k), getfield(defaults,k))
             for k in fieldnames(LibraryConfig))
    for key in ("backend", "adapter", "mpicc", "cflags", "auto_build")
        Preferences.has_preference(@__MODULE__,key) &&
            throw(ArgumentError("obsolete WaitIO preference: $key; remove it before use"))
    end
    project = Base.active_project()
    if project !== nothing
        # Compatibility for files created before the package was renamed.
        for name in ("JuliaLocalPreferences.toml", "LocalPreferences.toml")
            path = joinpath(dirname(project),name)
            isfile(path) || continue
            localprefs = TOML.parsefile(path)
            if !haskey(localprefs,"WaitIO") && haskey(localprefs,"WAITIO")
                merge!(d,localprefs["WAITIO"])
            end
            break
        end
    end
    _config_from_dict(d)
end

function _require_paths(c, label)
    missing = [String(k) for k in (:libwaitio,:libwaitio_mpi,:include_dir) if isempty(getfield(c,k))]
    isempty(missing) || throw(ArgumentError("$label is incomplete: set $(join(missing, ", ")); run WaitIO.use_system_library() on the target system"))
    c
end

function _environment_configuration()
    path = get(ENV, "WAITIO_JL_CONFIG", "")
    explicit_file = !isempty(path)
    base = explicit_file ? _require_paths(load_config(path), "WAITIO_JL_CONFIG=$path") : _preferences_config()
    d = Dict(k => getfield(base,k) for k in fieldnames(LibraryConfig))
    overrides = String[]
    for key in (:abi_profile, :libwaitio, :libwaitio_mpi, :include_dir)
        env = "WAITIO_JL_" * uppercase(String(key))
        if haskey(ENV, env)
            d[key] = ENV[env]
            push!(overrides,env)
        end
    end
    source = (;kind=explicit_file ? "file" : "preferences",
        path=explicit_file ? abspath(path) : "", project=Base.active_project(),
        environment_overrides=overrides, explicit_overrides=String[])
    LibraryConfig(;d...), source
end
_environment_config() = first(_environment_configuration())

"Configure the installed WaitIO libraries before loading them. Explicit keywords override environment and saved settings."
function configure!(; kwargs...)
    base, source = _config[] === nothing ? _environment_configuration() : (_config[],_config_source[])
    d = Dict(k => getfield(base,k) for k in fieldnames(LibraryConfig))
    for (key,value) in kwargs
        haskey(d,key) || throw(ArgumentError("unknown configuration key: $key"))
        d[key] = value
    end
    config = configure!(LibraryConfig(;d...))
    _config_source[] = merge(source,(;explicit_overrides=unique(vcat(source.explicit_overrides,String.(collect(keys(kwargs)))))))
    config
end
function configure!(config::LibraryConfig)
    _library[] === nothing || throw(ArgumentError("libraries already loaded; change configuration in a fresh Julia process"))
    _config[] = config
    _config_source[] = (;kind="explicit",path="",project=Base.active_project(),
        environment_overrides=String[],explicit_overrides=String.(collect(fieldnames(LibraryConfig))))
    config
end
configuration() = _config[] === nothing ? _environment_config() : _config[]

"Return the effective configuration and its origin without loading a library or writing files."
function configuration_info()
    config, source = _config[] === nothing ? _environment_configuration() : (_config[],_config_source[])
    (;config,source=deepcopy(source))
end

_hash(path) = open(io -> bytes2hex(sha256(io)), path)
@locked function _symbol(name::Symbol)
    b=_library[]
    b === nothing && throw(ArgumentError("call check_library or Init first"))
    get!(b.pointers,name) do
        ptr=_julia_symbol(name)
        ptr===nothing || return ptr
        handle = (startswith(String(name),"waitio_mpi_") || startswith(String(name),"WAITIO_MPI_") ||
             name in (:waitio_create_universe,:waitio_create_universe_pbhead,:waitio_do_init,:waitio_do_reduce)) ? b.collective : b.core
        ptr=Libdl.dlsym(handle,name;throw_error=false)
        ptr===nothing && throw(UnsupportedFeatureError(name))
        ptr
    end
end

"Load and check ABI and required symbols without starting communication."
@locked function check_library(; require=[:core], verbose=false, io::IO=stdout)
    if _library[]===nothing
        resolved=configuration_info()
        c=_require_paths(resolved.config,"WaitIO configuration")
        if c.miyabi_compat || c.native_fixes
            @warn "Legacy miyabi_compat/native_fixes settings are ignored. WaitIO.API now calls installed native symbols without replacements."
        end
        metadata=_julia_metadata(c)
        _check_library_machine(c)
        _config[]=c
        _config_source[]=resolved.source
        c.test_pending>0 || throw(ArgumentError("test_pending must be positive"))
        # Use the site's MPI dependency chain; do not load an MPI JLL here.
        core=Libdl.dlopen(c.libwaitio,Libdl.RTLD_LAZY|Libdl.RTLD_GLOBAL)
        collective=Libdl.dlopen(c.libwaitio_mpi,Libdl.RTLD_LAZY|Libdl.RTLD_GLOBAL)
        _library[]=LibraryState(c,core,collective,Dict(),Dict(),metadata)
        metadata["test_pending"]=c.test_pending
    end
    for group in require
        names = group==:core ? [:waitio_isend,:waitio_irecv,:waitio_wait,:waitio_test,:waitio_finalize,:waitio_create_universe,:waitio_group_rank,:waitio_group_size] :
            group==:all ? collect(keys(API.SIGNATURES)) :
            group==:collectives ? [n for n in keys(API.SIGNATURES) if startswith(String(n),"waitio_mpi_")] :
            throw(ArgumentError("unknown feature group: $group"))
        foreach(_symbol,names)
    end
    info=library_info()
    if verbose
        println(io,"WaitIO configuration: ",info.source)
        println(io,"  libwaitio: ",info.config.libwaitio)
        println(io,"  libwaitio_mpi: ",info.config.libwaitio_mpi)
        println(io,"  include_dir: ",info.config.include_dir)
        println(io,"  machine: ",Sys.MACHINE,"; ABI: ",info.abi["recognized_profile"])
        println(io,"  miyabi_compat: ",info.config.miyabi_compat,"; native_fixes: ",info.config.native_fixes)
    end
    info
end
function library_info()
    b=_library[]
    b===nothing && return (;loaded=false,configuration_info()...)
    (;loaded=true,config=b.config,source=deepcopy(_config_source[]),abi=deepcopy(b.info),aliases=copy(b.aliases))
end
function capabilities()
    _library[]===nothing && check_library()
    Dict(n => try _symbol(n); true catch e; e isa UnsupportedFeatureError ? false : rethrow() end
         for n in keys(API.SIGNATURES))
end
