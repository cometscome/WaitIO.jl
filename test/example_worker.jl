using WaitIO
include("process_transport.jl")
ProcessTransport.install(ARGS[1], parse(Int, ARGS[2]); n=2)
include(joinpath(@__DIR__, "..", "examples", ARGS[3]))
@assert WaitIO.Finalized()
