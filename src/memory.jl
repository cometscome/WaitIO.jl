mutable struct RegisteredMemory
    buffer::Buffer
    handle::Ptr{Cvoid}
    runtime::Runtime
    users::Int
    active::Bool
end
Buffer(m::RegisteredMemory) = m.active ? Buffer(m.buffer) : throw(ArgumentError("memory was unregistered"))
function _overlap(a::Buffer,b::Buffer)
    x=UInt(_pointer(a)); y=UInt(_pointer(b))
    _nbytes(a)>0 && _nbytes(b)>0 && x<y+UInt(_nbytes(b)) && y<x+UInt(_nbytes(a))
end
function _registered_buffers(r,b)
    Any[m for m in keys(r.registrations) if m.active && _overlap(m.buffer,b)]
end
"Register host memory with the selected transport. Native API returns void; a non-NULL handle is required."
@locked function Register!(data)
    r=_rt(); b=Buffer(data); bytes=_count(_nbytes(b))
    bytes>0 || throw(ArgumentError("cannot register an empty buffer"))
    isempty(_registered_buffers(r,b)) || throw(ArgumentError("overlapping memory already registered"))
    any(req -> req.buffer!==nothing && _overlap(req.buffer,b),keys(r.requests)) &&
        throw(ArgumentError("cannot register a buffer while it is in flight"))
    handle=Ref{Ptr{Cvoid}}(C_NULL)
    GC.@preserve b API.waitio_register_mem(_pointer(b),bytes,handle)
    handle[]==C_NULL && throw(WaitIOError(:waitio_register_mem,-1,"transport returned no memory handle"))
    memory=RegisteredMemory(b,handle[],r,0,true)
    r.registrations[memory]=nothing
    memory
end
@locked function Unregister!(memory::RegisteredMemory)
    memory.active || return nothing
    memory.runtime===_rt() || throw(ArgumentError("memory belongs to another runtime"))
    memory.users==0 || throw(ArgumentError("registered memory still has active requests"))
    API.waitio_unregister_mem(memory.handle)
    memory.active=false; memory.handle=C_NULL
    delete!(memory.runtime.registrations,memory)
    nothing
end
