# HLD Rationale

This document captures the reasoning behind design decisions in [HLD.md](HLD.md). Each section maps to its corresponding HLD section.

## EXIF and the Metadata Pipeline

Why extract EXIF into XMP sidecars rather than querying EXIF directly?

- **No image corruption risk** — original files are never written to
- **Format independence** — EXIF parsing (JPEG, HEIC, RAW, etc.) happens once at extraction, not on every query
- **Recoverable metadata** — if an XMP sidecar is lost, a housekeeping agent can re-extract EXIF from the image and enrichment agents can re-enrich
- **Negligible storage overhead** — EXIF duplication in XMP is tiny compared to image size

## Folder Structure and Partitioning

### Why physical structure is internal

The physical structure is an **internal optimization**, not a user-facing concept. Users browse through consumption agents using smart albums, timeline views, and filters — not by navigating raw folders.

### Index mode characteristics

- **No file movement**: Photos stay exactly where the user placed them. Only `.ouestcharlie/` directories are created.
- **Uneven partitions**: Folder sizes reflect user behavior, not optimization targets. A `Camera Roll` folder may contain thousands of photos while `Birthday 2024` has 50. The manifest tree adapts to whatever structure exists.
- **Existing XMP preserved**: If photos already have XMP sidecars (from Lightroom, darktable, etc.), the housekeeping agent reads them rather than re-extracting from EXIF.
- **Mixed depth**: The manifest tree can have varying depth — a flat folder with 200 photos coexists with a deeply nested `Vacations/Italy 2023/Day 3/` structure. Each leaf folder with photos gets its own manifest regardless of depth.

### Object storage considerations (S3, GCS)

- **Shallow prefix depth**: `YYYY/YYYY-MM/` is only 2 levels of prefix. Deeper nesting (adding `/DD/`) would create 365x more prefixes with few objects each, increasing LIST call overhead.
- **Prefix-based load distribution**: S3 automatically partitions by key prefix. Date-based prefixes spread writes across partitions, avoiding throttling.
- **No directory listing**: There are no directories — `ListObjectsV2` with `Delimiter=/` simulates folder listing. Manifest-based navigation avoids listing entirely; agents read manifests by their well-known path.
- **IAM path scoping**: S3 IAM policies and GCS IAM Conditions can restrict access by prefix (e.g., `photos/2024/*` for a scoped enrichment agent).

### API-based storage considerations (OneDrive, Kdrive)

- **API pagination**: Folder contents are retrieved via paginated API calls. Keeping partitions at ~1,000 photos means each folder listing fits in 1-2 API pages (typical page size: 200-1000 items).
- **Rate limiting**: OneDrive and Kdrive APIs have request rate limits. Manifest-based navigation minimizes API calls — a consumption agent reads manifest files by path, never lists directories.

### Why ~1,000 photos per partition

Each leaf folder (partition) targets **~1,000 photos**. This balances manifest size, pruning granularity, and thumbnail container efficiency.

| Photos per partition | Manifest size (full XMP inline) | Thumbnail AVIF size | S3 read latency |
|---|---|---|---|
| 200 | ~200-300 KB | ~2-6 MB | ~55 ms |
| **1,000** | **~1-1.5 MB** | **~10-30 MB** | **~80 ms** |
| 5,000 | ~5-7.5 MB | ~50-150 MB | ~150 ms |

At 1,000 photos per partition, a **100,000 photo library** has ~100 leaf partitions.

## Thumbnail Storage

### Problem

Each folder can contain many photos. Storing one thumbnail file per photo creates a proliferation of small files, which is costly on object storage (per-request latency and pricing) and clutters the folder structure.

### Format Analysis

| Format | Multi-image container | Random access to individual thumbnails | Compression | Platform support |
|---|---|---|---|---|
| Individual JPEG/WebP | N/A (one file per photo) | N/A | Good | Universal |
| Sprite sheet (single WebP/JPEG) | Grid layout, one file | By pixel offset (requires decoding full image) | Good | Universal |
| Multi-page TIFF | Yes | Yes, by IFD offset | Moderate (LZW) | Universal |
| HEIF/HEIC | Yes (ISOBMFF container) | Yes, by item index | Excellent (HEVC) | iOS/macOS native, limited elsewhere |
| **AVIF grid** | **Yes (ISOBMFF container)** | **Yes, each tile independently decodable** | **Excellent (AV1)** | **All major platforms** |

### Why AVIF Grid Containers

**Advantages over alternatives:**
- **vs. individual files**: Reduces file count from N to 1 per folder. Critical for object storage cost and latency.
- **vs. sprite sheets**: Individual tiles can be decoded independently — no need to decode the entire image to extract one thumbnail. Better for progressive loading.
- **vs. HEIF/HEIC**: AVIF is open and royalty-free (AV1-based), with broader cross-platform support. HEVC licensing is complex.
- **vs. multi-page TIFF**: Better compression, smaller files.

