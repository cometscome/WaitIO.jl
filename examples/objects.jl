using WaitIO

# Load this same definition in the same module on both participants.
struct TrainingBatch{T}
    name::String
    coordinates::Matrix{T}
    metadata::Dict{String,Int}
end

WaitIO.Init()
comm = WaitIO.Comm_world()
@assert WaitIO.Comm_size(comm) == 2 "Launch one process in each of two parallel blocks"
rank = WaitIO.Comm_rank(comm)

if rank == 0
    batch = TrainingBatch("sample", ones(3, 100), Dict("step" => 10))
    request = WaitIO.isend(batch, comm; dest=1, tag=20)
    WaitIO.Wait(request)
else
    batch = WaitIO.recv(comm; source=0, tag=20)
    @assert batch isa TrainingBatch{Float64}
    @assert batch.name == "sample"
    @assert batch.coordinates == ones(3, 100)
    @assert batch.metadata == Dict("step" => 10)
end
println("objects PASS rank=$rank")
WaitIO.Finalize()
