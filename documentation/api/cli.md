# Command line (echoframe_cli)

A batch tool for replaying stored RF through the core, with no MATLAB or Python
in the loop. Useful for offline processing and for benchmarking the core on its
own.

```sh
echoframe_cli ScanParameters.mat rf_acq.dat            # replay stored RF
echoframe_cli --benchmark ScanParameters.mat [iters]   # synthetic benchmark
```

Arguments are positional. In replay mode both are required; anything other than
exactly two prints the usage line and exits.

| Argument | What it is |
|----------|------------|
| `ScanParameters.mat` | the spec structs, as written by `init_storage` |
| `rf_acq.dat` | the RF buffers, as written by the `storage` MEX |

## Benchmark mode

`--benchmark` takes the specs but **no RF file** — it generates synthetic input and
runs `runSyntheticBenchmark`, so it measures the core without any disk read. The
optional third argument is the iteration count (default `1`).

```sh
echoframe_cli --benchmark ScanParameters.mat 100
```

Those are exactly the files an EchoFrame storage session produces, so anything
recorded from MATLAB can be replayed here.
`echoframe/matlab/tests/data/generate_echoframe_demo_data.m` will
produce a pair if you need one.

## What it does

1. Reads the specs out of the `.mat` with matio (`loadSpecsFromMat`).
2. Creates the core.
3. Reads the header of the RF file to learn how many buffers it holds.
4. Loops over every buffer: reads it, processes it, prints the elapsed time.

Timing is wall clock via `std::chrono`, measured around
`EchoFrameProcessAndGetOutputs` only, and printed per buffer:

```
Buffer 3/40 done in 12 ms
```

## Exit codes

| Code | Meaning |
|------|---------|
| 0 | finished |
| 1 | wrong number of arguments |
| 2 | the `.mat` could not be read, or a spec failed validation |
| 3 | the RF file could not be opened |
| 4 | `EchoFrameCreate` failed |
| 5 | the synthetic benchmark threw (`--benchmark` only) |

## Building

The CLI is not built by default in the sense that it needs three extra
dependencies — matio, HDF5 and zlib — which the MEX and Python targets do not.
`EF_BUILD_CLI` is `ON` by default, so it builds unless you turn it off:

```sh
cmake -S echoframe/cpp/src -B echoframe/cpp/src/build -DEF_BUILD_CLI=OFF ...
```

Those three dependencies are declared in `echoframe/cpp/src/vcpkg.json` and installed
by vcpkg at configure time, so there is no manual install step — the build only
needs `VCPKG_ROOT` set to a vcpkg checkout. See the main README for the one-time
vcpkg setup.

## Limitations

**There is no storage.** `EchoFrameCreate` is called with `use_storage = false`,
hard-coded, and the outputs are discarded after each buffer is timed — nothing is
written back to disk. `cli.cpp` carries a `// TODO: implement storage` where that
would go.

This is also why `loadSpecsFromMat` validates ReceiveSpec, ReconSpec, PDISpec and
FourierReconSpec but has nothing for the storage specs: there would be nothing to
validate them for. Adding storage means porting what the MEX does in
`convertMexResourcesWithStorage` over to matio, then flipping that
`EchoFrameCreate` flag.

## Internals

The helpers behind the CLI: reading the spec structs out of a MATLAB `.mat` file,
and reading RF buffers out of a storage `.dat` file.

```{doxygenfunction} loadSpecsFromMat
```

```{doxygenstruct} HeaderInfo
:members:
```

```{doxygenfunction} readHeader
```

```{doxygenfunction} readOneRFBuffer
```