**Platform support (native, no additional dependencies):**
- Android 12+ (Oct 2021)
- iOS 16+ / macOS Ventura+ (Sep 2022)
- Windows 11 22H2+
- All major browsers: Chrome 85+, Firefox 93+, Safari 16+, Edge 90+
- Linux: via [libavif](https://github.com/AOMediaCodec/libavif) and `avif-pixbuf-loader`

**Reference implementation**: [libavif](https://github.com/AOMediaCodec/libavif) by the Alliance for Open Media — C library, cross-platform, supports grid encoding/decoding with per-tile random access.

**References:**
- [AVIF specification - Alliance for Open Media](https://aomedia.org/specifications/avif/)
- [libavif - GitHub](https://github.com/AOMediaCodec/libavif)
- [AVIF browser support - Can I Use](https://caniuse.com/avif)
- [AVIF - Wikipedia](https://en.wikipedia.org/wiki/AVIF)
- [libavif-container](https://github.com/link-u/libavif-container) — AVIF container manipulation library

## Albums

### Why album definitions are device-local

Album definitions are device-local (see HLR: Albums for rationale). Manual album **tags** (`album/*`) still live in XMP sidecars within each backend — they are per-photo metadata and travel with the photos.

**Multi-device sync** of album definitions is an optional, separable concern. Devices can sync `albums.json` via a shared backend, a git repo, or a syncing service.

## Content-Based Identity and Deduplication

### Mobile Backup Scenario (illustrative example)

1. User takes a photo on their phone → stored locally with hash `sha256:abc123` written to XMP sidecar
2. Mobile backup agent syncs the photo to S3 → the photo file and its XMP sidecar (containing the same hash) are uploaded
3. The S3 backend now has a photo with hash `sha256:abc123`, and the local backend has the same
4. When a consumption agent queries both backends, it sees two results with the same content hash and deduplicates — showing the photo once, preferring the local copy for display (lower latency)
5. If the user deletes the local copy, the consumption agent seamlessly falls back to the S3 copy — same hash, same photo, different backend

### Design Consequences

- **No coordination required**: Each backend independently stores hashes in XMP sidecars. Deduplication is computed at read time, not write time.
- **Hash collisions**: SHA-256 has a negligible collision probability (2^-128 for birthday attack). No collision handling is needed in practice.
- **Backend migration**: Moving photos between backends preserves identity — the content hash doesn't change, so cross-references, album tags, and enrichment metadata remain valid.
- **Partial replication**: Users can choose to replicate only some folders to a cloud backend. The hash-based identity ensures that duplicated photos are recognized regardless of their storage path.

## Security and Access Control

### Immutability and Write-Scoping Enforcement per Backend

Photo immutability and metadata write-scoping can be enforced at the backend level, with varying strength depending on the provider:

**S3** — strong enforcement via IAM policies:
- Photo immutability: deny `s3:PutObject` / `s3:DeleteObject` on photo paths for all agents except ingestion
- Metadata write-scoping: allow `s3:PutObject` on `*.xmp` and manifest paths only for housekeeping/enrichment roles
- Consumption agents receive `s3:GetObject` only — they physically cannot modify anything

**Local filesystem** — moderate enforcement via file permissions:
- After ingestion, photo files are set read-only (`chmod 444`)
- XMP sidecars and manifests remain writable by the application user
- Effective against accidental writes; not a hard boundary against a process running as the same user

**GCS** — strong enforcement via IAM Conditions:
- Photo immutability: deny `storage.objects.create` / `storage.objects.delete` on photo prefixes for all agents except ingestion
- Metadata write-scoping: allow `storage.objects.create` on XMP/manifest prefixes only for housekeeping/enrichment service accounts
- IAM Conditions support `resource.name` prefix matching for path-level scoping
- Consumption agents receive `storage.objects.get` only

**ADLS Gen2** — strong enforcement via POSIX ACLs:
- ADLS Gen2 with hierarchical namespace enabled supports POSIX-like ACLs at the directory and file level
- Photo immutability: set read + execute on photo directories, no write, for all agent service principals except ingestion
- Metadata write-scoping: grant write on XMP/manifest paths only to housekeeping/enrichment principals
- Combined with Azure RBAC for coarse-grained access and ACLs for fine-grained path control

**OneDrive / Kdrive** — application-level enforcement only:
- These consumer-grade APIs do not support fine-grained path-based or suffix-based ACLs
- Read-only sharing links can protect consumption agents, but there is no way to allow "write XMP but not photos" at the provider level
- Mitigation: the application layer enforces scopes before issuing any write call

### Threat Model Summary

| Threat | Local mitigation | Cloud mitigation |
|---|---|---|
| Unauthorized access | OS auth + filesystem permissions | Scoped short-lived tokens |
| Data exfiltration by rogue agent | App sandbox / in-process scope check | IAM policy restricts paths + actions |
| Credential theft | OS keychain | Master credential never leaves device; scoped tokens expire |
| Data at rest exposure | OS-level disk encryption | Provider-side encryption (SSE-S3, Azure Storage encryption, OneDrive encryption) |
| Man-in-the-middle | N/A (local) | TLS enforced |
