# Windows + OneDrive Performance Analysis

## Context

Observed: thumbnail and preview generation is significantly slower on Windows + OneDrive
compared to macOS with similar hardware. This document captures the root cause analysis.

## Bottlenecks (by severity)

### 1. Subprocess startup cost — `image-proc` (critical)

Every thumbnail chunk and every preview JPEG spawns a new `asyncio.create_subprocess_exec()`
call to the Rust `image-proc` binary. On Windows, process creation is **10–50x more
expensive** than on Unix — there is no `fork()`, so each invocation requires a full
context setup. With hundreds of photos this dominates total runtime.

**Preview:** 1 subprocess per photo.
**Thumbnails:** 1 subprocess per chunk (up to 64 photos/chunk), chunks run in parallel.

→ See [persistent image-proc design](../project/) for the planned mitigation on the preview side.

### 2. Antivirus interference on atomic renames (critical)

`_atomic_replace()` in `local.py` already has a Windows-specific retry loop (up to 5
retries, exponential backoff: 10 → 80 ms) to handle Windows Defender briefly locking
freshly-written files. That adds up to **~150 ms worst-case latency per file write**,
accumulating across hundreds of XMP sidecars and AVIF tiles.

### 3. Cross-process lock spin-wait (high)

The Windows cross-process lock uses `msvcrt.locking()`, which **spin-waits** rather than
blocking at the kernel level like Unix `fcntl.flock()`. Under concurrent indexing
(semaphore cap = 4 partitions), this causes CPU waste and write serialization.

### 4. `glob()` on OneDrive (high)

`list_files()` runs **13 separate glob patterns** (one per photo extension,
case-insensitive) per partition. On OneDrive, each glob may trigger cloud I/O round-trips.
macOS local NVMe makes this nearly free; Windows + OneDrive amplifies it significantly.

### 5. Temp directory I/O per chunk / preview (medium)

Each thumbnail chunk and each preview creates a `TemporaryDirectory`, writes staging
copies of the photos into it, calls `image-proc`, then reads back the result. On Windows
with antivirus scanning temp files or slow storage, this adds latency on top of the
subprocess cost.

### 6. ProactorEventLoop scheduling overhead (low-medium)

Python 3.10+ defaults to `ProactorEventLoop` on Windows (IOCP-based). It has higher
per-operation overhead than the `epoll`/`kqueue` loops used on macOS for this mix of
async + thread-pool workload. Not a major factor alone, but compounds the others.

### 7. Atomic rename retry loop — Windows-specific (already mitigated, but visible)

Already handled by the 5-retry exponential backoff in `_atomic_replace()`. Worth
monitoring retry rates in logs to quantify real-world impact.

## Planned Mitigations

| Bottleneck | Mitigation | Status |
|---|---|---|
| Subprocess cost (preview) | Persistent `image-proc` process in Wally | Planned |
| Subprocess cost (thumbnails) | Persistent `image-proc` pool in Whitebeard | Future |
| glob() on OneDrive | Batch single-pass directory scan | Future |
| Antivirus / rename retries | No good mitigation; retry logic already in place | — |
| Cross-process lock spin-wait | No good mitigation without changing the lock primitive | — |
