# Issue 10b: Refactor Backend — local_path() + content_hash()

#status:done

## Context

Issue 10 introduced `CloudMountedBackend` but the bytes-based approach has two problems:

1. **Dehydration detection is unreliable on kDrive.** On macOS FUSE, `open().read()` blocks
   until the file is downloaded, so `len(data) == st_size` always — the guard never fires.
   Placeholder files that kDrive returns as valid bytes (same size as the cloud file) cause
   pyexiv2 to fail with a parse error rather than an IOError.

2. **Double I/O for photo-media operations.** Every consumer of `backend.read()` for photo
   media immediately writes the bytes to a tmpfile:
   - `photo.py:extract_exif()` — bytes → `mkstemp` → `pyexiv2.Image(tmp_path)` → `unlink`
   - `thumbnail_builder.py:_stage_photos()` — bytes → tmpdir for image-proc subprocess
   - `preview_builder.py:generate_preview_jpeg()` — bytes → tmpdir for image-proc subprocess

   For local filesystem and FUSE-mounted backends the file already exists on disk.
   Loading it into Python memory and writing it back is pure waste.

3. **Hash computation is hard-coded to BLAKE3 from downloaded bytes.** Cloud services
   expose per-file checksums via REST APIs (kDrive: SHA256, OneDrive: quickXorHash,
   GDrive: MD5). A future API-backed backend could return the checksum without ever
   downloading the file. Today `content_hash` is a free function in `photo.py` — it cannot
   be overridden per backend.

## Solution

Add two new methods to the Backend Protocol:

- **`def local_path(path: str) -> Path | None`** — synchronous, I/O-free. Returns the
  absolute local path for backends where the file lives on the local filesystem (local,
  cloud-mounted). Returns `None` for future remote backends (S3, GCS, etc.).

- **`async def content_hash(path: str) -> str`** — computes or fetches the canonical
  content hash for a file. The canonical format is **BLAKE3 truncated to 128 bits,
  base64url-encoded without padding** — a 22-character URL- and filename-safe string
  (same as `hashing.content_hash()`). Default implementation reads bytes via
  `self.read()` and applies that formula. Future cloud API backends override to call the
  provider REST API and return the same 22-char format (or a different hash — see
  Future Extension Point below).

## Files to Modify

All paths relative to `ouestcharlie-py-toolkit/`.

| File | Change |
|------|--------|
| `src/ouestcharlie_toolkit/backend.py` | Add `local_path()` and `content_hash()` to Backend Protocol |
| `src/ouestcharlie_toolkit/backends/local.py` | Implement both methods |
| `src/ouestcharlie_toolkit/backends/cloud_mount.py` | Inherits both — no change needed |
| `src/ouestcharlie_toolkit/photo.py` | `create_identity()` delegates to `backend.content_hash()`; `extract_exif()` uses `local_path()` for pyexiv2 |
| `src/ouestcharlie_toolkit/thumbnail_builder.py` | `_stage_photos()` uses `local_path()` to skip staging |
| `src/ouestcharlie_toolkit/preview_builder.py` | `generate_preview_jpeg()` uses `local_path()` to skip staging |
| `tests/test_backend.py` | New tests for both methods |
| `tests/test_photo.py` | Update for new create_identity / extract_exif behavior |
| `tests/test_thumbnail_builder.py` | Test local-path fast path |
| `tests/test_preview_builder.py` | Test local-path fast path |
| `py_toolkit_LLD.md` | Update Backend Abstraction and XMP Creation sections |

## Implementation

### `backend.py` — extend the Backend Protocol

Add `from pathlib import Path` to imports (not currently present in this file).

Add after `delete_dir()`:

```python
def local_path(self, path: str) -> "Path | None":
    """Return the absolute local filesystem path for a backend-relative path.

    Returns a resolved Path for backends where the file lives on the local
    filesystem (local, cloud-mounted). Returns None for remote backends (S3, etc.).

    Synchronous and I/O-free.
    """
    ...

async def content_hash(self, path: str) -> str:
    """Return the canonical content hash for this file.

    Canonical format: BLAKE3 truncated to 128 bits, base64url-encoded without
    padding — a 22-character URL- and filename-safe string.

    Default implementation: reads the file and computes the BLAKE3 hash.
    Remote backends (kDrive, OneDrive, etc.) can override to fetch the
    provider checksum from their REST API without downloading the file.

    Raises:
        ValueError: If the file is empty (zero bytes).
        FileNotFoundError: If the file does not exist.
    """
    ...
```

### `backends/local.py` — implement both methods

Add after `_resolve()` (before `read()` at line ~149):

```python
def local_path(self, path: str) -> Path:
    return self._resolve(path)

async def content_hash(self, path: str) -> str:
    from ..hashing import content_hash as _hash
    data, _ = await self.read(path)
    if not data:
        raise ValueError(
            f"Photo file is empty — may not be downloaded from cloud storage: {path!r}"
        )
    return _hash(data)
```

`CloudMountedBackend(LocalBackend)` inherits both automatically:
- `local_path()` returns the FUSE mount path (correct)
- `content_hash()` calls `self.read()` which is overridden in CloudMountedBackend to
  include the retry loop — so dehydration retry is preserved

### `photo.py` — delegate hash to backend

**`create_identity()`** (lines 203–215):

```python
async def create_identity(self) -> str:
    if self._content_hash is None:
        self._content_hash = await self.backend.content_hash(self.path)
    return self._content_hash
```

**`extract_exif()`** (lines 217–292) — replace the `read()` call and tmp-file block:

```python
import pyexiv2  # lazy import unchanged
pyexiv2.set_log_level(4)

photo_hash = await self.backend.content_hash(self.path)
# content_hash() raises ValueError for empty files — no separate guard needed
suffix = Path(self.path).suffix or ".jpg"

local = self.backend.local_path(self.path)
if local is not None:
    img = pyexiv2.Image(str(local))   # pyexiv2 requires str, not Path
    exif_data: dict[str, str] = img.read_exif()
    img.close()
else:
    # Remote backend: stage bytes to a tmpfile for pyexiv2
    data, _ = await self.backend.read(self.path)
    fd, tmp_path = tempfile.mkstemp(suffix=suffix)
    try:
        os.write(fd, data)
        os.close(fd)
        img = pyexiv2.Image(tmp_path)
        exif_data = img.read_exif()
        img.close()
    finally:
        os.unlink(tmp_path)

self._content_hash = photo_hash
# ... rest unchanged (date, GPS, etc.) ...
```

Note: `content_hash()` already raises `ValueError` for empty files, so the existing
`if not data: raise ValueError(...)` guard in `extract_exif()` can be removed.

### `thumbnail_builder.py` — skip staging when local path is available

**`_stage_photos()`** (lines 63–76) — replace the inner loop body:

```python
for i, entry in enumerate(photo_entries):
    photo_path = f"{prefix}{entry.filename}"
    ext = os.path.splitext(entry.filename)[1]
    local = backend.local_path(photo_path)
    if local is not None:
        path_for_proc = str(local)
    else:
        photo_bytes, _ = await backend.read(photo_path)
        staged_path = os.path.join(tmpdir, f"photo_{i:06d}{ext}")
        Path(staged_path).write_bytes(photo_bytes)
        path_for_proc = staged_path
    photos_payload.append({
        "path": path_for_proc,
        "ext": ext,
        "orientation": entry.searchable.get("orientation"),
        "content_hash": entry.content_hash,
    })
```

`tmpdir` stays in the function signature — still required for `_call_image_proc()` output.

### `preview_builder.py` — skip staging when local path is available

**`generate_preview_jpeg()`** (lines 76–80) — replace the staging block inside the
`TemporaryDirectory` context:

```python
with tempfile.TemporaryDirectory(ignore_cleanup_errors=True) as tmpdir:
    local = backend.local_path(photo_path)
    if local is not None:
        staged_path = str(local)
    else:
        photo_bytes, _ = await backend.read(photo_path)
        staged_path = os.path.join(tmpdir, f"photo{ext}")
        Path(staged_path).write_bytes(photo_bytes)
    # ... payload building and image_proc.request() unchanged ...
```

