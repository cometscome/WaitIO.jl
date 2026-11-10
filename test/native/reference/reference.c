/* Independent native oracle: installed headers/libraries only, no package adapter.
 * One case per MPI launch, with one process in each of two WaitIO PBs.
 * dlsym selects the requested native symbol; a missing symbol is an error.
 */
#include <mpi.h>
#include <waitio.h>
#include <waitio_mpi.h>
#include <dlfcn.h>
#include <limits.h>
#include <stdint.h>

static void check(int rc, const char *where) {
    if (rc) { fprintf(stderr, "%s returned %d\n", where, rc); exit(2); }
}
static double input(const char *type, const char *op, int rank, int i) {
    if (!strcmp(type,"u8")) return !strcmp(op,"sum") ? rank+1 : (rank ? 100-i : 200+i);
    if (!strcmp(type,"i8")) return !strcmp(op,"sum") ? rank+1 : (rank ? 100-i : -56+i);
    if (!strcmp(type,"i64")) return 1099511627776.0 + rank*10+i;
    double x = (rank ? -10 : 10) + i;
    return type[0]=='f' ? x+0.25 : x;
}
static void put(void *p,const char *t,int i,double x) {
    if (!strcmp(t,"i32")) ((int*)p)[i]=(int)x;
    else if (!strcmp(t,"i64")) ((long*)p)[i]=(long)x;
    else if (!strcmp(t,"f32")) ((float*)p)[i]=(float)x;
    else if (!strcmp(t,"f64")) ((double*)p)[i]=x;
    else ((unsigned char*)p)[i]=(unsigned char)(int)x;
}
static void print_value(void *p,const char *t,int i) {
    if (!strcmp(t,"i32")) printf("%d",((int*)p)[i]);
    else if (!strcmp(t,"i64")) printf("%ld",((long*)p)[i]);
    else if (!strcmp(t,"f32")) printf("%.9g",(double)((float*)p)[i]);
    else if (!strcmp(t,"f64")) printf("%.17g",((double*)p)[i]);
    else if (!strcmp(t,"i8")) printf("%d",(int)((int8_t*)p)[i]);
    else printf("%u",(unsigned)((unsigned char*)p)[i]);
}
int main(int argc,char **argv) {
    if (argc!=7) { fprintf(stderr,"usage: reference ID OPERATION TYPE OP ROOT COUNT\n"); return 2; }
    const char *id=argv[1], *name=argv[2], *type=argv[3], *opname=argv[4];
    int root=atoi(argv[5]), count=atoi(argv[6]);
    if (count<0 || count>1024) return 2;
    int widened=!strcmp(type,"u8-wide") || !strcmp(type,"i8-wide");
    if (widened) type=type[0]=='u' ? "u8" : "i8";
    const char *storage=widened ? "i64" : type;
    int datatype, width;
    if (widened) { datatype=WAITIO_MPI_LONG; width=sizeof(long); }
    else if (!strcmp(type,"i32")) { datatype=WAITIO_MPI_INT; width=sizeof(int); }
    else if (!strcmp(type,"i64")) { datatype=WAITIO_MPI_LONG; width=sizeof(long); }
    else if (!strcmp(type,"f32")) { datatype=WAITIO_MPI_FLOAT; width=sizeof(float); }
    else if (!strcmp(type,"f64")) { datatype=WAITIO_MPI_DOUBLE; width=sizeof(double); }
    else if (!strcmp(type,"u8") || !strcmp(type,"i8")) { datatype=WAITIO_MPI_CHAR; width=1; }
    else return 2;
    int op=!strcmp(opname,"sum") ? WAITIO_MPI_SUM : !strcmp(opname,"min") ? WAITIO_MPI_MIN : WAITIO_MPI_MAX;
    printf("META\tchar_signed=%d\tlong_bytes=%zu\trequest_bytes=%zu\twidened_bytes=%d\n",CHAR_MIN<0,sizeof(long),sizeof(waitio_req_t),widened);
    fflush(stdout);
    if (sizeof(int)!=4 || sizeof(long)!=8) return 2;
    const char *library=getenv("REFERENCE_LIBWAITIO_MPI");
    if (!library) { fprintf(stderr,"REFERENCE_LIBWAITIO_MPI must name the installed library\n"); return 2; }
    void *handle=dlopen(library,RTLD_NOW|RTLD_GLOBAL);
    if (!handle) { fprintf(stderr,"%s\n",dlerror()); return 2; }
    char symbol[128]; snprintf(symbol,sizeof(symbol),"waitio_mpi_%s",name);
    void *fn=dlsym(handle,symbol);
    if (!fn && strcmp(name,"p2p")) { fprintf(stderr,"MISSING_SYMBOL %s: %s\n",symbol,dlerror()); return 77; }
    check(MPI_Init(&argc,&argv),"MPI_Init");
    waitio_group_t world;
    check(waitio_create_universe(&world),"waitio_create_universe");
    int typebytes=-99;
    int type_rc=waitio_mpi_type_size(datatype,&typebytes);
    printf("TYPE_SIZE\tstorage=%d\theader=%d\tnative=%d\trc=%d\n",width,waitio_mpi_dtypesize(datatype),typebytes,type_rc);
    fflush(stdout);
    int rank,size;
    check(waitio_group_rank(world,&rank),"waitio_group_rank");
    check(waitio_group_size(world,&size),"waitio_group_size");
    if (size!=2) { fprintf(stderr,"This fixture requires exactly two ranks\n"); return 2; }
    if (root==-1) root=size-1;
    if (root<0 || root>=size) return 2;
    void *send=calloc((size_t)(size*count+1),(size_t)width);
    void *recv=calloc((size_t)(size*count+1),(size_t)width);
    if (!send || !recv) return 2;
    for (int i=0;i<size*count;i++) {
        put(send,storage,i,input(type,opname,rank,i%count));
        put(recv,storage,i,7);
    }
    int rc, outcount=count, status[2]={-777,-777};
    if (!strncmp(name,"bcast",5)) {
        rc=((__typeof__(&waitio_mpi_bcast))fn)(send,count,datatype,root,world);
        memcpy(recv,send,(size_t)count*width);
    } else if (!strncmp(name,"allreduce",9)) {
        rc=((__typeof__(&waitio_mpi_allreduce))fn)(send,recv,count,datatype,op,world);
    } else if (!strncmp(name,"reduce",6)) {
        rc=((__typeof__(&waitio_mpi_reduce))fn)(send,recv,count,datatype,op,root,world);
        if (rank!=root) outcount=0;
    } else if (!strncmp(name,"allgather",9)) {
        rc=((__typeof__(&waitio_mpi_allgather))fn)(send,recv,count,datatype,world);
        outcount=size*count;
    } else if (!strncmp(name,"gather",6)) {
        rc=((__typeof__(&waitio_mpi_gather))fn)(send,recv,count,datatype,root,world);
        outcount=rank==root ? size*count : 0;
    } else if (!strncmp(name,"scatter",7)) {
        for (int r=0;r<size;r++) for (int i=0;i<count;i++) put(send,storage,r*count+i,input(type,opname,r,i));
        rc=((__typeof__(&waitio_mpi_scatter))fn)(send,count,datatype,recv,count,datatype,root,world);
    } else if (!strcmp(name,"p2p")) {
        waitio_req_t requests[2]; memset(requests,0,sizeof(requests));
        check(waitio_irecv(world,1-rank,recv,(size_t)count*width,91,&requests[0]),"byte irecv");
        check(waitio_isend(world,1-rank,send,(size_t)count*width,91,&requests[1]),"byte isend");
        check(waitio_wait(&requests[0]),"receive wait");
        rc=waitio_wait(&requests[1]);
    } else if (!strcmp(name,"waitall")) {
        waitio_req_t requests[2]; memset(requests,0,sizeof(requests));
        check(waitio_mpi_irecv(recv,count,datatype,1-rank,91,world,&requests[0]),"irecv");
        check(waitio_mpi_isend(send,count,datatype,1-rank,91,world,&requests[1]),"isend");
        rc=((__typeof__(&waitio_mpi_waitall))fn)(2,requests,status);
    } else return 2;
    printf("RESULT\t%s\t%d\t%d\t%d\t",id,rank,size,rc);
    for (int i=0;i<outcount;i++) {
        if (i) putchar(',');
        if (widened) {
            /* Explicit modulo-256 narrowing, without implementation-defined
             * conversion of an out-of-range value to signed char. */
            unsigned byte=(unsigned char)((long*)recv)[i];
            printf("%d",type[0]=='i' && byte>=128 ? (int)byte-256 : (int)byte);
        } else print_value(recv,type,i);
    }
    printf("\t");
    if (!strcmp(name,"waitall")) printf("%d,%d",status[0],status[1]);
    putchar('\n'); fflush(stdout);
    if (rc) return 2;
    check(waitio_finalize(),"waitio_finalize");
    check(MPI_Finalize(),"MPI_Finalize");
    free(send); free(recv);
    return 0;
}
