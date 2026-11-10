# A Julia-only, shared-directory test transport for independent processes.
# Atomic rename delivers whole messages. This does not model WaitIO networking.
include("mock.jl")
include("collective_fixture.jl")
module ProcessTransport
using ..NativeMock
using ..CollectiveFixture
using WaitIO
const W=WaitIO
const rank=Ref(0)
const npb=Ref(4)
const directory=Ref("")
const sequence=Dict{Tuple{Bool,UInt,Int,Culong},Int}()
const members=Dict{UInt,Vector{Int}}()
const pending=Dict{Ptr{Cvoid},Tuple{String,Ptr{Cvoid},Int}}()
function path(receive,g,peer,tag)
    peer=members[UInt(g)][Int(peer)+1]
    key=(receive,UInt(g),Int(peer),tag)
    n=get(sequence,key,0)+1; sequence[key]=n
    src,dst=receive ? (peer,rank[]) : (rank[],peer)
    joinpath(directory[],"$(UInt(g))-$src-$dst-$tag-$n")
end
function send(g,peer,b,n,tag,req)
    file=path(false,g,peer,tag)
    open(file*".writing","w") do io
        write(io,unsafe_wrap(Array,Ptr{UInt8}(b),Int(n)))
    end
    mv(file*".writing",file)
    Cint(0)
end
function recv(g,peer,b,n,tag,req)
    pending[req]=(path(true,g,peer,tag),b,Int(n))
    Cint(0)
end
function test(req)
    haskey(pending,req) || return Cint(0)
    file,b,n=pending[req]
    isfile(file) || return Cint(1)
    data=read(file)
    length(data)==n || return Cint(-89)
    GC.@preserve data unsafe_copyto!(Ptr{UInt8}(b),pointer(data),n)
    delete!(pending,req); rm(file)
    Cint(0)
end
function wait(req)
    deadline=time()+60
    while time()<deadline
        rc=test(req); rc==1 || return rc
        sleep(0.001)
    end
    Cint(-93)
end
getrank(g,p)=NativeMock.put(p,something(findfirst(==(rank[]),members[UInt(g)]),0)-1)
getsize(g,p)=NativeMock.put(p,length(members[UInt(g)]))
pbsize(p)=NativeMock.put(p,npb[])
pbrank(p)=NativeMock.put(p,rank[])
function nprocs(p)
    for i in 1:npb[]; unsafe_store!(p,Cint(1),i); end
    Cint(0)
end
function create(gid,filters,order)
    selected=Int[]
    for i in 1:npb[]
        pb=Int(unsafe_load(order,i))
        fn=unsafe_load(filters,pb+1)
        ccall(fn,Cint,(Cint,Cint),pb,0)!=0 && push!(selected,pb)
    end
    handle=Ptr{Cvoid}(UInt(gid+1)); members[UInt(handle)]=selected
    handle
end
function install(dir,r;n=4)
    directory[]=dir; rank[]=r; npb[]=n
    empty!(members); members[UInt(1)]=collect(0:n-1)
    NativeMock.install(;bytes=88)
    CollectiveFixture.install()
    p=W._library[].pointers
    p[:waitio_isend]=@cfunction(send,Cint,(Ptr{Cvoid},Cint,Ptr{Cvoid},Csize_t,Culong,Ptr{Cvoid}))
    p[:waitio_irecv]=@cfunction(recv,Cint,(Ptr{Cvoid},Cint,Ptr{Cvoid},Csize_t,Culong,Ptr{Cvoid}))
    p[:waitio_test]=@cfunction(test,Cint,(Ptr{Cvoid},))
    p[:waitio_wait]=@cfunction(wait,Cint,(Ptr{Cvoid},))
    p[:waitio_group_rank]=@cfunction(getrank,Cint,(Ptr{Cvoid},Ptr{Cint}))
    p[:waitio_group_size]=@cfunction(getsize,Cint,(Ptr{Cvoid},Ptr{Cint}))
    p[:waitio_get_nprocs]=@cfunction(nprocs,Cint,(Ptr{Cint},))
    p[:waitio_pb_size]=@cfunction(pbsize,Cint,(Ptr{Cint},))
    p[:waitio_pb_rank]=@cfunction(pbrank,Cint,(Ptr{Cint},))
    p[:waitio_create_group]=@cfunction(create,Ptr{Cvoid},(Cint,Ptr{Ptr{Cvoid}},Ptr{Cint}))
end
end
