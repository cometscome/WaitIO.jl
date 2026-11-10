@testset "named site configurations" begin
    # Compare aliases to recorded native deployments, without native function replacements.
    for (name,arch,root,variant,profile,compat,fixes) in (
        ("miyabi-dev-g",:aarch64,"/work/share/waitio-rt/opt/waitio","nvidia","miyabi-dev-360",false,false),
        ("miyabi-dev-c",:x86_64,"/work/share/waitio-rt/opt/waitio","intel","miyabi-dev-360",false,false),
        ("miyabi-g",:aarch64,"/work/opt/local/aarch64/apps/nvidia/25.9/nv-hpcx/25.9/waitio/1.0","nvidia","miyabi-88",false,false),
        ("miyabi-c",:x86_64,"/work/opt/local/x86_64/apps/intel/2023.2.0/impi/2021.10.0/waitio/1.0","intel","miyabi-88",false,false),
        ("wisteria-odyssey",:aarch64,"/work/share/waitio-rt/opt/waitio","a64fx","wisteria-352",false,false),
        ("wisteria-aquarius",:x86_64,"/work/share/waitio-rt/opt/waitio","intel","wisteria-352",false,false))
        d=W.site_defaults(name)
        @test d.library_dir==joinpath(root,"lib")
        @test d.include_dir==joinpath(root,"include")
        @test (d.variant,d.abi_profile,d.miyabi_compat,d.native_fixes)==(variant,profile,compat,fixes)
        @test !W.library_info().loaded
        mktempdir() do dir
            target=joinpath(dir,"config.toml")
            if Sys.ARCH != arch
                @test_throws ArgumentError W.use_system_library(name;config_file=target,io=devnull)
                @test !isfile(target)
                return
            end
            # Alias paths must not accidentally pick up another site's module.
            withenv("WAITIO_LIB"=>"/wrong/site","WAITIO_INC"=>"/wrong/include") do
                @test W._site_options(name)==d
            end
            write(joinpath(dir,"libwaitio_$variant.so"),"invalid library")
            write(joinpath(dir,"libwaitio_mpi_$variant.so"),"invalid library")
            options=W._site_options(name;library_dir=dir,include_dir=dir)
            c=W._system_config(;options...)
            @test c.libwaitio==joinpath(dir,"libwaitio_$variant.so")
            @test c.abi_profile==profile
            options=W._site_options(name;libwaitio=c.libwaitio,libwaitio_mpi=c.libwaitio_mpi,include_dir=dir)
            @test !haskey(options,:library_dir) && !haskey(options,:variant)
            @test W._system_config(;options...).libwaitio==c.libwaitio
            @test_throws ArgumentError W._system_config(;W._site_options(name;libwaitio=c.libwaitio)...)
            # Invalid installation: never save a preset without validation.
            withenv("WAITIO_COMM_TYPE"=>"socket") do
                @test_throws ArgumentError W.use_system_library(name;library_dir=dir,
                    include_dir=dir,config_file=target,io=devnull)
            end
            @test !isfile(target)
            @test W._config[]===nothing && !W.library_info().loaded
            @test W.site_defaults(name)==d
        end
    end
    @test_throws ArgumentError W.site_defaults("miyabi")
    @test_throws ArgumentError W.use_system_library("unknown")
end

@testset "site setup and independent configurations" begin
    mktempdir() do dir
        for variant in ("intel","nvidia")
            write(joinpath(dir,"libwaitio_$variant.so"),"fixture")
            write(joinpath(dir,"libwaitio_mpi_$variant.so"),"fixture")
        end
        withenv("WAITIO_LIB"=>dir,"WAITIO_INC"=>dir) do
            @test_throws ArgumentError W._system_config()
            c=W._system_config(variant="intel")
            @test c.machine==Sys.MACHINE
            @test endswith(c.libwaitio,"libwaitio_intel.so")
            @test endswith(c.libwaitio_mpi,"libwaitio_mpi_intel.so")
            @test_throws ArgumentError W._system_config(libwaitio=c.libwaitio)
            @test_throws ArgumentError W._system_config(variant="../intel")
            @test_throws ArgumentError W._system_config(variant="intel",libwaitio=c.libwaitio,libwaitio_mpi=c.libwaitio_mpi)
            @test_throws ArgumentError W._check_library_machine(c)
            # Setup must not write a configuration when validation fails.
            file=joinpath(dir,"failed.toml")
            @test_throws ArgumentError W.use_system_library(variant="intel",config_file=file,io=devnull)
            @test !isfile(file)
            @test W._config[]===nothing
            @test !W.library_info().loaded
            rm(joinpath(dir,"libwaitio_nvidia.so"))
            @test W._system_config().libwaitio==c.libwaitio
            # A foreign-architecture ELF must fail before dlopen.
            h=zeros(UInt8,20); h[1:6]=UInt8[0x7f,0x45,0x4c,0x46,2,1]
            h[19]=Sys.ARCH==:x86_64 ? 183 : 62
            write(c.libwaitio,h); write(c.libwaitio_mpi,h)
            @test_throws ArgumentError W._check_library_machine(c)
        end
        incomplete=joinpath(dir,"incomplete.toml")
        write(incomplete,"[WaitIO]\nlibwaitio=\"/partial.so\"\n")
        withenv("WAITIO_JL_CONFIG"=>incomplete,"WAITIO_JL_INCLUDE_DIR"=>dir) do
            @test_throws ArgumentError W.configuration()
        end
        withenv("WAITIO_JL_CONFIG"=>joinpath(dir,"missing.toml")) do
            @test_throws Exception W.configuration()
        end
        # Explicit settings stay process-local and report flat, copy-safe origins.
        try
            W.configure!(W.LibraryConfig(libwaitio="/initial/core.so"))
            W.configure!(libwaitio="/explicit/core.so")
            info=W.configuration_info()
            @test info.config.libwaitio=="/explicit/core.so"
            @test all(x->x isa String,info.source.explicit_overrides)
            empty!(info.source.explicit_overrides)
            @test !isempty(W.configuration_info().source.explicit_overrides)
        finally
            W._config[]=nothing; W._config_source[]=nothing
        end
    end
