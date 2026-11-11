# echoframe/cpp/libs

External libraries used by the C++ core.

## GSL — Microsoft Guidelines Support Library

A submodule (`github.com/microsoft/GSL`) providing the C++ Core Guidelines support
types — `gsl::span`, `gsl::not_null`, and related bounds/lifetime helpers — used
across the core for safer array views and pointer contracts. Header-only.

Note: this is Microsoft's **Guidelines** Support Library, not the GNU Scientific
Library.

## ffdas

A submodule (`github.com/BrainEchoLab/ffdas`) providing the CUDA
DAS beamformer backend. EchoFrame always builds it, so the submodule must
be initialised before configuring; a missing submodule is a hard CMake
error rather than a silently reduced build.

## Storage

An in-tree library (`Storage/`, not a submodule) that manages writing and reading
real-time RF, BF and PDI data to disk.

## Updating submodules

To initialise or update external submodules from the repository root:

```bash
git submodule update --init echoframe/cpp/libs/GSL echoframe/cpp/libs/ffdas
```
