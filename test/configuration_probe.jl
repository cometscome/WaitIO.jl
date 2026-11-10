using WaitIO
info = WaitIO.configuration_info()
@assert !WaitIO.library_info().loaded
@assert WaitIO._config[] === nothing
d = Dict("core"=>info.config.libwaitio,"collective"=>info.config.libwaitio_mpi,
    "include"=>info.config.include_dir,"source"=>info.source.kind,
    "path"=>info.source.path,"overrides"=>info.source.environment_overrides)
open(io -> WaitIO.TOML.print(io,d),ARGS[1],"w")