end

@testset "Preferences inheritance and shared-project processes" begin
    mktempdir() do dir
        shared=joinpath(dir,"shared"); admin=joinpath(dir,"admin")
        mkpath(shared); mkpath(admin)
        project=Base.active_project()
        cp(project,joinpath(shared,"Project.toml"))
        # Pkg.test supplies a manifest with an absolute path to the package.
        cp(joinpath(dirname(project),"Manifest.toml"),joinpath(shared,"Manifest.toml"))
        write(joinpath(admin,"Project.toml"),"""
        [extras]
        WaitIO = "d19786dc-c986-4b1d-9838-faa08bcbccac"
        [preferences.WaitIO]
        libwaitio = "/admin/core.so"
        libwaitio_mpi = "/admin/collective.so"
        include_dir = "/admin/include"
        """)
        prefs=joinpath(shared,"LocalPreferences.toml")
        W.Preferences.set_preferences!(prefs,"WaitIO","libwaitio"=>"/local/core.so")
        probe=joinpath(@__DIR__,"configuration_probe.jl")
        env=Dict("WAITIO_JL_CONFIG"=>"","JULIA_LOAD_PATH"=>"@:$admin:@stdlib")
        for k in ("LIBWAITIO","LIBWAITIO_MPI","INCLUDE_DIR","ABI_PROFILE")
            env["WAITIO_JL_$k"]=""
        end
        function command(file; overrides=Dict{String,String}())
            cmd=`$(Base.julia_cmd()) --startup-file=no --project=$shared $probe $file`
            # Remove inherited path overrides completely; empty strings are explicit values.
            childenv=copy(ENV)
            for k in keys(env); startswith(k,"WAITIO_JL_") && pop!(childenv,k,nothing); end
            childenv["JULIA_LOAD_PATH"]=env["JULIA_LOAD_PATH"]
            merge!(childenv,overrides)
            setenv(cmd,childenv)
        end
        output=joinpath(dir,"preferences.toml")
        @test success(pipeline(command(output);stdout,stderr))
        d=W.TOML.parsefile(output)
        @test d["core"]=="/local/core.so"
        @test d["collective"]=="/admin/collective.so"
        @test d["include"]=="/admin/include"
        @test d["source"]=="preferences"
        files=String[]
        for role in ("c","g")
            path=joinpath(shared,"$role.toml")
            W.save_config(path,W.LibraryConfig(libwaitio="/$role/core.so",
                libwaitio_mpi="/$role/collective.so",include_dir="/$role/include"))
            push!(files,path)
        end
        tracked=[files; prefs; joinpath(shared,"Project.toml"); joinpath(shared,"Manifest.toml")]
        hashes=W._hash.(tracked)
        outputs=[joinpath(dir,"result-$i.toml") for i in 1:2]
        processes=[run(pipeline(command(outputs[i];overrides=Dict("WAITIO_JL_CONFIG"=>files[i]));stdout,stderr);wait=false) for i in 1:2]
        @test all(success,processes)
        for (i,role) in enumerate(("c","g"))
            result=W.TOML.parsefile(outputs[i])
            @test result["core"]=="/$role/core.so"
            @test result["collective"]=="/$role/collective.so"
            @test result["source"]=="file"
            @test result["path"]==files[i]
        end
        @test W._hash.(tracked)==hashes
        @test success(pipeline(command(output;overrides=Dict("WAITIO_JL_CONFIG"=>files[1],
            "WAITIO_JL_LIBWAITIO"=>"/override/core.so"));stdout,stderr))
        @test W.TOML.parsefile(output)["overrides"]==["WAITIO_JL_LIBWAITIO"]
        @test W.TOML.parsefile(output)["core"]=="/override/core.so"
    end
end
