/* Peer for exchange.jl: 1024 Float64/double values, native byte transport, tag 10.
 * Build with the local MPI compiler and the installed WaitIO headers/libraries.
 */
#include <stdio.h>
#include <stdlib.h>
#include <mpi.h>
#include <waitio.h>
#include <waitio_mpi.h>

static void check(int rc, const char *operation) {
    if (rc != 0) {
        fprintf(stderr, "%s returned %d\n", operation, rc);
        MPI_Abort(MPI_COMM_WORLD, 1);
        exit(1);
    }
}

int main(int argc, char **argv) {
    if (sizeof(double) != 8) {
        fprintf(stderr, "This example requires an 8-byte IEEE 754 double\n");
        return 1;
    }
    if (MPI_Init(&argc, &argv) != MPI_SUCCESS) return 1;
    waitio_group_t comm;
    check(waitio_create_universe(&comm), "create_universe");
    int rank, size;
    check(waitio_group_rank(comm, &rank), "group_rank");
    check(waitio_group_size(comm, &size), "group_size");
    if (size != 2) {
        fprintf(stderr, "Launch one process in each of two parallel blocks\n");
        MPI_Abort(MPI_COMM_WORLD, 1);
        return 1;
    }
    double sendbuf[1024], recvbuf[1024] = {0};
    for (int i = 0; i < 1024; ++i) sendbuf[i] = (double)rank;
    waitio_req_t requests[2] = {0};
    check(waitio_irecv(comm, 1-rank, recvbuf, sizeof(recvbuf), 10, &requests[0]), "irecv");
    check(waitio_isend(comm, 1-rank, sendbuf, sizeof(sendbuf), 10, &requests[1]), "isend");
    check(waitio_wait(&requests[0]), "receive wait");
    check(waitio_wait(&requests[1]), "send wait");
    for (int i = 0; i < 1024; ++i) {
        if (recvbuf[i] != (double)(1-rank)) {
            fprintf(stderr, "Unexpected value at index %d: %.17g\n", i, recvbuf[i]);
            MPI_Abort(MPI_COMM_WORLD, 1);
            return 1;
        }
    }
    printf("exchange PASS rank=%d peer=%d count=1024\n", rank, 1-rank);
    check(waitio_finalize(), "finalize");
    return MPI_Finalize() == MPI_SUCCESS ? 0 : 1;
}
