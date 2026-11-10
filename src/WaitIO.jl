"""
    WaitIO

Julia interface to WaitIO inter-job communication.

Loading the package does not load a native library or initialize communication.
"""
module WaitIO

using Libdl, SHA, TOML, Serialization
import Preferences

include("locking.jl")
include("errors.jl")
include("configuration.jl")
include("api.jl")
include("julia_library.jl")
include("setup.jl")
include("runtime.jl")
include("buffers.jl")
include("requests.jl")
include("collectives.jl")
include("inplace.jl")
include("extensions.jl")
include("memory.jl")
include("objects.jl")

end # module WaitIO
