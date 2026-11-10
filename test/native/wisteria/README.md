# Wisteria: Julia peers on Odyssey and Aquarius

These are broad Julia-to-Julia diagnostics, including serialized objects.
Use the [reference suite](../reference/README.md) for independent C peers.
Check the installed library's capabilities before selecting tests.

## Odyssey–Aquarius communication

Use `job-o.pjm` and `job-a.pjm` to launch one Julia process on each system.
Both jobs read the same `source/Project.toml` and source tree, but use separate
`config-0.toml` / `config-1.toml` files and `depot-o/` / `depot-a/` writable depots.
`run-oa.sh` selects `a64fx` with Fujitsu MPI on Odyssey and `intel` with Intel MPI
on Aquarius. It waits for both configurations and exchanges the Odyssey master
hostname through the shared directory and checks it against the site
`waitio-serv` service. The templates use base port 7480 plus coupling ID 71
(effective master port 7551). Aquarius starts communication only after
Odyssey publishes that its master socket is listening (`ss -lnt`).

Prepare a fresh shared run directory with `source/`, its resolved `Manifest.toml`,
and `depot-shared/` as described below. Extract Julia 1.12.6 for aarch64 into
`julia-1.12.6/`. Set `WAITIO_JULIA_A_BIN` in the Aquarius job to the absolute bin
directory of an x86_64 Julia 1.12.6 installation. Replace `CHANGE_ME_PROJECT` in
both job templates with an allocation authorized for `coupler-o` and `coupler-a`;
keep both job names identical. Submit both scripts from the shared run directory:

```sh
pjsub job-o.pjm
pjsub job-a.pjm
```

The pair requests one node per system and ten minutes per job. Both use the
socket transport and call the installed native functions. Inspect `launcher-o.log`, `launcher-a.log`,
`peer-1.log`, the Odyssey PJM `.out` file, and both `exit-*.txt`.
Fujitsu MPI writes process output to the PJM file even when the launcher
redirects its own stdout; `peer-0.log` can therefore be empty. Each launcher must report successful
setup, nine configuration checks, unchanged project/config checksums, and completion.
Each communication process must complete its assertions and report `normal_exit=yes`.
Record the actual pass/fail/skip counts; do not reuse historical counts as evidence.
The configuration checks also reject the other CPU architecture before library
loading. These tests do not cover RDMA, direct GPU buffers, or cross-center use.

The launch sequence follows the site's
[WaitIO tutorial](https://www.cc.u-tokyo.ac.jp/events/lectures/236/20241030-2.pdf).

## Aquarius-only diagnostic test

This test uses the installed Intel WaitIO libraries with the reviewed 352-byte
request layout. It runs two independent one-process MPI
jobs inside one Aquarius allocation, with different PB IDs and configuration
files, reading the same Julia project. It does not test Odyssey/Aquarius coupling,
RDMA, or GPU buffers.

Prepare a fresh run directory containing:

- `source/`: this package, without `.git`, `unused`, or site-local preferences;
  instantiate it with Julia 1.12.6 before submission and retain `Manifest.toml`.
- `depot-shared/`: package sources matching the manifest, including Preferences.jl.
- `julia-1.12.6/`: the x86_64 Julia distribution, with `bin/julia` executable.
- `job.pjm`: copied from this directory, with `CHANGE_ME_PROJECT` replaced by an
  allocation allowed to use the requested Aquarius queue.

Submit with `pjsub job.pjm` from the run directory. The template uses `debug-a`,
one node, and at most ten minutes. Adjust module versions for the installation.
Only the private `depot/` receives Julia cache writes. No package installation,
C compilation, or MPI/WaitIO build occurs in the job.

The setup process calls `use_system_library()` with default persistence, checks
core symbols, reports missing declared names, and writes `config-0.toml` and `config-1.toml`. A fresh process
then verifies that Preferences.jl retrieves the saved configuration with native
functions selected. The two MPI
processes select their explicit files and test numeric arrays, asynchronous
requests, collective operations with both roots, custom serialized objects, and
cyclic references. Symbol availability is not full behavioral coverage of all
80 native functions.

Inspect the scheduler output, `peer-0.log`, `peer-1.log`, and `exit.txt`. Both peers
must report `normal_exit=yes` and the job must finish with `exit.txt` containing
`0`. Project, manifest, preferences, and both config checksums must be unchanged
during communication. A timeout or missing output is a failed/incomplete run.

Keep generated logs and reports in your private run directory.
