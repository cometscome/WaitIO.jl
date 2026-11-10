# Running the examples

These programs use the installed WaitIO library. Run one process in each of two
independent MPI jobs, connected as two parallel blocks (PBs). They are intended
for Miyabi-C/G or Wisteria Odyssey/Aquarius, not a standalone laptop invocation.
Each program initializes communication, checks its results, and finalizes it.

| Program | Run on PB 0 | Run on PB 1 | Expected result |
| --- | --- | --- | --- |
| Arrays | `exchange.jl` | `exchange.jl` | Both print `exchange PASS`, count 1024 |
| Collectives | `collectives.jl` | `collectives.jl` | Both print `collectives PASS`, sum 3.0, variable [10.0, 20.0, 30.0] |
| Julia objects | `objects.jl` | `objects.jl` | Both print `objects PASS`; rank 1 checks the struct and its contents |
| Mixed languages | compiled `exchange.c` | `exchange.jl` | Both print `exchange PASS`, count 1024 |

The C and Julia placements can be reversed. Use matching Julia versions, package
environments, and type definitions for the object example. The collective example
requires the lowercase native gather/scatter/allgatherv functions; use the
`miyabi-dev-*` aliases on Miyabi. Missing uppercase `WAITIO_MPI_Allgatherv` does
not prevent the high-level `Allgatherv!` from calling lowercase `waitio_mpi_allgatherv`.

## Prepare the project

Copy the chosen example files into an application directory shared by the two
systems (or copy the same files to each system). In that directory, install WaitIO:

```sh
julia --project=. -e 'using Pkg; Pkg.add(url="https://github.com/cometscome/WaitIO.jl.git")'
```

For a local package checkout, use `Pkg.develop(path="/path/to/WaitIO.jl")` instead.
[Configure each target](../README.md#configure-each-system) with its MPI modules
and library search paths, saving separate files for the two systems. Start a
fresh Julia process after setup. Prepare each architecture's writable depot and
its dependencies before submitting jobs; do not install packages in paired jobs.

For example, create `config/miyabi-c.toml` on C and `config/miyabi-g.toml` on G
using `miyabi-dev-c` / `miyabi-dev-g`. For Wisteria, create `config/odyssey.toml`
and `config/aquarius.toml` using the corresponding aliases. These settings select
libraries; the job environment below selects the communication partners.

## Launch on the two systems

Obtain paired allocations using your site's scheduler. Load the modules and
library search paths described in the [setup instructions](../README.md#choose-a-site-alias)
in **each allocation**. Start in the application directory. The following commands
are the communication portion of a job, not complete PBS/PJM submission scripts.

Choose one example and agree on a reachable PB 0 hostname and an available port.
Use the same values on both sides, with distinct PB IDs:

```sh
# Both jobs: replace this value with the actual PB 0 compute hostname.
export WAITIO_MASTER_HOST=CHANGE_ME_PB0_HOST
export WAITIO_MASTER_PORT=20770
export WAITIO_COMM_TYPE=socket
export WAITIO_NPB=2
# If the site's coupled-job procedure sets COUPLER_JOB_ID, keep the same value
# on both sides; the native library adds it to the base master port.
```

Select the remaining settings for each job:

| System | PB ID | WAITIO_JL_CONFIG | Writable depot | WAITIO_HOST_POSTFIX | Launcher |
| --- | --- | --- | --- | --- | --- |
| Miyabi-C | 0 | `$PWD/config/miyabi-c.toml` | `$PWD/depot-c:` | `-ib` | `mpiexec.hydra -n 1` |
| Miyabi-G | 1 | `$PWD/config/miyabi-g.toml` | `$PWD/depot-g:` | `-ib` | `mpirun -np 1` |
| Odyssey | 0 | `$PWD/config/odyssey.toml` | `$PWD/depot-o:` | `-tofu1` | `mpiexec -n 1` |
| Aquarius | 1 | `$PWD/config/aquarius.toml` | `$PWD/depot-a:` | `-tofu1` | `mpiexec.hydra -n 1` |

Use the compute node's base hostname with the suffix convention required by the
site installation; do not append the suffix twice. The Wisteria paired diagnostic
[launch procedure](../test/native/wisteria/README.md) also shows site service
registration and readiness checks. Follow the site's current coupling procedure.

For example, the Miyabi-C job runs:

```sh
export WAITIO_PBID=0 WAITIO_HOST_POSTFIX=-ib
export WAITIO_JL_CONFIG="$PWD/config/miyabi-c.toml"
export JULIA_DEPOT_PATH="$PWD/depot-c:"
timeout --kill-after=10s 300s mpiexec.hydra -n 1 \
  julia --startup-file=no --project=. exchange.jl
```

The Miyabi-G job runs:

```sh
export WAITIO_PBID=1 WAITIO_HOST_POSTFIX=-ib
export WAITIO_JL_CONFIG="$PWD/config/miyabi-g.toml"
export JULIA_DEPOT_PATH="$PWD/depot-g:"
timeout --kill-after=10s 300s mpirun -np 1 \
  julia --startup-file=no --project=. exchange.jl
```

Start PB 0 first. Confirm that its master socket is listening on the effective
port before launching PB 1; process startup alone does not establish readiness.
For example, run `ss -lnt` on the PB 0 node and check the selected port. Launch
PB 1 promptly within the time limit. If one participant fails, stop the other
job; MPI abort only terminates the failing participant's local MPI job. Start
both again for another example, with fresh rendezvous state and no port conflict.

For `collectives.jl` or `objects.jl`, replace the filename on **both** sides.
Do not run different examples as a pair. Each participant must finish successfully;
a timeout, assertion failure, or a missing peer result is not a pass.

## Build and launch the C peer

Build on the system that will run C, with its MPI compiler, installed WaitIO
headers, and matching libraries. For Miyabi-C's development installation:

```sh
module load intel/2023.2.0 impi/2021.10.0
export WAITIO_DIR=/work/share/waitio-rt/opt/waitio
export LD_LIBRARY_PATH="$WAITIO_DIR/lib:/usr/ofed/lib:${LD_LIBRARY_PATH:-}"
mpiicc -std=c99 -O2 -Wall -Wextra -I"$WAITIO_DIR/include" exchange.c \
  -Wl,--no-as-needed "$WAITIO_DIR/lib/libwaitio_mpi_intel.so" \
  "$WAITIO_DIR/lib/libwaitio_intel.so" -o exchange-c
```

On another system, use that system's MPI C compiler and WaitIO library variant
(`nvidia`, `a64fx`, or `intel`). Compile separately for each CPU architecture.
The compiler is needed for this C application.

Keep the same PB/network settings, but replace the C-side Julia launcher with:

```sh
timeout --kill-after=10s 300s mpiexec.hydra -n 1 ./exchange-c
```

The other side still runs `exchange.jl`. The C process does not read
`WAITIO_JL_CONFIG`; its libraries are selected during linking and through the
library search path. Both implementations transfer 1024 eight-byte values with
tag 10 through `waitio_isend` / `waitio_irecv`, followed by completion. On the
supported systems, Julia `Float64` and C `double` use the same little-endian
IEEE 754 representation. No Julia serialization or native LONG datatype is used.

## Scope of these examples

The Julia example programs are exercised in the local test suite using two
processes and a file-based test transport. That verifies their API usage and
expected values, not native networking. Run the examples on the target pair to
check the installed libraries and job setup. The standalone C example must also
be built and run with the target installation. Broader independent C/Julia
comparisons are available in the [reference suite](../test/native/reference/README.md).
