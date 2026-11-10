"""Unchecked C API. Caller owns pointers and asynchronous buffer lifetimes. Use the high-level API unless native interoperation is required."""
module API
using ..WaitIO: _symbol, _call_lock, @locked

const SIGNATURES = Dict{Symbol,Tuple{Any,Tuple}}(
    :waitio_sock_rawread => (Cint, (Cint,Ptr{Cvoid},Cint)),
    :waitio_sock_rawwrite => (Cint, (Cint,Ptr{Cvoid},Cint)),
    :waitio_sock_blockwrite => (Cint, (Cint,Ptr{Cvoid},Cint)),
    :waitio_sock_blockread => (Cint, (Cint,Ptr{Cvoid},Cint)),
    :waitio_sock_setup => (Cint, (Cint,Cint)),
    :waitio_setup_epoll => (Cint, ()),
    :waitio_add_epoll => (Cint, (Cint,Cuint)),
    :waitio_connect_all => (Cint, (Ptr{Cvoid},)),
    :waitio_isend => (Cint, (Ptr{Cvoid},Cint,Ptr{Cvoid},Csize_t,Culong,Ptr{Cvoid})),
    :waitio_irecv => (Cint, (Ptr{Cvoid},Cint,Ptr{Cvoid},Csize_t,Culong,Ptr{Cvoid})),
    :waitio_wait => (Cint, (Ptr{Cvoid},)),
    :waitio_test => (Cint, (Ptr{Cvoid},)),
    :waitio_init => (Cint, (Cint,)),
    :waitio_finalize => (Cint, ()),
    :waitio_get_nprocs => (Cint, (Ptr{Cint},)),
    :waitio_create_group => (Ptr{Cvoid}, (Cint,Ptr{Ptr{Cvoid}},Ptr{Cint})),
    :waitio_pb_size => (Cint, (Ptr{Cint},)),
    :waitio_pb_rank => (Cint, (Ptr{Cint},)),
    :waitio_pb_hostinfo => (Cint, (Cint,Cint,Ptr{Cint},Ptr{Cint})),
    :waitio_group_rank => (Cint, (Ptr{Cvoid},Ptr{Cint})),
    :waitio_group_size => (Cint, (Ptr{Cvoid},Ptr{Cint})),
    :waitio_group_hostinfo => (Cint, (Ptr{Cvoid},Cint,Ptr{Cint},Ptr{Cint})),
    :waitio_group_ismember => (Cint, (Ptr{Cvoid},)),
    :waitio_create_group_wranks => (Ptr{Cvoid}, (Cint,Ptr{Ptr{Cint}},Ptr{Cint})),
    :waitio_register_mem => (Cvoid, (Ptr{Cvoid},Cint,Ptr{Ptr{Cvoid}})),
    :waitio_unregister_mem => (Cvoid, (Ptr{Cvoid},)),
    :truef => (Cint, (Cint,Cint)),
    :headf => (Cint, (Cint,Cint)),
    :waitio_free => (Cvoid, (Ptr{Cvoid},)),
    :waitio_mpi_bcast_layered => (Cint, (Ptr{Cvoid},Cint,Cint,Cint,Ptr{Cvoid})),
    :waitio_mpi_reduce_layered => (Cint, (Ptr{Cvoid},Ptr{Cvoid},Cint,Cint,Cint,Cint,Ptr{Cvoid})),
    :waitio_mpi_allreduce_layered => (Cint, (Ptr{Cvoid},Ptr{Cvoid},Cint,Cint,Cint,Ptr{Cvoid})),
    :waitio_mpi_bcast_Nnary => (Cint, (Ptr{Cvoid},Cint,Cint,Cint,Ptr{Cvoid})),
    :waitio_mpi_reduce_Nnary => (Cint, (Ptr{Cvoid},Ptr{Cvoid},Cint,Cint,Cint,Cint,Ptr{Cvoid})),
    :waitio_mpi_allreduce_Nnary => (Cint, (Ptr{Cvoid},Ptr{Cvoid},Cint,Cint,Cint,Ptr{Cvoid})),
    :waitio_mpi_gather_Nnary => (Cint, (Ptr{Cvoid},Ptr{Cvoid},Cint,Cint,Cint,Ptr{Cvoid})),
    :waitio_mpi_allgather_Nnary => (Cint, (Ptr{Cvoid},Ptr{Cvoid},Cint,Cint,Ptr{Cvoid})),
    :waitio_mpi_scatter_Nnary => (Cint, (Ptr{Cvoid},Cint,Cint,Ptr{Cvoid},Cint,Cint,Cint,Ptr{Cvoid})),
    :waitio_do_init => (Cint, (Ptr{Cvoid},Cint,Cint,Cint)),
    :waitio_do_reduce => (Cint, (Ptr{Cvoid},Ptr{Cvoid},Cint,Cint,Cint)),
    :waitio_mpi_isend => (Cint, (Ptr{Cvoid},Cint,Cint,Cint,Cint,Ptr{Cvoid},Ptr{Cvoid})),
    :WAITIO_MPI_Isend => (Cint, (Ptr{Cvoid},Cint,Cint,Cint,Cint,Ptr{Cvoid},Ptr{Cvoid})),
    :waitio_mpi_irecv => (Cint, (Ptr{Cvoid},Cint,Cint,Cint,Cint,Ptr{Cvoid},Ptr{Cvoid})),
    :WAITIO_MPI_Irecv => (Cint, (Ptr{Cvoid},Cint,Cint,Cint,Cint,Ptr{Cvoid},Ptr{Cvoid})),
    :waitio_mpi_send => (Cint, (Ptr{Cvoid},Cint,Cint,Cint,Cint,Ptr{Cvoid})),
    :WAITIO_MPI_Send => (Cint, (Ptr{Cvoid},Cint,Cint,Cint,Cint,Ptr{Cvoid})),
    :waitio_mpi_recv => (Cint, (Ptr{Cvoid},Cint,Cint,Cint,Cint,Ptr{Cvoid})),
    :WAITIO_MPI_Recv => (Cint, (Ptr{Cvoid},Cint,Cint,Cint,Cint,Ptr{Cvoid})),
    :waitio_mpi_reduce => (Cint, (Ptr{Cvoid},Ptr{Cvoid},Cint,Cint,Cint,Cint,Ptr{Cvoid})),
    :WAITIO_MPI_Reduce => (Cint, (Ptr{Cvoid},Ptr{Cvoid},Cint,Cint,Cint,Cint,Ptr{Cvoid})),
    :waitio_mpi_bcast => (Cint, (Ptr{Cvoid},Cint,Cint,Cint,Ptr{Cvoid})),
    :WAITIO_MPI_Bcast => (Cint, (Ptr{Cvoid},Cint,Cint,Cint,Ptr{Cvoid})),
    :waitio_mpi_allreduce => (Cint, (Ptr{Cvoid},Ptr{Cvoid},Cint,Cint,Cint,Ptr{Cvoid})),
    :WAITIO_MPI_Allreduce => (Cint, (Ptr{Cvoid},Ptr{Cvoid},Cint,Cint,Cint,Ptr{Cvoid})),
    :waitio_mpi_waitall => (Cint, (Cint,Ptr{Cvoid},Ptr{Cint})),
    :WAITIO_MPI_Waitall => (Cint, (Cint,Ptr{Cvoid},Ptr{Cint})),
    :waitio_create_universe => (Cint, (Ptr{Ptr{Cvoid}},)),
    :waitio_create_universe_pbhead => (Cint, (Ptr{Ptr{Cvoid}},)),
    :waitio_mpi_gather => (Cint, (Ptr{Cvoid},Ptr{Cvoid},Cint,Cint,Cint,Ptr{Cvoid})),
    :WAITIO_MPI_Gather => (Cint, (Ptr{Cvoid},Ptr{Cvoid},Cint,Cint,Cint,Ptr{Cvoid})),
    :waitio_mpi_allgather => (Cint, (Ptr{Cvoid},Ptr{Cvoid},Cint,Cint,Ptr{Cvoid})),
    :WAITIO_MPI_Allgather => (Cint, (Ptr{Cvoid},Ptr{Cvoid},Cint,Cint,Ptr{Cvoid})),
    :waitio_mpi_scatter => (Cint, (Ptr{Cvoid},Cint,Cint,Ptr{Cvoid},Cint,Cint,Cint,Ptr{Cvoid})),
    :WAITIO_MPI_Scatter => (Cint, (Ptr{Cvoid},Cint,Cint,Ptr{Cvoid},Cint,Cint,Cint,Ptr{Cvoid})),
    :waitio_mpi_scatterv => (Cint, (Ptr{Cvoid},Ptr{Cint},Ptr{Cint},Cint,Ptr{Cvoid},Cint,Cint,Cint,Ptr{Cvoid})),
    :WAITIO_MPI_Scatterv => (Cint, (Ptr{Cvoid},Ptr{Cint},Ptr{Cint},Cint,Ptr{Cvoid},Cint,Cint,Cint,Ptr{Cvoid})),
    :waitio_mpi_gatherv => (Cint, (Ptr{Cvoid},Cint,Cint,Ptr{Cvoid},Ptr{Cint},Ptr{Cint},Cint,Cint,Ptr{Cvoid})),
    :WAITIO_MPI_Gatherv => (Cint, (Ptr{Cvoid},Cint,Cint,Ptr{Cvoid},Ptr{Cint},Ptr{Cint},Cint,Cint,Ptr{Cvoid})),
    :waitio_mpi_allgatherv => (Cint, (Ptr{Cvoid},Cint,Cint,Ptr{Cvoid},Ptr{Cint},Ptr{Cint},Cint,Ptr{Cvoid})),
    :WAITIO_MPI_Allgatherv => (Cint, (Ptr{Cvoid},Cint,Cint,Ptr{Cvoid},Ptr{Cint},Ptr{Cint},Cint,Ptr{Cvoid})),
    :waitio_mpi_scan => (Cint, (Ptr{Cvoid},Ptr{Cvoid},Cint,Cint,Cint,Ptr{Cvoid})),
    :WAITIO_MPI_Scan => (Cint, (Ptr{Cvoid},Ptr{Cvoid},Cint,Cint,Cint,Ptr{Cvoid})),
    :waitio_mpi_exscan => (Cint, (Ptr{Cvoid},Ptr{Cvoid},Cint,Cint,Cint,Ptr{Cvoid})),
    :WAITIO_MPI_Exscan => (Cint, (Ptr{Cvoid},Ptr{Cvoid},Cint,Cint,Cint,Ptr{Cvoid})),
    :waitio_mpi_alltoall => (Cint, (Ptr{Cvoid},Cint,Cint,Ptr{Cvoid},Cint,Cint,Ptr{Cvoid})),
    :WAITIO_MPI_Alltoall => (Cint, (Ptr{Cvoid},Cint,Cint,Ptr{Cvoid},Cint,Cint,Ptr{Cvoid})),
    :waitio_mpi_type_size => (Cint, (Cint,Ptr{Cint})),
    :WAITIO_MPI_Type_size => (Cint, (Cint,Ptr{Cint})),
    :waitio_mpi_barrier => (Cint, (Ptr{Cvoid},)),
    :WAITIO_MPI_Barrier => (Cint, (Ptr{Cvoid},)),
)

