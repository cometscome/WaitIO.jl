using Test, WaitIO, Libdl
const W=WaitIO
# No native libraries, C compiler, or archived files are needed by this suite.
include("abi.jl")
include("bindings.jl")
include("configuration.jl")
@testset "runtime subprocesses" begin
    project=dirname(Base.active_project())
    for mode in ("external","error","missing_external","thread","serialized","external_worker","object_error")
        @test success(pipeline(`$(Base.julia_cmd()) --startup-file=no --threads=2 --project=$project $(joinpath(@__DIR__,"subprocess.jl")) $mode`;stdout,stderr))
    end
    for (mode,bytes) in (("plain",648),("fixture",648),("fixture",88),("fixture",352))
        @test success(pipeline(`$(Base.julia_cmd()) --startup-file=no --project=$project $(joinpath(@__DIR__,"runtime_worker.jl")) $mode $bytes`;stdout,stderr))
    end
end
include("processes.jl")
include("unit.jl")
