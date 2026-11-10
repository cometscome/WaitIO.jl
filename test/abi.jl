@testset "configuration and reviewed ABI profiles" begin
    @test !isdefined(W,:build_adapter)
    for key in (:backend,:adapter,:mpicc,:cflags,:auto_build)
        @test !(key in fieldnames(W.LibraryConfig))
        @test_throws ArgumentError W._config_from_dict(Dict(String(key)=>"obsolete"))
    end
    @test W._layout_headers["miyabi-88"][1]==88
    @test W._layout_headers["wisteria-352"][1]==352
    @test W._layout_headers["miyabi-dev-360"][1]==360
    @test W._header_constant("#define BASE 0x80000\n#define X (BASE | 2)","X")==0x80002
    for text in ("#define X system(1)","#define X Y\n#define Y X", "#define X 1\n#define X 2")
        @test_throws ArgumentError W._header_constant(text,"X")
    end
    mktempdir() do dir
        # Text files deliberately cannot be dlopened. Only metadata validation
        # is under test here, with no attempt to infer a C struct layout.
        lib=joinpath(dir,"library"); write(lib,"test library identity")
        write(joinpath(dir,"waitio.h"),"test request header")
        write(joinpath(dir,"waitio-lib.h"),"#define NPBGMAX 64\n#define NPBMAX 64\n")
        header=joinpath(dir,"waitio_mpi.h")
        names=("INT","LONG","CHAR","FLOAT","DOUBLE","SUM","MAX","MIN")
        write(header,join(("#define WAITIO_MPI_$n $i\n" for (i,n) in enumerate(names))))
        profile=Dict("machine"=>Sys.MACHINE,"request_bytes"=>88,"request_alignment"=>8,
            "group_limit"=>64,"pb_limit"=>64,"libwaitio_sha256"=>W._hash(lib),"libwaitio_mpi_sha256"=>W._hash(lib),
            "headers"=>Dict(n=>W._hash(joinpath(dir,n)) for n in ("waitio.h","waitio_mpi.h","waitio-lib.h")))
        path=joinpath(dir,"abi.toml")
        record(p)=open(io->W.TOML.print(io,p),path,"w")
        record(profile)
        c=W.LibraryConfig(libwaitio=lib,libwaitio_mpi=lib,include_dir=dir,abi_profile=path)
        metadata=W._julia_metadata(c)
        @test metadata["request_bytes"]==88
        @test metadata["constants"][[6,10,11]]==[-1,-1,-1]
        @test metadata["implementation"]=="julia"
        for bytes in (352,648)
            record(merge(profile,Dict("request_bytes"=>bytes)))
            @test W._julia_metadata(c)["request_bytes"]==bytes
        end
        for (key,value) in (("request_alignment",32),("request_bytes",0),("request_bytes",89),
                ("pb_limit",0),("group_limit",0),("machine","other"),
                ("libwaitio_sha256","changed"),("headers",Dict("waitio.h"=>"changed")))
            record(merge(profile,Dict(key=>value)))
            @test_throws ArgumentError W._julia_metadata(c)
        end
        # A rebuilt binary is accepted with a recognized request layout.
        name="test-reviewed-layout"
        W._layout_headers[name]=(88,profile["headers"])
        try
            config=W.LibraryConfig(libwaitio=lib,libwaitio_mpi=lib,include_dir=dir)
            found=W._julia_metadata(config)
            @test found["recognized_profile"]==name
            @test !found["known_library_pair"]
            @test found["request_bytes"]==88
        finally
            delete!(W._layout_headers,name)
        end
        @test_throws ArgumentError W._julia_metadata(W.LibraryConfig(libwaitio=lib,
            libwaitio_mpi=lib,include_dir=dir,allow_unverified_abi=true))
    end
end
