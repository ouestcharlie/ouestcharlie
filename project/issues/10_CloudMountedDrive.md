# Issue 10: CloudMountedBackend for FUSE/File Provider cloud sync mounts

#status:done

## Context
When indexing a library on a cloud-mounted drive (kDrive, OneDrive, Google Drive, Dropbox), files not yet downloaded locally cause pyexiv2.Image() to fail. The behaviour depends on the platform and provider:

macOS/Linux (FUSE): kDrive mounts via FUSE. open().read() blocks at the OS level until the file is fully downloaded — the asyncio event loop is unaffected (the thread pool worker blocks, not the loop). The file returned is always complete.
Windows (Storage Provider / CF API): Cloud providers use Windows placeholder files with FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS. Reads trigger a download, but not all Windows providers block until completion — some return partial data immediately and expect the caller to retry.
Design: blocking read + completeness check + graceful error

CloudMountedBackend.read():

Issues a blocking read (on POSIX FUSE this blocks until the file is fully downloaded).
Compares len(data) against st_size (from the same fstat call).
If incomplete (Windows CF API returning partial data, or download failure), raises IOError with a clear diagnostic. The indexer's per-photo error handler catches this and counts it as a skipped photo — non-fatal, shown in IndexResult.error_details.
Future — API-backed identity (not implemented here): cloud services expose per-file checksums (kDrive: SHA256; OneDrive: quickXorHash; GDrive: MD5) via their REST APIs. A future KDriveBackend (or similar) could fetch the remote checksum without downloading the file and compare it against the sidecar's content_hash. If they match, the file is already indexed and no download is needed. Noted in OpenPoints.md.

The existing ValueError in photo.py for truly 0-byte files (stat size == 0 too) is kept as a safety net for genuinely empty files.

## Files to Modify
- ouestcharlie-py-toolkit/src/ouestcharlie_toolkit/backends/cloud_mount.py — new file
- ouestcharlie-py-toolkit/src/ouestcharlie_toolkit/backend.py — "cloud_mount" in backend_from_config
- ouestcharlie-py-toolkit/tests/test_backend.py — new CloudMountedBackend tests
- ouestcharlie/OpenPoints.md — note API-backed identity as a future optimisation

### Implementation
New file: backends/cloud_mount.py

```Python
"""CloudMountedBackend — LocalBackend for FUSE/CF-API cloud mounts."""

from __future__ import annotations

import asyncio
import logging
import os
from pathlib import Path

from ..backend import VersionToken
from .local import LocalBackend

_log = logging.getLogger(__name__)


class CloudMountedBackend(LocalBackend):
    """LocalBackend for FUSE/Windows-CF-API cloud mounts (kDrive, OneDrive, GDrive, Dropbox).

    On POSIX (macOS/Linux with FUSE), open().read() blocks until the cloud sync
    client finishes the download, so the completeness check always passes.

    On Windows (Storage Provider / CF API), some providers return partial data.
    In that case an IOError is raised immediately so the indexer records the photo
    as a skipped error rather than feeding corrupt data to pyexiv2.

    Configure with {"type": "cloud_mount", "root": "/path/to/mount"}.
    """

    async def read(self, path: str) -> tuple[bytes, VersionToken]:
        full_path = self._resolve(path)
        loop = asyncio.get_event_loop()

        def _read_with_size() -> tuple[bytes, int, int]:
            with open(full_path, "rb") as fd:
                mtime_ns = os.fstat(fd.fileno()).st_mtime_ns
                data = fd.read()
                st_size = os.fstat(fd.fileno()).st_size
            return data, mtime_ns, st_size

        data, mtime_ns, st_size = await loop.run_in_executor(None, _read_with_size)

        if st_size > 0 and len(data) < st_size:
            raise IOError(
                f"Incomplete read for cloud-mounted file "
                f"(got {len(data)} of {st_size} bytes): {path!r}"
            )

        return data, VersionToken(mtime_ns)
```

st_size is read from a second fstat() on the same open fd after read() completes — atomically consistent with the bytes that were returned.

backend.py — backend_from_config
Add after the "filesystem" branch:

if backend_type == "cloud_mount":
    from .backends.cloud_mount import CloudMountedBackend
    root = config.get("root")
    if not root:
        raise ConfigurationError("cloud_mount backend requires 'root' field")
    return CloudMountedBackend(root)
Config example:

{ "type": "cloud_mount", "root": "/Users/alice/kDrive" }
Tests (test_backend.py)
New section # CloudMountedBackend:

test_cloud_mount_read_returns_full_file
  — normal file with content; asserts correct bytes and version token returned.

test_cloud_mount_read_zero_byte_file
  — truly 0-byte file (st_size == 0); asserts b"" returned without error
    (0-byte files are valid, not cloud placeholders).

test_cloud_mount_read_raises_on_incomplete_data
  — writes N bytes to a file, then monkeypatches _read_with_size to return
    (partial_bytes, mtime, N) with len(partial) < N; asserts IOError with
    "Incomplete read" in the message.

test_backend_from_config_cloud_mount
  — backend_from_config({"type": "cloud_mount", "root": tmpdir}) returns CloudMountedBackend.

test_backend_from_config_cloud_mount_missing_root
  — raises ConfigurationError.

OpenPoints.md
Add entry: API-backed identity for cloud storage backends — a KDriveBackend (and similar) could fetch the remote file checksum (SHA256 on kDrive) via the cloud REST API and compare it against the sidecar's content_hash, skipping the full download for files that are already indexed and unchanged. Requires: a get_checksum() extension on Backend, and storing the remote hash algorithm in the XMP sidecar alongside content_hash.

### Verification

```shell
cd /Users/antoinehue/Code/charlie/ouestcharlie-py-toolkit
.venv/bin/python -m pytest tests/test_backend.py -v -k "cloud_mount"
.venv/bin/python -m pytest tests/ -v
Manual: set backend type to "cloud_mount" pointing at a kDrive mount folder, run index_library; files that trigger on-demand download should index successfully.
```

