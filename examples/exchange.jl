using WaitIO

WaitIO.Init()
comm = WaitIO.Comm_world()
@assert WaitIO.Comm_size(comm) == 2 "Launch one process in each of two parallel blocks"
rank = WaitIO.Comm_rank(comm)
peer = 1 - rank

sendbuf = fill(Float64(rank), 1024)
recvbuf = zeros(1024)
recvreq = WaitIO.Irecv!(recvbuf, comm; source=peer, tag=10)
sendreq = WaitIO.Isend(sendbuf, comm; dest=peer, tag=10)
# Other work may use other buffers here. Keep these buffers unchanged until completion.
WaitIO.Waitall([recvreq, sendreq])
@assert all(==(Float64(peer)), recvbuf)
println("exchange PASS rank=$rank peer=$peer count=$(length(recvbuf))")
WaitIO.Finalize()
