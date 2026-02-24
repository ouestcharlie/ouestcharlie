# Open Points

## 1. Video support is never mentioned

The HLR says "photo management" but modern phone libraries are 30-50% video. The design never addresses whether video is in scope, out of scope, or deferred. If it's out of scope, it should say so explicitly — otherwise every design decision (AVIF containers, EXIF extraction, thumbnail tiers, size estimates) implicitly excludes video without acknowledging it.

## 4. No offline / partial-connectivity story

The architecture has local + cloud backends, but there's no design for what happens when the cloud is unreachable. Can the user still browse? Are manifests cached locally? What about writes queued for sync? This is critical for mobile use cases (mobile backup is explicitly listed as a use case).

## 7. No search or query language specification

The HLD shows filter examples like `date:2024 AND tag:travel` and `rating >= 4` but never defines the query language. Bloom filters are mentioned for pruning, but what fields are indexed? What operators are supported? This is central to how consumption agents work.

## 8. EXIF extraction reads the full image and writes a temp copy to local disk

The current `Photo.extract_exif()` implementation has two inefficiencies worth revisiting:

**Full image read.** `backend.read()` loads the entire file into memory to compute the SHA-256 hash.  Exiv2/pyexiv2 only needs the EXIF APP1 segment (typically the first ≈ 64 KB of a JPEG), so fetching the whole file is wasteful for large RAWs or HEICs (50–100 MB).  A potential improvement is a `Backend.read_partial(path, max_bytes)` API that lets EXIF extraction fetch only the metadata header, while the hash computation still fetches the full file (or is deferred).

**Temp copy on local disk.** pyexiv2 requires a file path — it cannot parse EXIF from an in-memory buffer.  The current code writes the entire image to a `tempfile.mkstemp` file on the local filesystem before calling `pyexiv2.Image(tmp_path)`, then deletes it.  For cloud-backed photos this means downloading the full file and writing it to local disk even when the goal is only to read metadata.  Options worth evaluating: (a) expose a streaming / partial-read path in the backend and write only the first N bytes to the temp file (sufficient for EXIF), (b) switch to a library that accepts in-memory buffers (e.g. `exifread`, `pillow`, or the pyexiv2 `ImageData` API if available), or (c) keep the current approach but bound temp file size when only EXIF is needed.


