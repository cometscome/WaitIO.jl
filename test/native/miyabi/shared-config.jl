using WaitIO, Test, TOML, SHA
role=only(ARGS)
peer=role=="g" ? "c" : "g"
@testset "shared project configuration $role" begin
    info=WaitIO.configuration_info()
    @test info.source.kind=="file"
    @test info.source.path==abspath("config-$role.toml")
    @test info.config.machine==Sys.MACHINE
    @test isempty(info.source.environment_overrides)
    @test !WaitIO.library_info().loaded
    foreign=WaitIO.load_config("config-$peer.toml")
    @test foreign.machine!=Sys.MACHINE
    WaitIO.configure!(foreign)
    @test_throws ArgumentError WaitIO.check_library()
    @test !WaitIO.library_info().loaded
    WaitIO.configure!(info.config)
    @test WaitIO.check_library().loaded
    record=Dict("project"=>realpath(Base.active_project()),
        "source"=>realpath(pathof(WaitIO)),"machine"=>Sys.MACHINE,
        "config"=>info.source.path,
        "source_sha256"=>open(io->bytes2hex(sha256(io)),pathof(WaitIO)),
        "library"=>info.config.libwaitio)
    open(io->TOML.print(io,record),"shared-project-$role.toml","w")
end
