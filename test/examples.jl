# Execute the actual user programs in separate processes, without rewriting them
# into test variants. The fixture supplies transport only, never native networking.
using Test
@testset "runnable examples" begin
    project = dirname(Base.active_project())
    for name in ("exchange.jl", "collectives.jl", "objects.jl")
        @testset "$name" begin
            mktempdir() do dir
                children = Base.Process[]
                logs = IOStream[]
                try
                    for rank in 0:1
                        log = open(joinpath(dir, "rank-$rank.log"), "w")
                        push!(logs, log)
                        cmd = `$(Base.julia_cmd()) --startup-file=no --project=$project $(joinpath(@__DIR__, "example_worker.jl")) $dir $rank $name`
                        push!(children, run(pipeline(cmd; stdout=log, stderr=log); wait=false))
                    end
                    completed = timedwait(() -> all(process_exited, children), 90; pollint=0.1)
                    @test completed == :ok
                    for child in children
                        process_exited(child) || kill(child)
                        wait(child)
                    end
                    foreach(close, logs)
                    for (i, child) in enumerate(children)
                        print(read(joinpath(dir, "rank-$(i-1).log"), String))
                        @test success(child)
                    end
                finally
                    for child in children
                        process_exited(child) || kill(child)
                        wait(child)
                    end
                    foreach(io -> isopen(io) && close(io), logs)
                end
            end
        end
    end
end
