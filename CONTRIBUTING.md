# Contributing to WaitIO.jl

Report a reproducible problem or propose a change through this repository's
issues and pull requests. Include the Julia version, operating system, CPU
architecture, WaitIO library/header version, MPI implementation, and the smallest
program that shows the behavior. Remove account IDs, project/allocation codes,
credentials, and private paths from shared logs.

## Local checks

Run from the package root on Linux with Julia 1.10 or later:

```sh
julia --startup-file=no --project=. -e 'using Pkg; Pkg.test()'
python3 -m unittest discover -s test/native/reference -p 'test_*.py' -v
```

The package tests use local fixtures and require neither site WaitIO/MPI
libraries nor a C compiler. The Python tests exercise result comparison,
mixed-language launch selection, and timeout handling. Neither suite establishes
interoperability with an installed WaitIO library.

To check that different C function names remain distinct, run the separate
dispatch diagnostic with a C compiler:

```sh
cc -shared -fPIC -o /tmp/waitio-dispatch.so test/native/dispatch/symbols.c
julia --startup-file=no --project=. test/native/dispatch/check.jl /tmp/waitio-dispatch.so
```

CI runs these checks, with the Julia checks on 1.10, 1.11, and 1.12. Changes to
communication behavior also need the relevant [native C/Julia comparisons](test/native/reference/README.md)
on the target systems. Keep full results, including failures and incomplete runs, in private storage
outside this repository. Compare against independent expected values as well as C
output. Publish test programs and user-facing limitations, not internal reports,
scheduler output, raw logs, or development review records.

## Native APIs and Julia extensions

`WaitIO.API` resolves the exact declared native symbol. Keep algorithm variants,
case-sensitive names, native return codes, and status arrays distinct. A missing
symbol must not silently select a different function. Availability depends on
the installed library; 80 declared wrappers do not mean 80 tested functions.

High-level array operations manage Julia buffers and requests while using the
native communication calls. Test relevant changes with a C peer, because the
other application need not use Julia. New wire formats or collective algorithms
belong in explicit, documented extensions agreed by every participant; do not
enable them through a site alias. Serialized-object operations require trusted
Julia peers with matching type definitions and compatible Julia versions.

## Documentation and distribution

Keep the main README and contribution instructions in English. Put Japanese
documentation under `inJapanese/` and check Japanese edits with yomiyasu. Update
both READMEs when setup or public behavior changes. Keep internal validation reports and progress slides outside the public repository,
including its Git history. Document supported behavior and limitations for users.

WaitIO.jl is MIT-licensed; the external WaitIO and MPI installations have their
own terms. Do not include their libraries or unpublished source code. Site paths
in documented aliases identify installations; personal configuration files,
private credentials, and account/allocation identifiers do not belong in Git.
