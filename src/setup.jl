# These functions run only when explicitly called, never at module load/precompile time.

# Site installations used by the November 2026 native tests. These are explicit
# choices, not hostname/CPU heuristics; the regular ABI checks still apply.
const _site_installations = (
    "miyabi-dev-g" => (arch=:aarch64, root="/work/share/waitio-rt/opt/waitio",
        variant="nvidia", abi_profile="miyabi-dev-360", miyabi_compat=false, native_fixes=false),
    "miyabi-dev-c" => (arch=:x86_64, root="/work/share/waitio-rt/opt/waitio",
        variant="intel", abi_profile="miyabi-dev-360", miyabi_compat=false, native_fixes=false),
    "miyabi-g" => (arch=:aarch64,
        root="/work/opt/local/aarch64/apps/nvidia/25.9/nv-hpcx/25.9/waitio/1.0",
        variant="nvidia", abi_profile="miyabi-88", miyabi_compat=false, native_fixes=false),
    "miyabi-c" => (arch=:x86_64,
        root="/work/opt/local/x86_64/apps/intel/2023.2.0/impi/2021.10.0/waitio/1.0",
        variant="intel", abi_profile="miyabi-88", miyabi_compat=false, native_fixes=false),
    "wisteria-odyssey" => (arch=:aarch64, root="/work/share/waitio-rt/opt/waitio",
        variant="a64fx", abi_profile="wisteria-352", miyabi_compat=false, native_fixes=false),
    "wisteria-aquarius" => (arch=:x86_64, root="/work/share/waitio-rt/opt/waitio",
        variant="intel", abi_profile="wisteria-352", miyabi_compat=false, native_fixes=false),
)

function _site_installation(site::AbstractString)
    for (name, installation) in _site_installations
        site == name && return installation
    end
    throw(ArgumentError("unknown WaitIO site '$site'; choose $(join(first.(_site_installations), ", "))"))
end

"""
    site_defaults(site)

Inspect the library directories, variant, ABI profile, and compatibility options
for `"miyabi-g"`, `"miyabi-c"`, `"miyabi-dev-g"`, `"miyabi-dev-c"`,
`"wisteria-odyssey"`, or `"wisteria-aquarius"`.
Returns a named tuple without accessing the site, loading libraries, or saving
settings. The aliases describe the installations used in November 2026 tests.
"""
function site_defaults(site::AbstractString)
    s = _site_installation(site)
    (; library_dir=joinpath(s.root,"lib"), include_dir=joinpath(s.root,"include"),
       s.variant, s.abi_profile, s.miyabi_compat, s.native_fixes)
end

function _site_options(site::AbstractString; kwargs...)
    s = _site_installation(site)
    Sys.ARCH == s.arch || throw(ArgumentError("$site requires $(s.arch); run setup on the target system (current architecture: $(Sys.ARCH))"))
    defaults = site_defaults(site)
    if haskey(kwargs,:libwaitio) || haskey(kwargs,:libwaitio_mpi)
        # Explicit library pairs replace the default directory/variant selection.
        defaults = (; (k=>v for (k,v) in pairs(defaults) if k ∉ (:library_dir,:variant))...)
    end
    merge(defaults, (;kwargs...))
end

"""
    use_system_library(site; config_file=nothing, force=false, kwargs...)

Configure a known site using `site_defaults(site)`. Run on the selected target
architecture with its MPI modules loaded. Set `WAITIO_COMM_TYPE=socket` for Miyabi.
Explicit keywords override alias defaults; `WAITIO_LIB`/`WAITIO_INC` do not override
an alias. Existing library/header and ABI validation remains mandatory.
Use separate `config_file` paths for systems sharing an application project.
"""
function use_system_library(site::AbstractString; kwargs...)
    use_system_library(;_site_options(site;kwargs...)...)
end

function _check_library_machine(c::LibraryConfig)
    expected = Sys.ARCH == :x86_64 ? 62 : Sys.ARCH == :aarch64 ? 183 : 0
    expected != 0 || throw(ArgumentError("unsupported CPU architecture: $(Sys.ARCH)"))
    for path in (c.libwaitio,c.libwaitio_mpi)
        header = open(io -> read(io,20),path)
        length(header)==20 && header[1:4]==UInt8[0x7f,0x45,0x4c,0x46] &&
            header[5]==2 && header[6]==1 ||
            throw(ArgumentError("expected a 64-bit little-endian ELF shared library: $path"))
        machine = Int(header[19]) | Int(header[20])<<8
        machine==expected || throw(ArgumentError("library $path has ELF machine $machine, incompatible with $(Sys.ARCH); select the matching WAITIO_JL_CONFIG"))
    end
    nothing
end

