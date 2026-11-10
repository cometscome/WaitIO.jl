# Compare installed WaitIO with WaitIO.jl

This diagnostic runs **C↔C**, **Julia↔Julia**, **C↔Julia**, and **Julia↔C** with
identical inputs and rank placement. In the mixed modes, the first language is
PB0 and the second is PB1. The C program uses the installed headers and libraries
without an adapter or replacement from this repository. Ordinary Julia calls
also resolve to the installed native functions.

Each case produces three separate checks:

1. Do the C and Julia return codes, output values, and status entries agree?
2. Does C produce the independently calculated numerical answer?
3. Does Julia produce that numerical answer?

Identical wrong answers fail. A native `not defined datatype` or operation
diagnostic also fails, even if the returned values happen to match. A missing function, missing output, duplicate
record, nonzero process exit (including finalization failure), or timeout also
fails. `comparison.json` retains each observation and its expected values.
There is no expected-failure whitelist.

## Coverage and limits

`long-probe.c` is a separate C-only reproducer for `WAITIO_MPI_LONG`.
It compares `long` and `long long` storage at counts 1 and 3 using integer inputs
above 2^40 and `WAITIO_MPI_SUM`. Both PBs must run the same executable, compiled
for their architecture against the same WaitIO installation used at runtime:

```sh
mpicc -std=gnu99 -O0 -Wall -Wextra -I"$WAITIO_INC" long-probe.c \
  "$REFERENCE_LIBWAITIO_MPI" "$REFERENCE_LIBWAITIO" \
  -Wl,-rpath,"$(dirname "$REFERENCE_LIBWAITIO")" -o long-probe
```

Launch one MPI process in each of two PBs with the site's WaitIO connection
settings. The program checks both ranks' answers and returns nonzero on a
mismatch. `./long-probe --layout` prints the C request size, alignment, and
group/PB limits without initializing communication. It is a diagnostic tool,
not a package setup requirement.

`cases.tsv` defines 57 cases for exactly two WaitIO ranks (one MPI process in
each PB). Run each suite on **Miyabi-C + Miyabi-G** or **Wisteria Odyssey + Aquarius**.
Repeat with reversed PB placement to expose architecture-dependent root behavior.
Do not compare outputs from different placements, library installations, or inputs.

The cases cover Bcast, Gather, Allgather, Scatter, Reduce and Allreduce, their
available `Nnary` and `layered` names, Waitall with MPI-style Isend/Irecv, and
byte-count point-to-point requests (`p2p`) with the managed Julia request API. They include:

- Both root positions, one/three/zero elements, SUM/MIN/MAX.
- Int32, Int64 values above 2^40, Float32/Float64, Int8 and UInt8 boundary values.
- The untouched `Waitall` status sentinel `-777`, recorded without interpreting
  it as a documented status contract.

Standard operations use Julia's public high-level API. Named algorithm variants
and Waitall status arrays use `WaitIO.API` directly. C selects the exact native
symbol using `dlsym`; it never falls back to another algorithm. A missing native
symbol exits with code 77 and does not count as a pass.

**This is not an 80-function conformance certificate.** It does not yet cover
Scan/Exscan, variable-count collectives, Alltoall, group creation, memory
registration, all uppercase aliases, or socket internals. Barrier arrival timing,
performance/scaling, and Fortran peers require separate tests. Mixed C/Julia
communication is exercised only for the listed cases, not every function. Matching a native defect is not correctness; differences in undocumented
outputs require clarification from the WaitIO developer.

`WAITIO_MPI_CHAR` is C `char`, not a portable signed or unsigned 8-bit reduction
type. The C program prints `CHAR_MIN`, request size, long size, header datatype size,
and the installed `waitio_mpi_type_size` result. This separates a native datatype
size defect from the Julia wrapper's size validation.
The original `u8` and `i8` cases retain a native CHAR baseline and compare it
with the high-level Julia operation. Their mathematical checks use the declared
Julia type; native CHAR behavior can therefore disagree with that numerical
expectation, even if C and Julia agree. This still reports a failure.

Ten additional `u8-wide` / `i8-wide` cases make the C program explicitly convert
the same inputs to signed 64-bit values, call the native LONG reduction, and
narrow the result modulo 256. The Julia test explicitly makes the same conversion
before calling the normal high-level API; the package does not widen implicitly.
These cases have `widened_bytes=1` in the C metadata. Neither peer substitutes
a reduction algorithm. No original CHAR case has been removed or exempted.
Integer comparisons are exact; floats use relative and absolute tolerances of
1e-6 (Float32) and 1e-12 (Float64). Inputs avoid integer overflow and use exactly
representable floating-point fractions. Non-root reduction/gather workspaces
are not compared because their contents are not result values.

## Prepare each architecture

Use a shared copy of the package, with dependencies already instantiated and
separate writable Julia depots for the two architectures. Load the site's MPI
and WaitIO modules. Run communication tests on allocated compute nodes.
The existing [Miyabi](../miyabi/README.md) and
[Wisteria](../wisteria/README.md) templates describe the scheduler allocation,
module setup, hostname exchange, and (for Wisteria) WaitIO hostname service.
Replace their test invocation with this runner; do not run this whole suite
under their existing short walltime without selecting a small case subset.

