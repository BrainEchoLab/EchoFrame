# core/

The MATLAB library. Everything here is called by the acquisition and processing
scripts; nothing here is a demo, a test, or a benchmark.

| Folder | What it does |
|---|---|
| [`imaging/`](./imaging/) | Builds the spec structs and precomputes the reconstruction tables the CUDA core reads. |
| [`storage/`](./storage/) | Opens a recording and manages its lifecycle while data is being written. |
| [`reading/`](./reading/) | Reads a finished recording back off disk. |
| [`verasonics/`](./verasonics/) | Translates Verasonics Vantage structures into EchoFrame's specs. |
| [`setup/`](./setup/) | `ECHOFRAME_PATH` handling. |

The split between `storage/` and `reading/` is by verb: `storage/` writes recordings
during acquisition, `reading/` consumes them afterwards. Nothing in `reading/` is on
the live acquisition path.

None of these process data themselves — that is `echoframe_mex`'s job. They prepare
what it needs and manage what it writes.

The spec struct field tables live in [`../README.md`](../README.md).
