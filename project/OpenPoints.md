# Open Points

## 1. Video support is never mentioned

The HLR says "photo management" but modern phone libraries are 30-50% video. The design never addresses whether video is in scope, out of scope, or deferred. If it's out of scope, it should say so explicitly — otherwise every design decision (AVIF containers, EXIF extraction, thumbnail tiers, size estimates) implicitly excludes video without acknowledging it.

## 4. No offline / partial-connectivity story

The architecture has local + cloud backends, but there's no design for what happens when the cloud is unreachable. Can the user still browse? Are manifests cached locally? What about writes queued for sync? This is critical for mobile use cases (mobile backup is explicitly listed as a use case).

## 8. EXIF extraction reads the full image and writes a temp copy to local disk

The current `Photo.extract_exif()` implementation has two inefficiencies worth revisiting:

**Full image read.** `backend.read()` loads the entire file into memory to compute the SHA-256 hash.  Exiv2/pyexiv2 only needs the EXIF APP1 segment (typically the first ≈ 64 KB of a JPEG), so fetching the whole file is wasteful for large RAWs or HEICs (50–100 MB).  A potential improvement is a `Backend.read_partial(path, max_bytes)` API that lets EXIF extraction fetch only the metadata header, while the hash computation still fetches the full file (or is deferred).

**Temp copy on local disk.** pyexiv2 requires a file path — it cannot parse EXIF from an in-memory buffer.  The current code writes the entire image to a `tempfile.mkstemp` file on the local filesystem before calling `pyexiv2.Image(tmp_path)`, then deletes it.  For cloud-backed photos this means downloading the full file and writing it to local disk even when the goal is only to read metadata.  Options worth evaluating: (a) expose a streaming / partial-read path in the backend and write only the first N bytes to the temp file (sufficient for EXIF), (b) switch to a library that accepts in-memory buffers (e.g. `exifread`, `pillow`, or the pyexiv2 `ImageData` API if available), or (c) keep the current approach but bound temp file size when only EXIF is needed.

## 10. Full-file ~~SHA-256~~ hash is expensive as a photo identity fingerprint

`content_hash` is currently computed by hashing the entire file with SHA-256.  For large RAW or HEIC files (20–100 MB) on a cloud backend, this means downloading the full file on every first encounter or forced re-index.  The hash is stored in the XMP sidecar after the first run, so the cost is paid once — but it is significant for initial ingestion of large libraries or when detecting changes.

**The core tension:** full-file hash is change-detecting (any byte change produces a different hash) but expensive.  Cheaper alternatives trade some of that robustness:

**Partial file hash — start + end + size.** SHA-256 of `first 64 KB + last 4 KB + file_size`.  Requires only two small reads regardless of file size.  Distinct photos will virtually never collide.  However it is sensitive to EXIF/XMP edits that touch the file header — a metadata-only edit would produce a different hash, which may or may not be desirable.

**Image-data-only hash for JPEG.** Parse JPEG markers, skip all APP segments (EXIF, XMP, ICC profile — all at the start of the file), then SHA-256 only the compressed scan stream.  This is metadata-edit-resistant: rating or tagging a photo does not change its `content_hash`.  Downside: still requires reading most of the file (scan data is typically 90–95% of JPEG size), and requires per-format parsing logic.

**Cloud ETag as the change signal.** Object stores (S3, kDrive) expose an ETag per object that changes when the object is replaced.  The backend could expose this as the version token and use it to skip re-hashing when the ETag is unchanged since the last indexing run.  Full-file hash would then only be computed on first encounter or when the ETag changes.  Limitation: local filesystem has no equivalent (mtime is unreliable across copies).

**Recommended direction.** The ETag/version-token approach is the most architecture-consistent: backends already return a `VersionToken` from `list_files`, and the XMP sidecar already stores `xmp_version_token`.  Extending this to skip re-hashing when the token is unchanged would be low-risk and high-impact for cloud backends, without changing the identity semantics.


## 11. Woof V1 runs as a stdio MCP server — no background daemon

For V1, Woof is launched on demand by Claude Desktop as a stdio MCP server process. It exits when Claude Desktop closes. This is sufficient for the V1 scope (manual indexing, search) but will need to change when the following features are added:

- **Change detection**: FSEvents file watching must survive Claude Desktop being closed
- **Scheduled enrichment**: housekeeping and enrichment passes should run on a schedule, independently of the UI
- **Agent executions outlasting a session**: long indexing runs should not be interrupted by the user closing Claude Desktop

**V2 path**: Deploy Woof as a launchd agent on macOS (and equivalent on other platforms). Claude Desktop connects to the already-running instance via the MCP transport declared in the Desktop Extension manifest. The dirty partition queue and activity log (already designed in the LLD) become meaningful only once the daemon model is active.

**V1 constraint accepted**: the dirty partition queue and any background scheduling logic in the LLD are not implemented for V1.

## 13. Packaging and install

We need to complete dependency lists for each platform, install on each platform.
Is the current architecture ok for mobile, or only ok for desktop with apps like Claude?
Are we compatible with other desktop applications?

We also need an install documentation.