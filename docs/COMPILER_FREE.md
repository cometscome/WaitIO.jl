# Library compatibility and configuration

WaitIO.jl calls the WaitIO and MPI shared libraries installed on the target system.
Setup checks their CPU architecture and application binary interface (ABI) before
communication. The site aliases in the [README](../README.md#choose-a-site-alias)
provide settings for Miyabi and Wisteria. Use explicit paths for other installations.

```julia
using WaitIO
WaitIO.configure!(
    libwaitio="/site/waitio/lib/libwaitio_intel.so",
    libwaitio_mpi="/site/waitio/lib/libwaitio_mpi_intel.so",
    include_dir="/site/waitio/include",
)
info = WaitIO.check_library()
println(info.abi["recognized_profile"], ": ", info.abi["request_bytes"], " bytes")
```

## ABI selection

A release name or module version does not by itself identify a C request layout.
The built-in profiles match all three WaitIO header hashes and check the core and
collective library hashes for known mismatches. A rebuilt library is accepted
when its matching headers identify a reviewed layout. The recorded installations are:

| Profile | Request size / alignment | Known library pairs |
| --- | --- | --- |
| `wisteria-352` | 352 / 8 bytes | Wisteria Intel / A64FX |
| `miyabi-88` | 88 / 8 bytes | Miyabi Intel and NVIDIA |
| `miyabi-dev-360` | 360 / 8 bytes | Miyabi development Intel and NVIDIA, November 10, 2026 |

Each profile describes a distinct request layout. Profile names are local
identifiers, independent of upstream version numbers.
Profiles currently cover little-endian LP64 Linux on x86_64 and aarch64.

Setting `abi_profile` to one of these identifiers optionally pins a layout;
matching headers are still required. Leaving it empty selects a known layout
automatically. An unknown layout is rejected before loading or calling the library,
even with `allow_unverified_abi=true`. The option remains readable in older config
files but no longer controls acceptance of new binary hashes. A known pair
for a different layout is always rejected. There is no implicit compiler fallback.

Constants and PB/group limits are read from the identified headers using a restricted
integer-expression reader. Header text is never executed or passed to a compiler.
The reader accepts integer literals, named macros, parentheses, and bitwise OR;
unsupported expressions stop configuration rather than producing guessed values.

For a new installation, an independently reviewed custom profile can be selected
with `abi_profile="/absolute/path/profile.toml"`. It must record `machine`
(`Sys.MACHINE`), `request_bytes`, `request_alignment`, `group_limit`, `pb_limit`,
`libwaitio_sha256`, `libwaitio_mpi_sha256`, and a `[headers]` table with hashes for
`waitio.h`, `waitio_mpi.h`, and `waitio-lib.h`. Library and header hashes must match
exactly, even in diagnostic mode. Establish the layout from the actual ABI before
creating this file; adding bytes without knowing the correct array stride is unsafe.
The profile author must independently verify the layout; matching hashes alone
cannot establish that the recorded sizes and alignment are correct.

## Runtime behavior

- Request storage is zeroed native allocation with the profile's size. Raw request
  arrays use that exact stride; requests remain at stable addresses until completion.
- MPI initialization, ownership, finalization, and thread checks call the same site's
  MPI through its existing library dependency chain. No MPI binary package is loaded.
- Group callbacks are retained until native finalization.
- Ordinary WaitIO functions resolve directly to the installed native symbols.
  No algorithm, registration call, or completion status is replaced.
- C-callable Julia helpers manage allocation, MPI ownership, and filter callbacks.
  They are internal helpers, not replacements for the 80 external C functions.
- `WaitIO.Extensions` contains opt-in Julia collective protocols. Participants
  must explicitly agree to those protocols; site aliases do not enable them.

The legacy `native_fixes` and `miyabi_compat` configuration fields are accepted but
ignored with a warning. The helper `API.waitio_mpi_dtypesize` is a Julia
size table, not an external native function or a probe of a header's inline code.
Use native `API.waitio_mpi_type_size` when comparing the installed library's answer.

## Migrating saved configuration

Remove obsolete `backend`, `adapter`, `mpicc`, `cflags`, and `auto_build`
keys from saved configuration files. The package loads its Julia bindings directly.

## Validation

The active local suite uses Julia callbacks to check all 80 API wrappers against
an independently recorded header contract. It also checks configuration, ABI
hashes, MPI ownership, OS-thread restrictions, error paths, request lifetime under
GC, and serialized objects. Request storage and contiguous request arrays are
exercised at 88, 352, and 648 bytes, with guard bytes checking stride and bounds.
These fixtures test Julia allocation and calling code, not the layout of a newly
installed native library.

Four independent Julia processes run the collective algorithms over a test
transport that exchanges files in a temporary directory. Coverage includes numeric types, SUM/MIN/MAX, every root, scan/exscan, sparse displacements,
64-bit values, zero-length broadcast, large all-to-all messages, and custom
objects sent between processes. This is a regression test, not a network or
native WaitIO test. It runs as part of `Pkg.test()` and needs no MPI launcher.
