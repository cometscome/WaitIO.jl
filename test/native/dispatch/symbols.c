/* Dispatch sentinels, not a WaitIO implementation or a communication test. */
#include <stddef.h>
#include <stdint.h>
int waitio_mpi_reduce_layered(const void *s, void *r, int n, int d, int op, int root, void *g) { return 101; }
int waitio_mpi_reduce_Nnary(const void *s, void *r, int n, int d, int op, int root, void *g) { return 202; }
int waitio_mpi_scatter_Nnary(void *s, int sn, int st, void *r, int rn, int rt, int root, void *g) { return 303; }
int waitio_mpi_scatter(void *s, int sn, int st, void *r, int rn, int rt, int root, void *g) { return 404; }
int waitio_mpi_barrier(void *g) { return 505; }
int WAITIO_MPI_Barrier(void *g) { return 606; }
int waitio_mpi_waitall(int n, void *q, int *status) {
    for (int i=0;i<n;i++) status[i]=700+i;
    return 707;
}
void waitio_register_mem(void *p, int n, void **handle) { *handle=(void *)(uintptr_t)0x1234; }
void waitio_unregister_mem(void *handle) { }
int waitio_mpi_allgatherv(const void *s,int n,int st,void *r,const int *c,const int *d,int rt,void *g) { return 808; }
/* Deliberately no uppercase Allgatherv: a missing symbol must stay missing. */
