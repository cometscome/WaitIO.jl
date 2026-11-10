using WaitIO

WaitIO.Init()
comm = WaitIO.Comm_world()
@assert WaitIO.Comm_size(comm) == 2 "Launch one process in each of two parallel blocks"
rank = WaitIO.Comm_rank(comm)

# Both ranks call the same native collectives, in the same order.
values = rank == 0 ? [10.0, 20.0] : zeros(2)
WaitIO.Bcast!(values, comm; root=0)
@assert values == [10.0, 20.0]

total = zeros(1)
WaitIO.Allreduce!([Float64(rank + 1)], total, WaitIO.SUM, comm)
@assert total == [3.0]

# Only the root needs the gathered result or the scatter input.
gathered = rank == 0 ? zeros(2) : nothing
WaitIO.Gather!([Float64(rank + 1)], gathered, comm; root=0)
if rank == 0
    @assert gathered == [1.0, 2.0]
end
piece = zeros(1)
WaitIO.Scatter!(gathered, piece, comm; root=0)
@assert piece == [Float64(rank + 1)]

# counts are per rank; VBuffer defaults to zero-based displacements [0, 1].
counts = [1, 2]
local_values = rank == 0 ? [10.0] : [20.0, 30.0]
all_values = zeros(3)
WaitIO.Allgatherv!(local_values, WaitIO.VBuffer(all_values, counts), comm)
@assert all_values == [10.0, 20.0, 30.0]
println("collectives PASS rank=$rank sum=$(total[1]) variable=$all_values")
WaitIO.Finalize()
