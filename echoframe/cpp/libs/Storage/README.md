# Storage

A standalone C++ library for high-throughput streaming of acquisition buffers to
disk. The same library is compiled into two places: the standalone `storage`
MATLAB MEX gateway, and `echoframe_mex`. During live acquisition `echoframe_mex`
uses it internally to stream the **BF, PDI, RF and RF-time-tag** buffers (each
stream via its own `Handler`). The standalone `storage` MEX is no longer part of
the live acquisition path — RF storage moved inside `echoframe_mex` — and now
serves as a standalone gateway, e.g. the OLD-vs-NEW comparison in
`echoframe/matlab/benchmarks/benchmark_storage.m`.

## What it does

Writes a sequence of fixed-size, typed buffers to one `.dat` file, fast enough to
keep up with real-time acquisition. There are two backends behind one API,
selected by `Handler.h` on `_WIN32` / `__linux__`: `WindowsFileIO` and
`LinuxFileIO`. Both get their throughput from asynchronous, direct I/O rather
than plain synchronous writes:

- **Several writes in flight** — buffer writes are queued through a pool of
  "workers" rather than written one at a time. On Windows that is overlapped I/O
  with an I/O completion port (`writeOverlappedBuffer`, `getAvailableWorker`,
  `dequeueNWorkers`, `waitForIoComplete`); on Linux it is POSIX AIO
  (`aio_write` / `aio_suspend`).
- **Unbuffered direct writes** — the page cache is bypassed
  (`FILE_FLAG_NO_BUFFERING` on Windows, `O_DIRECT | O_DSYNC` on Linux), so
  buffers and the header are sector-size aligned (padding is added when a buffer
  is not a multiple of the sector size, and recorded in the header). The
  alignment is queried at open time — `queryAlignment()` — from the physical
  sector size on Windows and from `statx(STATX_DIOALIGN)` on Linux.
- **Preallocation + privileged extension** — with `preallocateFullFile` the file
  is sized up front. On Windows extension uses `SE_MANAGE_VOLUME_NAME`
  (`SeManageVolumePrivilege`) to grow files without zero-filling; on Linux it
  uses `posix_fallocate` / `ftruncate`.

  On Windows this privilege is **required, not an optimisation**.
  `Handler::init` calls `assignPriviledges()` (`Handler.t.hpp:37`) before it opens
  or extends anything, and independently of `preallocateFullFile`. If the process
  cannot obtain the privilege, `WindowsFileIO::assignPrivileges` throws and the
  handler prints the error and calls `std::terminate()` — so a non-elevated host
  process dies outright rather than falling back to a slower path. Inside MATLAB
  that takes the whole session down. On Linux `assignPrivileges` is a documented
  no-op, so none of this applies.
- **Self-describing header** — each file starts with a header (version, header
  size, buffers stored, buffer size, padding bytes, data-type code). This is the
  header `echoframe/matlab/core/reading/read_header.m` parses when reading recordings
  back.

Note: it does **not** use OS shared memory or spawn processes — the concurrency is
purely asynchronous file I/O.

## Layout

- `src/storage/storage_spec.h` — `StorageSpec` (filepath, dataType, bufferSize,
  buffer counts, `crop`, `preallocateFullFile`).
- `src/storage/Handler.{h,t.hpp}` — `Handler<bufferType_t>`: the storage engine
  (open / extend / switch file, `storeBuffer`, `initiateStorage`, data-type
  decoding, privilege assignment).
- `src/storage/Windows/WindowsFileIO.{h,t.hpp}` — the overlapped-I/O + IOCP
  backend and the on-disk header.
- `src/storage/Linux/LinuxFileIO.{h,t.hpp}` — the POSIX AIO + `O_DIRECT`
  backend, mirroring the same public API.
- `src/mex/storage.{h,cpp}` — the MATLAB `storage` MEX gateway. Commands:
  `'init'` (open a recording), `'re-init'` (start another with the same config),
  `'store'` (queue a buffer).
- `src/utils/` — helpers shared by the handler and the MEX gateway.

## Building

Built by its own CMake project (`CMakeLists.txt`, project `CUBE_STORAGE`) into the
`storage` MEX. The same `Handler` / `WindowsFileIO` / `LinuxFileIO` template code
is also compiled into `echoframe_mex`, so a change here requires rebuilding
**both** MEX files. A
recording's storage specs are built by `echoframe/matlab/core/storage/init_storage.m`;
`echoframe_mex` drives the per-stream buffer writes internally. The standalone
`storage('init', ...)` / `storage('store', RF)` gateway commands are exercised by
`echoframe/matlab/benchmarks/benchmark_storage.m`.
