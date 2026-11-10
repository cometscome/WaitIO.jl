using WaitIO, TOML
role = only(ARGS)
config=WaitIO.use_system_library(
    "miyabi-dev-$role";
    config_file="config-$role.toml")
WaitIO.check_library(require=[:core])
println("Julia=",VERSION," arch=",Sys.ARCH)
println("library_info=",WaitIO.library_info())
open(io->TOML.print(io,Dict(string(k)=>v for (k,v) in WaitIO.capabilities())),"capabilities-$role.toml","w")
println("missing_symbols=", sort!([string(k) for (k,v) in WaitIO.capabilities() if !v]))
@assert WaitIO.library_info().abi["implementation"]=="julia"
@assert !WaitIO.library_info().abi["compiler_invoked"]
println("native_capabilities_recorded=yes implementation=julia compiler_invoked=false")
