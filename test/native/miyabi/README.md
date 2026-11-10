# Miyabi: Julia on G and C

These templates launch Julia on both Miyabi systems from a shared project and
source tree, with separate configuration files and writable depots. They are
broad regression diagnostics, including Julia-specific object transfers.
For independent C/C and mixed C/Julia comparisons, use the
[reference suite](../reference/README.md). Check the selected installation's
capabilities before choosing tests; these broad diagnostics may exercise
operations unavailable in that installation.

The templates select the development installation under `/work/share/waitio-rt/opt/waitio`,
with NVIDIA 24.9/HPC-X 24.9 on G and Intel 2023.2.0/MPI 2021.10.0 on C.
For introductory programs, use the [examples guide](../../../examples/README.md).

1. Create a fresh shared run directory. Copy this package into `source/` there,
   excluding `.git`, `unused`, and site-local `LocalPreferences.toml`.
   Instantiate `source/` with Julia 1.12.6 before submitting jobs. Retain the
   generated `Manifest.toml` in that directory. Prepare `depot-shared/` with the
   Preferences.jl source matching that manifest (for example, instantiate with
   `JULIA_DEPOT_PATH="$PWD/depot-shared:"` and automatic precompilation disabled).
   Ensure both compute systems can read it; all writes go to `depot-g/` or
   `depot-c/`. No package installation or manifest changes occur in the jobs.
2. Copy `job-g.pbs`, `job-c.pbs`, `run-peer.sh`, `configure.jl`, and `highlevel.jl`
   from this directory into the run directory.
3. Replace `CHANGE_ME_PROJECT` and `CHANGE_ME_PAIR` in both PBS templates. Use the
   same pair name for the two jobs. Set `WAITIO_JULIA_C_BIN` in `job-c.pbs`
   to a Julia 1.12.6 x86_64 installation. G uses the Julia 1.12.6 module; both
   participants must use matching Julia versions for serialized objects.
4. Submit `job-g.pbs` first from the shared run directory. Once `ready-g` appears,
   submit `job-c.pbs` promptly. Both scripts can be submitted from the G login node;
   their `debug-g` and `debug-c` queues select the compute systems. Keep the job
   name and project identical for the pair. G waits up to 600 seconds for C's
   configuration; its total job limit remains 15 minutes.
5. Inspect `exit-g.txt`, `exit-c.txt`, `highlevel-*.log`, `objects-*.log`,
   and `collectives-*.log`. Both exit files must contain `0`; all three phases must pass.

`configure.jl` checks core symbols and records availability of all declared API
names. Missing symbols are not counted as successful communication. The
high-level phase records skips for selected absent functions; other unsupported
operations may fail. Inspect skips as well as failures and exit codes. The jobs then test numeric communication
and serialized objects between Julia processes. An additional phase checks five
numeric types, reduction operations, sparse displacements, large all-to-all
messages, and raw request-array guards. The job scripts set `CC`, `CXX`, and
`MPICC` to nonexistent compiler paths. Both use `source/Project.toml`; writable
depots and configuration files are separate. Setup uses `use_system_library`
with the `miyabi-dev-g` / `miyabi-dev-c` aliases and separate output files. A fresh process then checks that the
correct file is selected and the other CPU's configuration is rejected before
library loading. Project/manifest checksums must remain unchanged.

Each participant atomically publishes `ready-$role` after configuration has
finished. `wait-peer.sh` waits for the peer's readiness and capability file, and
reports an early peer exit or timeout. The C hostname is exchanged through the
shared directory, so the test does not depend on the WaitIO hostname service.
Always use a fresh directory; readiness files from an older run must not be reused.

The templates use short debug jobs. Coupler jobs can start at different times;
submitting a pair does not remove the need for this readiness check. If the C
queue cannot start within the available wait, stop the test and try again when
both systems have capacity. Adjust the recorded module versions to your site.
Keep generated logs and reports in your private run directory.
