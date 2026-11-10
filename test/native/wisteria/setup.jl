using WaitIO, Test, TOML
config=WaitIO.use_system_library(
    library_dir=ENV["WAITIO_LIB"],include_dir=ENV["WAITIO_INC"],
    variant="intel")
info=WaitIO.check_library(require=[:core])
@test info.abi["recognized_profile"]=="wisteria-352"
@test info.abi["known_library_pair"]
println("missing_symbols=", sort!([string(k) for (k,v) in WaitIO.capabilities() if !v]))
@test !WaitIO.Initialized()
for role in 0:1
    WaitIO.save_config("config-$role.toml",config)
end
println("wisteria_setup_completed native_capabilities_recorded=yes")