`TemporaryDirectory` stays — `tmp_output` (image-proc JPEG output) still lives inside it.

## Tests

### `test_backend.py`

New synchronous tests (no `asyncio`) for `LocalBackend.local_path()`:
- `test_local_path_returns_resolved_path` — `backend.local_path("sub/img.jpg")` returns
  the correct absolute path
- `test_local_path_rejects_traversal` — `../../etc/passwd` raises `ValueError` (delegated
  from `_resolve()`)
- `test_cloud_mount_local_path_returns_resolved_path` — `CloudMountedBackend` inherits
  correctly

New async tests for `content_hash()`:
- `test_local_backend_content_hash` — returns correct BLAKE3 for known bytes
- `test_local_backend_content_hash_empty_raises` — empty file raises `ValueError`
- `test_cloud_mount_content_hash_uses_retry_read` — CloudMountedBackend's `content_hash()`
  calls its overridden `read()` (which has retry logic), not LocalBackend's `read()`

### `test_photo.py`

- Existing `test_extract_exif_*` tests use real `LocalBackend` and exercise the fast path
  automatically. No change needed for the happy path.
- Add `test_extract_exif_remote_backend_uses_tmpfile` — mock backend where `local_path()`
  returns `None` and `read()` returns valid JPEG bytes; assert `XmpSidecar` is correctly
  populated (exercises the fallback path).
- Add `test_create_identity_delegates_to_backend` — verify `create_identity()` calls
  `backend.content_hash()` rather than doing the hash computation itself.

### `test_thumbnail_builder.py` / `test_preview_builder.py`

- Existing tests using real `LocalBackend` will exercise the new local-path fast path.
- Add one test each asserting `backend.read()` is **not** called (monkey-patch to raise)
  when `local_path()` returns a non-None path.

## Documentation: `py_toolkit_LLD.md`

### Backend Abstraction section

- Update the protocol method list to include `local_path` and `content_hash`.
- Add a note under **Local Filesystem Backend**: `local_path()` returns `_resolve(path)` —
  synchronous and I/O-free; `content_hash()` reads via `read()` and returns the canonical
  hash (see Solution above). Raises `ValueError` for empty files.
- Add a **Cloud-Mounted Backend** subsection: `CloudMountedBackend` extends `LocalBackend`
  for FUSE/Windows CF API mounts. It overrides `read()` with a retry loop for incomplete
  reads. `local_path()` and `content_hash()` are inherited unchanged.

### XMP Creation at Ingestion section

Update step 2:

Before:
> Compute `content_hash(file_bytes)` (BLAKE3 128-bit, base64url, 22 chars) via `ouestcharlie_toolkit.hashing`

After:
> Compute the content hash via `backend.content_hash(path)`. Default: BLAKE3 128-bit,
> base64url, 22 chars (see Backend Abstraction). Future remote backends may fetch the hash
> from a provider REST API without downloading the file.

---

## Future Extension Point

A future `KDriveBackend` (or `OneDriveBackend`) can override `content_hash()` to call
the provider REST API:

```python
class KDriveBackend(Backend):
    async def content_hash(self, path: str) -> str:
        remote_sha256 = await self._api.get_file_checksum(path)  # no download
        return remote_sha256  # stored in sidecar as-is; algorithm noted separately
```

This requires the XMP sidecar to record the hash algorithm alongside `content_hash`, so
the indexer can skip re-downloading files where the stored hash matches the API hash.
That change (sidecar schema + indexer logic) is tracked in `OpenPoints.md` and is out of
scope for this issue.

## Verification

```shell
cd /Users/antoinehue/Code/charlie/ouestcharlie-py-toolkit
.venv/bin/python -m pytest tests/ -v
.venv/bin/python -m pytest tests_integration/ -v  # requires image-proc binary
```

Manual: configure a `cloud_mount` backend pointing at a kDrive folder with dehydrated
files, run the indexer. Confirm photos index successfully and no tmp files appear in `/tmp`
during EXIF extraction.
