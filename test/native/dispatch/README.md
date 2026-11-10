# Native symbol dispatch diagnostic

This small C shared library returns distinct sentinels from different function
names. It checks that `layered`/`Nnary`, uppercase/lowercase names, status arrays,
and registration handles reach the exact C symbol, even with legacy settings.
A deliberately absent symbol must remain absent. It does not implement WaitIO,
start MPI, test networking, or establish C/Julia protocol interoperability.

From the package root:

```sh
cc -shared -fPIC -o /tmp/waitio-dispatch.so test/native/dispatch/symbols.c
julia --project=. test/native/dispatch/check.jl /tmp/waitio-dispatch.so
```

Only this diagnostic needs a C compiler. Mixed-language communication with the
installed WaitIO libraries is covered by the separate [reference suite](../reference/README.md).
