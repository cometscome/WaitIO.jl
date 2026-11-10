/* Native C-only diagnostic: one MPI process in each of two WaitIO PBs. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <mpi.h>
#include <waitio.h>
#include <waitio_mpi.h>

static void check(int rc, const char *name) {
    if (rc != 0) { fprintf(stderr, "%s returned %d\n", name, rc); exit(2); }
}
int main(int argc, char **argv) {
    if (argc == 2 && !strcmp(argv[1], "--layout")) {
        printf("request_bytes = %zu\nrequest_alignment = %zu\ngroup_limit = %d\npb_limit = %d\n",
               sizeof(waitio_req_t), (size_t)__alignof__(waitio_req_t), NPBGMAX, NPBMAX);
        return 0;
    }
    check(MPI_Init(&argc, &argv), "MPI_Init");
    waitio_group_t world;
    check(waitio_create_universe(&world), "waitio_create_universe");
    int rank, size, bytes = -1;
    check(waitio_group_rank(world, &rank), "waitio_group_rank");
    check(waitio_group_size(world, &size), "waitio_group_size");
    check(waitio_mpi_type_size(WAITIO_MPI_LONG, &bytes), "waitio_mpi_type_size");
    printf("SIZES rank=%d long=%zu long_long=%zu header=%d library=%d datatype=%d\n",
           rank, sizeof(long), sizeof(long long), waitio_mpi_dtypesize(WAITIO_MPI_LONG), bytes, WAITIO_MPI_LONG);
    fflush(stdout);
    if (size != 2 || sizeof(long) != 8 || sizeof(long long) != 8) {
        fprintf(stderr, "Requires two ranks and 8-byte long/long long\n");
        return 2;
    }
    int failed = 0;
    for (int kind = 0; kind < 2; ++kind) {
        for (int count = 1; count <= 3; count += 2) {
            long sl[3], rl[3];
            long long sll[3], rll[3];
            for (int i = 0; i < 3; ++i) {
                sl[i] = (long)((1LL << 40) + rank*10 + i);
                sll[i] = (1LL << 40) + rank*10 + i;
                rl[i] = 7; rll[i] = 7;
            }
            int rc = waitio_mpi_allreduce(kind ? (const void *)sll : (const void *)sl,
                                         kind ? (void *)rll : (void *)rl,
                                         count, WAITIO_MPI_LONG, WAITIO_MPI_SUM, world);
            int ok = rc == 0;
            for (int i = 0; i < count; ++i) {
                long long actual = kind ? rll[i] : (long long)rl[i];
                long long expected = (1LL << 41) + 10 + 2*i;
                ok &= actual == expected;
                printf("VALUE rank=%d storage=%s count=%d index=%d expected=%lld actual=%lld\n",
                       rank, kind ? "long_long" : "long", count, i, expected, actual);
            }
            printf("PROBE rank=%d storage=%s count=%d rc=%d pass=%d\n", rank,
                   kind ? "long_long" : "long", count, rc, ok);
            fflush(stdout);
            failed |= !ok;
        }
    }
    check(waitio_finalize(), "waitio_finalize");
    check(MPI_Finalize(), "MPI_Finalize");
    return failed;
}