Configure Julia using the site's alias, for example on Miyabi-C:

```julia
using WaitIO
WaitIO.use_system_library("miyabi-c"; config_file="config-c.toml")
```

Use `miyabi-g`, `wisteria-odyssey`, or `wisteria-aquarius` on the other systems.
Export the absolute `WAITIO_JL_CONFIG` path for each participant. Export the
**same installed library paths** for the C build and run:

```bash
export WAITIO_INC="$WAITIO_DIR/include"
# Suffix: intel (Miyabi-C/Aquarius), nvidia (Miyabi-G), a64fx (Odyssey).
export REFERENCE_LIBWAITIO="$WAITIO_LIB/libwaitio_intel.so"
export REFERENCE_LIBWAITIO_MPI="$WAITIO_LIB/libwaitio_mpi_intel.so"
export LD_LIBRARY_PATH="$WAITIO_LIB:${LD_LIBRARY_PATH:-}"
export MPICC=mpicc   # Use the MPI C compiler provided by the loaded site modules.
bash source/test/native/reference/build.sh "$PWD/reference-c"
```

Build a separate executable on each architecture (`reference-c`, `reference-g`,
`reference-o`, `reference-a`, for example). Only this diagnostic needs a C
compiler. Julia checks that its effective library paths match the C paths before
initializing WaitIO. No compatibility replacement is active in either language.
Do not copy native headers or binaries into the public repository.

## Run a small comparison first

Set `WAITIO_NPB=2`, `WAITIO_COMM_TYPE=socket`, `WAITIO_MASTER_HOST` and the site's
`WAITIO_HOST_POSTFIX` as in the existing native templates. Use PB0 on Miyabi-C
or Odyssey and PB1 on Miyabi-G or Aquarius. On Wisteria, perform the normal
`waitio-serv-*` hostname-service setup first, with the same `COUPLER_JOB_ID` on
both sides. The runner preserves that ID and uses a different master port for
each case and language.

Start both commands inside their respective scheduler allocations, sharing one
**fresh** output directory. These examples use two quick cases; specify the same
case IDs on both sides. Replace the paths and launcher for each system.

PB0 (Miyabi-C example):

```bash
export WAITIO_PBID=0
python3 source/test/native/reference/run-peer.py 0 "$PWD/reference-results" \
  --c-executable "$PWD/reference-c" --project "$PWD/source" \
  --julia /path/to/julia --launcher 'mpiexec.hydra -np 1' \
  --case allreduce-i32-sum-r0-n3 --case allreduce-u8-wide-max-r0-n3
```

PB1 (Miyabi-G example):

```bash
export WAITIO_PBID=1
python3 source/test/native/reference/run-peer.py 1 "$PWD/reference-results" \
  --c-executable "$PWD/reference-g" --project "$PWD/source" \
  --julia /path/to/julia --launcher 'mpirun -np 1' \
  --case allreduce-i32-sum-r0-n3 --case allreduce-u8-wide-max-r0-n3
```

For Odyssey use `--launcher 'mpiexec -n 1'`; Aquarius uses
`--launcher 'mpiexec.hydra -np 1'`. The runner waits for PB0's actual listening
socket before launching PB1. Both participants verify identical case lists and
test sources. Library, executable and configuration hashes are saved per role.

After **both runners finish**, compare the same selected cases:

```bash
python3 source/test/native/reference/compare.py reference-results \
  --case allreduce-i32-sum-r0-n3 --case allreduce-u8-wide-max-r0-n3
```

The comparison exits nonzero on any mismatch or incomplete case. A native
`Waitall` leaving `-777` untouched while Julia writes `0` is reported as a
status mismatch; the test does not assume which behavior is correct.

Remove the `--case` options from both runners and the comparator to run all
54 cases. The default limit is 60 seconds per language per case, plus peer
coordination; split the suite across fresh directories to fit the scheduler's
walltime. `--base-port` must match on both sides and must not overlap another
run. Keep result directories outside the checkout. Raw native logs may contain
site account or host information; inspect them before publishing.

## Check the harness locally

```bash
python3 -m unittest discover -s test/native/reference -p 'test_*.py' -v
```

These tests validate the comparator, including matching wrong results, missing
records, status differences and timeouts. Two orchestration tests use a small
loopback socket stub and require local socket access. They are not native WaitIO
results.

## Runner details

Python 3.6 or newer is sufficient on the compute nodes. `capture-peer.sh` redirects
output inside each MPI process; this also captures Fujitsu MPI output that would
otherwise go only to the scheduler file. Each case retains both `.peer.log` and
merged `.log` files. The comparator still requires a successful process exit,
not just a `RESULT` line.

`--timeout` applies separately to master startup and to communication/finalization.
For slow Julia startup, for example on A64FX, use `--timeout 90` and optionally
`--julia-arg=-O0`. Reserve enough scheduler time for the selected cases. A timeout
stops the remaining launches on both peers because an MPI launcher can retain
processes after termination; retry the remaining cases in a fresh allocation.
Both languages check missing primary symbols before WaitIO initialization.

The mode plan alone is not proof of mixed communication: `mixed_language_tested`
is true only when both mixed modes have complete observations for every selected
case. It does not imply numerical correctness; inspect `pass_all` and each record.