function _system_config(;library_dir=nothing,include_dir=nothing,variant=nothing,
        libwaitio=nothing,libwaitio_mpi=nothing,abi_profile="",
        miyabi_compat=false,native_fixes=false,allow_unverified_abi=false)
    directory = library_dir === nothing ? get(ENV,"WAITIO_LIB","") : String(library_dir)
    headers = include_dir === nothing ? get(ENV,"WAITIO_INC","") : String(include_dir)
    if (libwaitio === nothing) != (libwaitio_mpi === nothing)
        throw(ArgumentError("specify both libwaitio and libwaitio_mpi, or neither"))
    end
    if libwaitio === nothing
        isempty(directory) && throw(ArgumentError("set library_dir or load the site's module defining WAITIO_LIB; alternatively specify both library paths"))
        isdir(directory) || throw(ArgumentError("WaitIO library directory does not exist: $directory"))
        if variant !== nothing
            occursin(r"^[A-Za-z0-9_-]*$",variant) || throw(ArgumentError("invalid library variant: $variant"))
            suffix = isempty(variant) ? "" : "_" * variant
            libwaitio = joinpath(directory,"libwaitio$suffix.so")
            libwaitio_mpi = joinpath(directory,"libwaitio_mpi$suffix.so")
        else
            candidates = Tuple{String,String}[]
            for name in sort(readdir(directory))
                m = match(r"^libwaitio(_[A-Za-z0-9_-]+)?\.so$",name)
                m===nothing && continue
                suffix = something(m.captures[1],"")
                (suffix=="_mpi" || startswith(suffix,"_mpi_")) && continue
                core = joinpath(directory,name)
                collective = joinpath(directory,"libwaitio_mpi$suffix.so")
                isfile(core) && isfile(collective) && push!(candidates,(core,collective))
            end
            length(candidates)==1 || throw(ArgumentError("expected one WaitIO library pair in $directory; found $(length(candidates)): $(join(first.(candidates), ", ")). Set variant or both absolute library paths explicitly"))
            libwaitio,libwaitio_mpi = only(candidates)
        end
    elseif variant !== nothing || library_dir !== nothing
        throw(ArgumentError("use either explicit library paths or library_dir/variant"))
    end
    isempty(headers) && throw(ArgumentError("set include_dir or load the site's module defining WAITIO_INC"))
    profile = isempty(abi_profile) || !isfile(abi_profile) ? abi_profile : abspath(abi_profile)
    LibraryConfig(;machine=Sys.MACHINE,libwaitio=abspath(libwaitio),
        libwaitio_mpi=abspath(libwaitio_mpi),include_dir=abspath(headers),
        abi_profile=profile,miyabi_compat,native_fixes,allow_unverified_abi)
end

"""
    use_system_library(; library_dir, include_dir, variant, libwaitio, libwaitio_mpi,
                         config_file=nothing, force=false, kwargs...)

Find a site's WaitIO library pair, validate it without starting communication,
then persist its configuration. `WAITIO_LIB`/`WAITIO_INC` supply directory defaults.
Multiple pairs require an explicit `variant` (e.g. "intel" or "nvidia") or both
library paths. No compiler, installer, module command, or MPI launcher is invoked.

Without `config_file`, use Preferences.jl to save to the active project's local
preferences. With `config_file`, write a standalone `[WaitIO]` TOML file for
`WAITIO_JL_CONFIG`. Existing differing preferences/files require `force=true`.
Run setup separately for each target environment, then start a fresh Julia process
for the application. Setup ignores existing preferences and WAITIO_JL_* overrides.
"""
function use_system_library(;config_file=nothing,force=false,io::IO=stdout,kwargs...)
    _library[]===nothing || throw(ArgumentError("libraries already loaded; run setup in a fresh Julia process"))
    if config_file !== nothing
        target = abspath(config_file)
        isfile(target) && !force && throw(ArgumentError("configuration file exists: $target; pass force=true to replace it"))
        basename(target) in ("Project.toml","JuliaProject.toml") &&
            throw(ArgumentError("use a site TOML file, not Project.toml"))
    else
        Base.active_project() !== nothing || throw(ArgumentError("activate a Julia project before saving preferences"))
    end
    config = _system_config(;kwargs...)
    previous, previous_source = _config[], _config_source[]
    try
        configure!(config)
        check_library(;verbose=true,io)
    catch
        if _library[]===nothing
            _config[],_config_source[] = previous,previous_source
        end
        rethrow()
    end
    if config_file === nothing
        Preferences.set_preferences!(@__MODULE__,
            (String(k)=>getfield(config,k) for k in fieldnames(LibraryConfig))...;force)
        println(io,"Saved WaitIO preferences for ",Base.active_project())
    else
        save_config(abspath(config_file),config)
        println(io,"Saved WaitIO configuration: ",abspath(config_file))
    end
    println(io,"Start a fresh Julia process for the application; setup does not initialize MPI/WaitIO communication.")
    config
end