for (name,(result,types)) in SIGNATURES
    args = [Symbol(:arg,i) for i in eachindex(types)]
    signature = Expr(:tuple,types...)
    @eval @locked function $name($(args...))
        ccall(_symbol($(QuoteNode(name))), $result, $signature, $(args...))
    end
end

waitio_mpi_dtypesize(datatype) = ccall(_symbol(:wjl_dtypesize),Cint,(Cint,),datatype)

"Allocate an opaque native request for raw C interoperation; caller must keep it stable until completion."
request_alloc() = ccall(_symbol(:wjl_request_alloc),Ptr{Cvoid},())
"Free only an inactive raw request. Never call this on a high-level Request.native."
request_free(ptr::Ptr) = ccall(_symbol(:wjl_request_free),Cvoid,(Ptr{Cvoid},),ptr)
request_size() = Int(ccall(_symbol(:wjl_request_size),Csize_t,()))
"Resolve a declared C function, including callbacks such as truef/headf."
function function_pointer(name::Symbol)
    haskey(SIGNATURES,name) || throw(ArgumentError("not a declared C function"))
    _symbol(name)
end

"Unsafe address of a public native global; no Julia layout or ownership is implied."
function global_pointer(name::Symbol)
    name in (:wdebug,:WIOinst,:PBGroup,:waitio_myhost,:waitio_pbid,:waitio_sockfd,:waitio_master_sockfd) ||
        throw(ArgumentError("not a public waitio.h global"))
    _symbol(name)
end

end # module API
