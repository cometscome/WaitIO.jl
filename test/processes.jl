@testset "four Julia processes" begin
    mktempdir() do dir
        project=dirname(Base.active_project())
        children=Base.Process[]; logs=IOStream[]
        try
            for rank in 0:3
                log=open(joinpath(dir,"rank-$rank.log"),"w"); push!(logs,log)
                cmd=`$(Base.julia_cmd()) --startup-file=no --project=$project $(joinpath(@__DIR__,"process_worker.jl")) $dir $rank`
                push!(children,run(pipeline(cmd;stdout=log,stderr=log);wait=false))
            end
            completed=timedwait(()->all(process_exited,children),180;pollint=0.2)
            @test completed==:ok
            for child in children
                process_exited(child) || kill(child)
                wait(child)
            end
            foreach(close,logs)
            for (rank,child) in enumerate(children)
                print(read(joinpath(dir,"rank-$(rank-1).log"),String))
                @test success(child)
            end
        finally
            for child in children
                process_exited(child) || kill(child)
            end
            foreach(io->isopen(io) && close(io),logs)
        end
    end
end
