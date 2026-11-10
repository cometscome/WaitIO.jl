# Pass the separately compiled sentinel .so; no MPI or native WaitIO needed.
using WaitIO, Libdl, Test
const W=WaitIO
lib=Libdl.dlopen(only(ARGS))
@testset "distinct C symbols, including legacy configuration" begin
    for (compat,fixes) in ((false,false),(true,false),(false,true),(true,true))
        config=W.LibraryConfig(miyabi_compat=compat,native_fixes=fixes)
        W._library[]=W.LibraryState(config,lib,lib,Dict(),Dict(),Dict())
        @test W.API.waitio_mpi_reduce_layered(C_NULL,C_NULL,0,0,0,0,C_NULL)==101
        @test W.API.waitio_mpi_reduce_Nnary(C_NULL,C_NULL,0,0,0,0,C_NULL)==202
        @test W.API.waitio_mpi_scatter_Nnary(C_NULL,0,0,C_NULL,0,0,0,C_NULL)==303
        @test W.API.waitio_mpi_scatter(C_NULL,0,0,C_NULL,0,0,0,C_NULL)==404
        @test W.API.waitio_mpi_barrier(C_NULL)==505
        @test W.API.WAITIO_MPI_Barrier(C_NULL)==606
        status=zeros(Cint,2)
        @test W.API.waitio_mpi_waitall(2,C_NULL,status)==707
        @test status==[700,701]
        handle=Ref{Ptr{Cvoid}}(C_NULL)
        W.API.waitio_register_mem(C_NULL,0,handle)
        @test handle[]==Ptr{Cvoid}(UInt(0x1234))
        @test_throws W.UnsupportedFeatureError W.API.function_pointer(:WAITIO_MPI_Allgatherv)
        @test isempty(W.library_info().aliases)
    end
end
