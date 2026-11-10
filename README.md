# WaitIO.jl

**MPI.jl-style communication for coupling applications across heterogeneous supercomputers.**

WaitIO.jl connects Julia applications to independently launched parallel programs
through **h3-Open-SYS/WaitIO**. Each application keeps its own MPI environment.
This makes it possible to couple a simulation with Julia-based analysis or learning
across heterogeneous HPC systems. The currently targeted systems are **Wisteria/BDEC-01
(Odyssey and Aquarius)** and **Miyabi (G and C)**.

[Japanese README](inJapanese/README.md) ·
[Tutorials, talks, and papers](docs/WAITIO_RESOURCES.md)

## Why WaitIO?

Suppose a simulation runs on a CPU system and a separate application analyzes its
results on a GPU system. To exchange intermediate results while both applications
run, they need to agree on communication partners, data, and synchronization.
This exchange is **application coupling**. The two applications may use different
MPI libraries, processors, and interconnects.

WaitIO provides communication between these independently launched MPI programs,
while their internal communication can continue to use local MPI. This design is
described in the WaitIO-Socket paper by
[Sumimoto et al. (2023)](https://doi.org/10.1007/978-3-031-29927-8_25).

MPI also offers connections between process groups through
[`MPI_Comm_connect` and `MPI_Comm_accept`](https://docs.open-mpi.org/en/main/man-openmpi/man3/MPI_Comm_accept.3.html).
Their availability depends on the MPI implementation and execution environment;
these APIs do not by themselves guarantee interoperability between arbitrary MPI
implementations. WaitIO supplies a separate communication layer for coupling.

## What does WaitIO.jl provide?

WaitIO.jl is the Julia interface to WaitIO. It offers MPI.jl-inspired operations
for arrays, nonblocking requests, and collectives, plus serialization for exchanging
Julia objects between Julia processes. Requests retain their buffers until completion.
Low-level wrappers are declared for 80 C function names; availability depends on
the installed WaitIO build. See [supported environments and limitations](#tested-environments-and-limitations).

WaitIO.jl uses the WaitIO and MPI libraries and headers installed at each site.

**Upstream availability (November 2026):** WaitIO itself is not yet open source,
and its source code is not publicly released. An open-source release is planned.
WaitIO.jl is distributed under the [MIT License](LICENSE).

## How it fits together

```text
Supercomputer / subsystem A                 Supercomputer / subsystem B
MPI program: simulation                    MPI program: analysis or learning
Julia, C, or Fortran                        Julia + WaitIO.jl
        |                                          |
        +-------------- WaitIO --------------------+
        local MPI A                        local MPI B
```

Each independently launched MPI program forms a **parallel block (PB)**. WaitIO
connects these blocks; `WaitIO.Comm_world()` spans the participating processes.
Local MPI communication can remain within each program. Socket and shared-file
communication are described in
[WaitIO-Hybrid (Sumimoto et al., 2025)](https://doi.org/10.1007/978-981-96-4207-6_13).
Upstream RDMA transports are described in
[Sumimoto et al. (2025)](https://doi.org/10.1145/3703001.3724382).

Wisteria's Odyssey/Aquarius and Miyabi's G/C subsystems are examples of this
heterogeneous setup. Connecting separate supercomputers also requires a supported
WaitIO transport, site-provided connectivity, and coordinated job scheduling. The
[upstream literature](docs/WAITIO_RESOURCES.md) also describes work on communication
between computing centers; that deployment has not been tested with this package.

## Familiar to MPI.jl users

The API follows the naming and buffer conventions of
[MPI.jl](https://juliaparallel.org/MPI.jl/stable/usage/):

| Operation | MPI.jl | WaitIO.jl |
| --- | --- | --- |
| Initialize | `MPI.Init()` | `WaitIO.Init()` |
| World communicator | `MPI.COMM_WORLD` | `WaitIO.Comm_world()` |
| Rank / size | `MPI.Comm_rank(comm)` / `MPI.Comm_size(comm)` | `WaitIO.Comm_rank(comm)` / `WaitIO.Comm_size(comm)` |
| Nonblocking array send | `MPI.Isend(buf, comm; dest, tag)` | `WaitIO.Isend(buf, comm; dest, tag)` |
| Nonblocking array receive | `MPI.Irecv!(buf, comm; source, tag)` | `WaitIO.Irecv!(buf, comm; source, tag)` |
| Complete requests | `MPI.Waitall(requests)` | `WaitIO.Waitall(requests)` |
| Reduce across ranks | `MPI.Allreduce!(src, dst, MPI.SUM, comm)` | `WaitIO.Allreduce!(src, dst, WaitIO.SUM, comm)` |

This is API familiarity, not a drop-in implementation of MPI.jl or the entire MPI
standard. WaitIO communicators and requests belong to WaitIO. Ranks and PB IDs
start at **0**; Julia array indices start at **1**. MPI.jl is not a dependency.

## Install

Requirements:

- Julia 1.10 or later on little-endian, 64-bit Linux (x86_64 or aarch64).
- Site-provided WaitIO libraries and headers, including its collective library.
- The MPI runtime used by that site's WaitIO.
- A supported WaitIO installation, checked during setup.
- Job allocations and a working WaitIO connection between the participating systems.

Install directly from this repository:

```julia
using Pkg
Pkg.add(url="https://github.com/cometscome/WAITIO.jl.git")
```

Load the package with `using WaitIO`.

## Configure each system

### Choose a site alias

Load the matching MPI modules, set `WAITIO_COMM_TYPE=socket`, and run setup on the
selected target system with your application's Julia project active. For example,
on Miyabi-G:

```julia
using WaitIO
WaitIO.use_system_library("miyabi-dev-g")
```

The alias supplies the library/header paths and settings for that system.
Setup validates the installation and saves the configuration.

| Alias | Target | MPI modules |
| --- | --- | --- |
| `miyabi-dev-g` | aarch64 / NVIDIA, development WaitIO | `nvidia/24.9 nv-hpcx/24.9` |
| `miyabi-dev-c` | x86_64 / Intel, development WaitIO | `intel/2023.2.0 impi/2021.10.0` |
| `miyabi-g` | aarch64 / NVIDIA | `nvidia/25.9 nv-hpcx/25.9` |
| `miyabi-c` | x86_64 / Intel | `intel/2023.2.0 impi/2021.10.0` |
| `wisteria-odyssey` | aarch64 / A64FX | `fj/1.2.43 fjmpi/1.2.43` |
| `wisteria-aquarius` | x86_64 / Intel | `intel/2023.0.0 impi/2021.8.0` |

Ensure the selected WaitIO installation's shared-library dependencies are
available. For the development Miyabi aliases, add its directories after loading
the MPI modules above:

```sh
export WAITIO_DIR=/work/share/waitio-rt/opt/waitio
export LD_LIBRARY_PATH="$WAITIO_DIR/lib:/usr/ofed/lib:${LD_LIBRARY_PATH:-}"
export PATH="$WAITIO_DIR/bin:$PATH"
```

For the other aliases, also load the site's `waitio/1.0` module.
Wisteria's aliases select the tested installation under
`/work/share/waitio-rt/opt/waitio`, which can differ from a module's default path.
The `miyabi-dev-c` and `miyabi-dev-g` aliases select the developer-recommended
development installation under `/work/share/waitio-rt/opt/waitio`. Use these
aliases for that build; its 360-byte request layout differs from the older
module installation. The original `miyabi-c` and `miyabi-g` aliases still select
the corresponding installation under `/work/opt/local`.
Inspect every default without loading libraries or writing files:

```julia
WaitIO.site_defaults("wisteria-odyssey")
# library_dir = "/work/share/waitio-rt/opt/waitio/lib"
# include_dir = "/work/share/waitio-rt/opt/waitio/include"
# variant = "a64fx", abi_profile = "wisteria-352", ...
```

The aliases use installation paths verified in November 2026. Re-run setup after
site upgrades to check compatibility. `WAITIO_LIB` and `WAITIO_INC` do not override
alias paths. To use a relocated installation,
pass explicit `library_dir` and `include_dir` keywords; an unsupported ABI still
fails validation. Full `libwaitio`/`libwaitio_mpi` paths can replace the default pair.

By default, setup saves through **Preferences.jl** in the active project's local
preferences (`LocalPreferences.toml`, or an existing `JuliaLocalPreferences.toml`).
Run Julia with `--project=/path/to/your/project`, then start a fresh Julia process
for the application. Existing differing preferences require `force=true`.
For a project shared by two systems, use **separate configuration files** as below.

### Explicit paths or module discovery

For a custom installation, specify its library and header paths:

```julia
WaitIO.use_system_library(
    libwaitio     = "/site/waitio/lib/libwaitio_intel.so",
    libwaitio_mpi = "/site/waitio/lib/libwaitio_mpi_intel.so",
    include_dir  = "/site/waitio/include",
)
```

Without an alias, `WaitIO.use_system_library()` discovers libraries from
`WAITIO_LIB` and headers from `WAITIO_INC`. Multiple pairs require a `variant`
such as `"intel"` or `"nvidia"`, or both explicit library paths. The site test
jobs use `WAITIO_COMM_TYPE=socket`. Site aliases select library paths and ABI
profiles; they do not replace the installed communication functions.

`libwaitio_mpi` is WaitIO's collective communication library, not MPI's `libmpi.so`.
Headers (`waitio.h`, `waitio_mpi.h`, `waitio-lib.h`) are required for ABI validation.
All paths must be accessible from the target compute nodes. Re-run setup when
changing the installation. In an application repository, ignore local preferences,
generated `config/*.toml`, and local depot directories.

### One shared project, separate G/C configurations

Use the same application, `Project.toml`, and `Manifest.toml` on both systems.
Select a complete configuration file in each job instead of overwriting shared
project preferences. The following setup commands run on the respective target
systems after loading their matching MPI and WaitIO modules:

```julia
# Miyabi-G: run once with WAITIO_COMM_TYPE=socket
using WaitIO
WaitIO.use_system_library(
    "miyabi-dev-g"; config_file="config/miyabi-g.toml",
)
```

```julia
# Miyabi-C: run once with WAITIO_COMM_TYPE=socket
using WaitIO
WaitIO.use_system_library(
    "miyabi-dev-c"; config_file="config/miyabi-c.toml",
)
```

Both commands are run from the shared application directory with `julia --project=.`.
An existing named file requires `force=true` to replace it. Regular application
runs only read configuration and never write preferences or install packages.

```bash
# G job: cd to the shared application directory, then load the site's G modules
export WAITIO_JL_CONFIG="$PWD/config/miyabi-g.toml"
export JULIA_DEPOT_PATH="$PWD/depot-g:"
export WAITIO_COMM_TYPE=socket
# Also set the PB ID, participant count, and rendezvous host/port for this job.
mpirun -np 1 julia --project=. simulation.jl
```

```bash
# C job: same application directory, with the site's C modules loaded
export WAITIO_JL_CONFIG="$PWD/config/miyabi-c.toml"
export JULIA_DEPOT_PATH="$PWD/depot-c:"
export WAITIO_COMM_TYPE=socket
# Set this participant's PB ID and the common rendezvous settings.
mpiexec.hydra -n 1 julia --project=. simulation.jl
```

Install/instantiate dependencies for **both** depots before submitting jobs;
do not run `Pkg.add`, `Pkg.update`, or setup concurrently against one preferences
file. A trailing `:` in `JULIA_DEPOT_PATH` retains Julia's system depots; it does
not retain the usual user depot. An offline site can append a prepared read-only
depot containing the required package sources. The
[shared-project test templates](test/native/miyabi/README.md) use that arrangement.
The calculation itself needs only `using WaitIO; WaitIO.Init()` before communication.
Both peers must use compatible WaitIO protocols; serialized Julia objects also
require matching Julia versions and type definitions.

### Wisteria: one project, separate Odyssey/Aquarius configurations

Use the same pattern, running each setup call on its target system:

```julia
# On Odyssey, with Fujitsu MPI loaded:
using WaitIO
WaitIO.use_system_library("wisteria-odyssey"; config_file="config/odyssey.toml")
```

```julia
# On Aquarius, with Intel MPI loaded:
using WaitIO
WaitIO.use_system_library("wisteria-aquarius"; config_file="config/aquarius.toml")
```

In the Odyssey job, select `WAITIO_JL_CONFIG="$PWD/config/odyssey.toml"` and a
separate writable depot, for example `JULIA_DEPOT_PATH="$PWD/depot-o:"`. In the
Aquarius job use `config/aquarius.toml` and `depot-a:` instead. Prepare dependencies
in both depots first. Load the matching modules and follow the
[paired Wisteria job procedure](test/native/wisteria/README.md) for socket transport,
master discovery, host suffix, shared-library search paths, and launchers.
The aliases configure Julia's library selection; they do not set up this job environment.

### Configuration precedence and diagnostics

In a fresh process, resolution uses:

1. Explicit `configure!` keyword arguments.
2. `WAITIO_JL_LIBWAITIO`, `WAITIO_JL_LIBWAITIO_MPI`, `WAITIO_JL_INCLUDE_DIR`, and
   `WAITIO_JL_ABI_PROFILE` overrides.
3. The file selected by `WAITIO_JL_CONFIG`, **or**, when unset, Preferences.jl settings.

An explicit file must contain nonempty `libwaitio`, `libwaitio_mpi`, and
`include_dir`. Missing files/fields are errors; project or administrator preferences
never fill gaps in an explicitly selected file. Overrides are reported, and the
final library/header combination is validated before communication. Passing a
`LibraryConfig` directly to `configure!` replaces the entire effective configuration.
`use_system_library` uses explicit arguments, alias defaults, or module paths
(`WAITIO_LIB`/`WAITIO_INC`) to create a configuration. Saved settings and
`WAITIO_JL_*` runtime overrides do not affect setup.

```julia
WaitIO.configuration_info()          # effective values and origin; no library load
WaitIO.check_library(verbose=true)   # load/check locally and print paths, ABI, origin
WaitIO.library_info()                # loaded configuration and ABI metadata
```

Once native libraries are loaded, changing the configuration requires a fresh
Julia process.

Preferences.jl also supports administrator defaults through environments on
`JULIA_LOAD_PATH`, with project preferences taking precedence. For example, a site
can place its settings in a `Project.toml` on that path:

```toml
[extras]
WaitIO = "d19786dc-c986-4b1d-9838-faa08bcbccac"

[preferences.WaitIO]
libwaitio = "/site/waitio/lib/libwaitio_intel.so"
libwaitio_mpi = "/site/waitio/lib/libwaitio_mpi_intel.so"
include_dir = "/site/waitio/include"
```

Keep the normal `@` and `@stdlib` entries when adjusting `JULIA_LOAD_PATH`.
See [Preferences.jl](https://juliapackaging.github.io/Preferences.jl/stable/) for
inheritance details. If MPI.jl is also loaded in the same process, configure it to
use the same native MPI implementation as WaitIO; loading another MPI implementation
into that process is unsupported.

### Installation compatibility

Setup checks that the library architecture, headers, and binary interface match a
supported installation. If validation fails after a site upgrade, check the loaded
modules and selected paths before running your application. Details for additional
installations are in the [library compatibility guide](docs/COMPILER_FREE.md).

## Run two communicating jobs

Configure and launch **both** participants using the site's WaitIO job procedure.
For a two-block socket connection, the job environments agree on
`WAITIO_NPB=2`, `WAITIO_COMM_TYPE=socket`, `WAITIO_MASTER_HOST`, and
`WAITIO_MASTER_PORT`, and use distinct `WAITIO_PBID` values, 0 and 1.
The master hostname must be reachable through the selected compute-node network.
Site scripts may discover it using `waitio-serv`; some sites also require a host
suffix or coordinated coupler queues.

Within each allocation, launch Julia with that system's MPI launcher. For example,
after setting the environment and selecting the site configuration:

```sh
# Run once in each job, with one process in each parallel block.
mpiexec -n 1 julia --project=/path/to/project exchange.jl
```

The launcher command alone is not a complete batch script. Use the
[Miyabi paired PBS templates](test/native/miyabi/README.md) or the
[Wisteria tutorial](https://www.cc.u-tokyo.ac.jp/events/lectures/236/20241030-2.pdf)
for scheduling and rendezvous setup. Both jobs must be running for communication
to complete.

Save the following as `exchange.jl` on both systems:

```julia
using WaitIO

WaitIO.Init()
comm = WaitIO.Comm_world()
rank = WaitIO.Comm_rank(comm)
@assert WaitIO.Comm_size(comm) == 2
peer = 1 - rank

sendbuf = fill(Float64(rank), 1024)
recvbuf = zeros(1024)
recvreq = WaitIO.Irecv!(recvbuf, comm; source=peer, tag=10)
sendreq = WaitIO.Isend(sendbuf, comm; dest=peer, tag=10)

# Computation using other buffers can run here.
WaitIO.Waitall([recvreq, sendreq])
@assert all(==(Float64(peer)), recvbuf)
println("Rank $rank received data from rank $peer")
WaitIO.Finalize()
```

Requests retain their buffers until completion. Do not modify or resize active
send buffers, or read or modify active receive buffers. Arrays with `isbits`
elements can be transferred, including complex numbers and pointer-free structs.
Noncontiguous views are packed automatically. Device arrays use host staging when
they implement `Array` and bulk `copyto!`; this is not GPU-direct communication.
Staging adds copies and memory use. Actual GPU hardware has not yet been tested.
Array peers must agree on element types, lengths, and byte order. `Send` and
`Recv!` provide blocking operations; `Test`, `Wait`, `Waitall`, and `Drain` manage
completion.

Nonblocking calls let an application defer waiting, but do not establish that
communication progresses independently or overlaps computation efficiently.
Those properties require measurement with the intended workload and transport.

## Coupling with C or Fortran

Keep the existing program's local MPI setup and add WaitIO communication at the
points where it exchanges data with Julia. Programs already using a compatible
WaitIO exchange may reuse that interface; arbitrary simulation code still needs
coupling calls and an agreed protocol.

Start with contiguous host arrays. Both sides must agree on element representation,
element count, peer ranks, tags, message order, and synchronization. For example,
a `Float64` array needs a matching 64-bit floating-point representation and byte
order at the other end. WaitIO.jl does not automatically translate arbitrary
C/Fortran structures or convert endianness. Julia's serialized objects, described
below, are for Julia peers. Higher-level tasks such as grid interpolation belong
to the application or a separate coupler such as h3-Open-UTIL/MP.

## Transfer a custom Julia type

Lowercase `send`, `recv`, and `isend` use Julia's `Serialization`. Run this script
on both ranks using matching Julia versions and the same type definition:

```julia
using WaitIO

struct TrainingBatch{T}
    name::String
    coordinates::Matrix{T}
    metadata::Dict{String,Int}
end

WaitIO.Init()
comm = WaitIO.Comm_world()
@assert WaitIO.Comm_size(comm) == 2

if WaitIO.Comm_rank(comm) == 0
    batch = TrainingBatch("sample", ones(3, 100), Dict("step" => 10))
    request = WaitIO.isend(batch, comm; dest=1, tag=20)
    WaitIO.Wait(request)
else
    batch = WaitIO.recv(comm; source=0, tag=20)
    @assert batch isa TrainingBatch{Float64}
    @assert size(batch.coordinates) == (3, 100)
    @assert batch.metadata["step"] == 10
end

WaitIO.Finalize()
```

`isend` serializes during the call and retains the resulting bytes until completion.
Object `bcast` and `gather` are also available; nonblocking object receive is not.
Repeated sends to the same peer and tag are queued in call order. Array and object
tags can use the full native `unsigned long` range. Keep array and object streams
on different tags when they share a peer and communicator. `maxbytes` is an optional
application limit; the default is `typemax(Int)`, subject to available memory and
the native transport. Both Julia peers must use this package's `WJLOBJ02` object
protocol; it is incompatible with the earlier `WJLOBJ01` framing. Type definitions must agree,
including their defining modules and relevant dependencies. Use compatible Julia
versions and package environments on both sides.

Only exchange serialized objects with trusted Julia peers. Julia deserialization
does not validate malformed input, and the object-size limit is not a security
boundary. See the [Julia serialization documentation](https://docs.julialang.org/en/v1/stdlib/Serialization/).

This object protocol is for Julia peers. Use uppercase array operations with an
agreed data layout for C or Fortran interoperability.

## Collectives and lifecycle

Inside an initialized program, all members call collectives in the same order:

```julia
result = zeros(1)
WaitIO.Allreduce!([Float64(WaitIO.Comm_rank(comm))], result, WaitIO.SUM, comm)
```

Available operations include `Bcast!`, `Reduce!`, `Allreduce!`, `Gather!`,
`Allgather!`, `Scatter!`, `Gatherv!`, `Allgatherv!`, `Scatterv!`, `Scan!`,
`Exscan!`, and `Alltoall!`. `VBuffer` describes variable counts and displacements;
`UBuffer` describes fixed chunks. Counts and displacements are in elements, with
zero-based displacements. Data-moving collectives accept `isbits` elements. Types
without a native WaitIO datatype use `CHAR` with byte counts; they do not undergo
representation conversion. For a C or Fortran peer, agree on the same datatype,
count, root, operation, memory layout, and collective order.

Ordinary collectives call the corresponding installed WaitIO C function.
For example, `WaitIO.Allreduce!` with `Float64` buffers and `WaitIO.SUM` calls
`waitio_mpi_allreduce` with `WAITIO_MPI_DOUBLE` and `WAITIO_MPI_SUM`. The C peer
calls that same native collective. `WaitIO.Barrier` calls `waitio_mpi_barrier`;
it does not substitute an allreduce. Correctness also depends on the installed
library: a native barrier defect is not repaired by this wrapper.

Reductions require a native datatype and operation. `Int8` and `UInt8` use native
`WAITIO_MPI_CHAR`, whose signedness follows the C library build and may differ
between systems or from the Julia element type. WaitIO.jl does not silently widen
these values. For portable integer arithmetic, explicitly convert buffers on
both peers to an agreed supported type, such as an 8-byte `WAITIO_MPI_LONG`, and
check its size. A native datatype-size mismatch is reported before communication.
`ValueLoc{Float64,Int32}` reductions require native `DOUBLE_INT`, `MAXLOC`/`MINLOC`,
and a matching layout; other pair layouts are available through the extensions below.

Overlapping input/output buffers are supported by saving the input locally:

```julia
WaitIO.Allreduce!(values, WaitIO.SUM, comm)
WaitIO.Allreduce!(WaitIO.IN_PLACE, values, WaitIO.SUM, comm)
```

`IN_PLACE` is available for allreduce, scan/exscan, allgather/allgatherv,
all-to-all, and the root of reduce/gather/gatherv/scatter/scatterv. For
scatter/scatterv it replaces the receive argument; for the others it replaces
the send argument. Other ranks provide their usual buffers. Packing a view or
saving an overlapping input does not change the peer's communication protocol.

### Explicit Julia extensions

Use `WaitIO.Extensions` when all participants agree to its collective protocols:

```julia
# Every participant uses this extension, rather than a native C allreduce.
values = ComplexF64[1 + 2im]
WaitIO.Extensions.Allreduce!(values, WaitIO.SUM, comm)
best = [WaitIO.ValueLoc(score, Int32(WaitIO.Comm_rank(comm)))]
WaitIO.Extensions.Allreduce!(best, WaitIO.MAXLOC, comm)
```

These methods support additional numeric types, complex `SUM`, location pairs,
and associative Julia operations through `Op(f)`. They use byte messages and
Julia reductions where native types or operations are absent, and explicitly
widen small integers for their native reduction path. Results must fit the element
type; fixed-width integer addition wraps. These algorithms are not performance-tuned.
`Extensions.Barrier` uses an `Int32` sum-allreduce. `Extensions.Create_group` builds
a logical PB ordering over a canonical native group; use extension collectives
with that communicator. Neither extension is selected by an ordinary call or site alias.

An unmodified C/Fortran native collective cannot participate in these extension
protocols. Use ordinary array methods for such peers. Lowercase object methods
(`send`, `recv`, `bcast`, `gather`) likewise use Julia serialization and framing;
they are intended for Julia peers.

### Lifecycle and groups

`Init(mpi=:auto)` initializes MPI if necessary, and `Finalize()` finalizes MPI
only when WaitIO.jl started it. Use `Init(mpi=:external)` for an already initialized
MPI runtime. If MPI.jl is also loaded, both packages must use the same local MPI
shared library. Initialization requests `MPI_THREAD_SERIALIZED`. With SERIALIZED
or MULTIPLE support, multiple Julia threads may call the high-level API; WaitIO.jl
serializes native access and polls request completion without monopolizing its lock.
If MPI provides only FUNNELED, calls must stay on the initializing OS thread.
Other packages calling the same MPI must coordinate their access too. Order
collectives consistently across ranks and threads. Complete all requests and call
`Finalize()` on the initializing OS thread. There is no automatic communication
in finalizers and no support for reinitialization after shutdown.

`Create_group(gid; order=[...])` passes the PB ordering to native WaitIO without
remapping ranks. All processes use the same group ID, selection, and order,
create the group, then synchronize before using it. The native group handle and
Julia rank queries describe the same group. Native group-ordering defects must
be resolved in the installed library or explicitly avoided by the application.

Extension collective protocols use tags `0x574a4c00:0x574a4c17`; Julia objects use
additional framing as described above. Do not overlap application messages using
those reserved protocol tags with the corresponding operations on the same
communicator. Ordinary native collectives retain their library's own tag use.

## Tested environments and limitations

WaitIO.jl targets Miyabi-C/G and Wisteria Odyssey/Aquarius. C/C, Julia/Julia,
and mixed C/Julia communication have been checked using the socket transport,
CPU arrays, and one MPI rank per subsystem. API availability and datatype
behavior depend on the installed WaitIO build.

- The Miyabi development installation selected by `miyabi-dev-c` and
  `miyabi-dev-g` supports the tested Int64 Allreduce, MPI-style Int64 transfers,
  Gather, and Scatter. The older `miyabi-c` / `miyabi-g` module installation
  has a LONG datatype size mismatch and lacks some native functions.
- CHAR MAX reductions are unsupported in the tested Miyabi development and
  Wisteria builds. Do not use Int8/UInt8 MAX reductions with these installations.
- Uppercase `WAITIO_MPI_Allgatherv` is absent in both tested builds. Query
  `capabilities()` for the actual symbols; 80 wrappers do not imply 80 available
  or verified native functions.
- GPU buffers, RDMA, multi-rank PBs, Fortran peers, and performance are outside
  this native interoperability verification.

Application job templates are available for [Miyabi](test/native/miyabi/README.md)
and [Wisteria](test/native/wisteria/README.md). The independent
[C/Julia reference programs](test/native/reference/README.md) can be run against
the installation available to you.

## Low-level API and tests

`WaitIO.API` exposes the native C entry points declared in [the bindings](src/api.jl).
Each function resolves its exact native symbol, including `layered`, `Nnary`,
and uppercase/lowercase variants. Missing symbols are reported; no alternative
algorithm is substituted. `capabilities()` reports the actual available symbols.
Callers manage raw pointers, buffer lifetimes, and error handling. The 80 wrapper
names do not imply that every installation exports all 80 functions.

Older `miyabi_compat` and `native_fixes` settings are accepted for config migration
but ignored with a warning. Native functions are never replaced by these settings.
High-level `Wait`/`Waitall` poll individual managed requests to retain buffer
ownership and allow Julia tasks to progress; they do not expose native status
arrays. Use `API.waitio_mpi_waitall` with a contiguous native request array when
its exact status-array behavior is needed.

From a checkout, run the local tests with:

```sh
julia --project=. -e 'using Pkg; Pkg.test()'
```

The local suite checks API wrappers, configuration, request ownership, and
Julia-object transfer using test fixtures. It runs without a WaitIO installation;
communication with site libraries is tested separately on the target systems.

CI runs the package suite on Julia 1.10, 1.11, and 1.12. Separate jobs check
distinct C function dispatch and the reference runner/comparator. The dispatch
job compiles a small diagnostic library; it does not need MPI or a WaitIO
installation. See [contributing and validation](CONTRIBUTING.md) to run these
checks locally.

The [C/Julia comparison suite](test/native/reference/README.md) runs the installed
WaitIO library from an independent C program and compares its output with
WaitIO.jl for the same inputs, including C↔Julia in both rank placements.
It also checks mathematical expectations, so
matching incorrect results do not pass. This suite covers selected operations
and boundary cases; it does not certify equivalence for all 80 API names.

## Learn more about WaitIO

Start with the [2024 WaitIO/MP hands-on tutorial](https://www.cc.u-tokyo.ac.jp/events/lectures/236/)
for programming and job setup, or the
[2023 English ASE talk](https://www.cc.u-tokyo.ac.jp/en/events/ase/45/Sumimoto.pdf)
for the architecture. The [2026 Miyabi workshop](https://www.cc.u-tokyo.ac.jp/events/lectures/277/)
provides WaitIO slides and recording links in a QC–HPC coupling context.

The [annotated reading list](docs/WAITIO_RESOURCES.md) covers these tutorials,
additional talks, and research papers. These are resources for the underlying
h3-Open-SYS/WaitIO project, developed by Shinji Sumimoto and collaborators;
WaitIO.jl's Julia API and optional extension protocols are documented in this repository.

## References

The introductory claims above refer to these upstream papers. Cite the relevant
WaitIO work when using its communication methods; these papers do not describe
WaitIO.jl or establish its performance.

1. Shinji Sumimoto et al. **A System-Wide Communication to Couple Multiple MPI
   Programs for Heterogeneous Computing.** PDCAT 2022, LNCS 13798, pp. 314–327,
   published 2023. [DOI: 10.1007/978-3-031-29927-8_25](https://doi.org/10.1007/978-3-031-29927-8_25).
   Introduces the WaitIO-Socket architecture and heterogeneous MPI application coupling.
2. Shinji Sumimoto et al. **WaitIO-Hybrid: Communication for Coupling MPI Programs
   Among Heterogeneous Systems.** PDCAT 2024, LNCS 15502, pp. 140–153,
   published 2025. [DOI: 10.1007/978-981-96-4207-6_13](https://doi.org/10.1007/978-981-96-4207-6_13).
   Describes socket and shared-file communication and coupled applications.
3. Shinji Sumimoto et al. **Accelerating Heterogeneous Coupling Computing with
   WaitIO Using RDMA.** HPC Asia 2025 Workshops, pp. 1–10, 2025.
   [DOI: 10.1145/3703001.3724382](https://doi.org/10.1145/3703001.3724382).
   Describes WaitIO-Verbs and WaitIO-Tofu; RDMA performance is separate from the
   socket-based Julia tests in this repository.

## License and upstream software

WaitIO.jl is distributed under the [MIT License](LICENSE).
Copyright (c) 2026 Yuki Nagai.

External WaitIO and MPI installations have separate terms; see
[third-party notices](THIRD_PARTY_NOTICE.md).

The site-provided WaitIO and MPI libraries are separate software; obtain them
under their own terms. This repository does not distribute those shared libraries.
