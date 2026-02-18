# High Level Design

## Root Configuration (lightweight catalog)

Unlike Iceberg which requires a catalog service to locate tables, OuEstCharly uses a **local configuration file** as its entry point. This preserves the "no central database" principle while giving agents a way to discover storage backends and root manifests.

The configuration lives on each device that runs agents:

```
~/.ouestcharly/config.json
{
  "backends": [
    { "name": "local", "type": "filesystem", "root": "/Users/alice/Photos" },
    { "name": "cloud-s3", "type": "s3", "bucket": "alice-photos", "root": "/" },
    { "name": "cloud-adls", "type": "adls2", "account": "alicephotos", "filesystem": "photos", "root": "/" },
    { "name": "cloud-gcs", "type": "gcs", "bucket": "alice-photos", "root": "/" },
    { "name": "kdrive", "type": "kdrive", "root": "/Photos" }
  ]
}
```

Key design decisions:

- **Each backend is independent**: every backend has its own root manifest and its own metadata tree. There is no cross-backend unified namespace — each is a self-contained photo collection.
- **No shared catalog service**: the config file is local to the device. Two devices accessing the same S3 bucket each have their own config pointing to it. The bucket itself is the source of truth (via its root manifest), not the config.
- **Convention-based root manifest**: within each backend, the root manifest is always at a well-known path (e.g., `/.ouestcharly/root-manifest.json`). Agents don't need the config to tell them where the manifest is — they just need the backend connection info.
- **Agent discovery**: when an agent starts, it reads the config, connects to its assigned backend(s), and reads the root manifest to understand the current state. From there, the hierarchical manifest tree guides all operations.

## EXIF and the Metadata Pipeline

Photo files are **immutable** — they are never modified after ingestion. EXIF data embedded in images (date, GPS, camera, orientation, etc.) is treated as **read-only input** to the metadata pipeline:

1. **Extraction**: At ingestion, a housekeeping agent reads EXIF from the image file and writes it into an XMP sidecar. This is the only time the image file is read for metadata.
2. **Enrichment**: Agents add new metadata (faces, descriptions, scene tags) to the XMP sidecar. The image file is read for pixel analysis but never written to.
3. **Consolidation**: Manifests aggregate XMP sidecars, never EXIF directly.

The XMP sidecar is the **single source of truth** for all queryable metadata. Agents and consumers never need to parse EXIF from images — they only read XMP and manifests.

This has key consequences:
- **No image corruption risk** — original files are never written to
- **Format independence** — EXIF parsing (JPEG, HEIC, RAW, etc.) happens once at extraction, not on every query
- **Recoverable metadata** — if an XMP sidecar is lost, a housekeeping agent can re-extract EXIF from the image and enrichment agents can re-enrich
- **Negligible storage overhead** — EXIF duplication in XMP is tiny compared to image size

## Folder Structure and Partitioning

### Physical structure strategy

OuEstCharly supports two operating modes for folder organization:

**Index mode** (existing library): The housekeeping agent scans the existing folder tree, builds manifests mirroring the physical structure, and extracts XMP sidecars. No files are moved. The user's original organization is preserved and becomes the manifest tree.

**Ingest mode** (new photos): The ingestion agent places photos into a canonical **date-based partitioning** scheme based on the photo's capture date (from EXIF). The physical layout is optimized per backend type.

The physical structure is an **internal optimization**, not a user-facing concept. Users browse through consumption agents using smart albums, timeline views, and filters — not by navigating raw folders.

### Index mode: original structure preserved

When OuEstCharly indexes an existing photo library, it overlays `.ouestcharly/` metadata directories without moving any files. The user's folder hierarchy becomes the manifest tree:

```
/Photos/                                    ← user's existing root
├── .ouestcharly/
│   └── manifest.json                       ← root manifest (consolidates children)
├── Vacations/
│   ├── .ouestcharly/
│   │   └── manifest.json                   ← mid-level manifest (consolidates Italy + Japan)
│   ├── Italy 2023/
│   │   ├── .ouestcharly/
│   │   │   ├── manifest.json               ← leaf manifest (full XMP inline, ~350 photos)
│   │   │   └── thumbnails.avif
│   │   ├── DSC_001.jpg
│   │   ├── DSC_001.xmp                     ← generated at indexing (EXIF extraction)
│   │   ├── DSC_002.jpg
│   │   ├── DSC_002.xmp
│   │   └── ...
│   └── Japan 2024/
│       ├── .ouestcharly/
│       │   ├── manifest.json
│       │   └── thumbnails.avif
│       └── ...
├── Family/
│   ├── .ouestcharly/
│   │   └── manifest.json
│   ├── Birthday 2024/
│   │   └── ...
│   └── Christmas 2023/
│       └── ...
└── Camera Roll/
    ├── .ouestcharly/
    │   ├── manifest.json                   ← leaf manifest (~2,500 photos — may be large)
    │   └── thumbnails.avif
    └── ...
```

Key characteristics:
- **No file movement**: Photos stay exactly where the user placed them. Only `.ouestcharly/` directories are created.
- **Uneven partitions**: Folder sizes reflect user behavior, not optimization targets. A `Camera Roll` folder may contain thousands of photos while `Birthday 2024` has 50. The manifest tree adapts to whatever structure exists.
- **Existing XMP preserved**: If photos already have XMP sidecars (from Lightroom, darktable, etc.), the housekeeping agent reads them rather than re-extracting from EXIF.
- **Mixed depth**: The manifest tree can have varying depth — a flat folder with 200 photos coexists with a deeply nested `Vacations/Italy 2023/Day 3/` structure. Each leaf folder with photos gets its own manifest regardless of depth.

### Ingest mode: storage-optimized structure

When OuEstCharly ingests new photos (mobile backup, bulk import), it controls placement using date-based partitioning optimized for the target backend.

#### Local filesystem and ADLS Gen2 (true hierarchical namespace)

```
/photos/                                    ← backend root
├── .ouestcharly/
│   └── manifest.json                       ← root manifest
├── 2024/
│   ├── .ouestcharly/
│   │   └── manifest.json                   ← year summary manifest
│   ├── 2024-01/
│   │   ├── .ouestcharly/
│   │   │   ├── manifest.json               ← leaf manifest (~1,000 photos)
│   │   │   └── thumbnails.avif
│   │   ├── IMG_001.jpg
│   │   ├── IMG_001.xmp
│   │   └── ...
│   ├── 2024-07/
│   │   ├── .ouestcharly/
│   │   │   ├── manifest.json
│   │   │   └── thumbnails.avif
│   │   └── ...
│   └── 2024-12/
│       └── ...
└── 2025/
    └── ...
```

Three-level hierarchy: `root → year → month`. Directory listing is cheap, and POSIX ACLs (ADLS Gen2) or filesystem permissions (local) can be set per directory.

#### S3 and GCS (flat namespace, prefix-simulated folders)

```
photos/                                     ← bucket prefix (not a real directory)
├── .ouestcharly/manifest.json              ← root manifest
├── 2024/.ouestcharly/manifest.json         ← year summary
├── 2024/2024-01/.ouestcharly/manifest.json ← leaf manifest
├── 2024/2024-01/.ouestcharly/thumbnails.avif
├── 2024/2024-01/IMG_001.jpg
├── 2024/2024-01/IMG_001.xmp
├── 2024/2024-07/.ouestcharly/manifest.json
├── 2024/2024-07/IMG_001.jpg
└── ...
```

Key considerations for object storage:
- **Shallow prefix depth**: `YYYY/YYYY-MM/` is only 2 levels of prefix. Deeper nesting (adding `/DD/`) would create 365× more prefixes with few objects each, increasing LIST call overhead.
- **Prefix-based load distribution**: S3 automatically partitions by key prefix. Date-based prefixes spread writes across partitions, avoiding throttling.
- **No directory listing**: There are no directories — `ListObjectsV2` with `Delimiter=/` simulates folder listing. Manifest-based navigation avoids listing entirely; agents read manifests by their well-known path.
- **IAM path scoping**: S3 IAM policies and GCS IAM Conditions can restrict access by prefix (e.g., `photos/2024/*` for a scoped enrichment agent).

#### OneDrive and Kdrive (API-based hierarchical)

```
/Photos/                                    ← root folder in cloud drive
├── .ouestcharly/
│   └── manifest.json
├── 2024/
│   ├── .ouestcharly/
│   │   └── manifest.json
│   ├── 2024-01/
│   │   ├── .ouestcharly/
│   │   │   ├── manifest.json
│   │   │   └── thumbnails.avif
│   │   └── ...
│   └── ...
└── ...
```

Same logical structure as local filesystem. Key difference:
- **API pagination**: Folder contents are retrieved via paginated API calls. Keeping partitions at ~1,000 photos means each folder listing fits in 1-2 API pages (typical page size: 200-1000 items).
- **Rate limiting**: OneDrive and Kdrive APIs have request rate limits. Manifest-based navigation minimizes API calls — a consumption agent reads manifest files by path, never lists directories.

### Backend comparison summary

| Backend | Namespace | Recommended depth | Manifest access | Key constraint |
|---|---|---|---|---|
| Local filesystem | True hierarchy | 3 levels (root/year/month) | File read | Directory listing is cheap |
| ADLS Gen2 | True hierarchy (HNS) | 3 levels | REST API | POSIX ACLs per directory |
| S3 | Flat (prefix-simulated) | 2 prefix levels | GET by key | Avoid deep prefixes; no directory listing |
| GCS | Flat (prefix-simulated) | 2 prefix levels | GET by key | Similar to S3; IAM Conditions for prefix scoping |
| OneDrive / Kdrive | API-based hierarchy | 3 levels | REST API | API pagination and rate limits |

### Split policy

Date-based partitioning targets ~1,000 photos per month. When a month exceeds this target:

- **Local / ADLS Gen2 / OneDrive / Kdrive**: Sub-partition by day — `2024/2024-07/2024-07-14/`. The day folder becomes a leaf manifest node. Directory creation is cheap on hierarchical backends.
- **S3 / GCS**: Sub-partition by ingestion batch — `2024/2024-07/batch-001/`. Avoids creating 31 daily prefixes when only a few days have photos. The batch threshold is configurable (default: 1,000 photos per batch).

### Partition sizing

Each leaf folder (partition) targets **~1,000 photos**. This balances manifest size, pruning granularity, and thumbnail container efficiency.

| Photos per partition | Manifest size (full XMP inline) | Thumbnail AVIF size | S3 read latency |
|---|---|---|---|
| 200 | ~200-300 KB | ~2-6 MB | ~55 ms |
| **1,000** | **~1-1.5 MB** | **~10-30 MB** | **~80 ms** |
| 5,000 | ~5-7.5 MB | ~50-150 MB | ~150 ms |

At 1,000 photos per partition, a **100,000 photo library** has ~100 leaf partitions.

### Hierarchical metadata

Photos are organized in folders (partitions). Each folder contains:

- **Photo files**: the original images (immutable)
- **Sidecar XMP files**: per-photo metadata (extracted EXIF + enrichments) stored in standard XMP format
- **Folder manifest**: contains the **full XMP metadata inline** for every photo in the partition, plus partition-level summary statistics (min/max dates, bloom filters, photo count, location bounding box)

The leaf manifest is the key enabler for efficient querying without a central database. By embedding full per-photo metadata, a consumption agent reads **one manifest file per partition** instead of scanning individual XMP sidecars. XMP sidecars remain on disk as the source of truth (for rebuilding manifests and for compatibility with external tools like Lightroom, darktable, ExifTool), but consumption agents never read them.

Manifests are structured hierarchically: a parent folder's manifest consolidates its children's manifests into **summary-only entries** (bloom filters, min/max stats, photo counts), forming a metadata tree that mirrors the storage hierarchy.

| Manifest level | Content | Typical size (100K library) |
|---|---|---|
| Root | Consolidates year summaries | ~5 KB |
| Year | Consolidates month summaries (bloom filters, min/max dates, tag unions) | ~10-20 KB |
| Leaf (month) | Full per-photo metadata inline + partition summary | ~1-1.5 MB |

### When XMP sidecars are read

XMP sidecars are read only by write-path agents, never by consumption:

| Operation | Reads XMP? | Reads manifest? |
|---|---|---|
| Consumption query (browse, search, filter) | No | Yes |
| Enrichment agent (add tags, faces) | Yes (read-modify-write) | Yes (to find unenriched photos) |
| Housekeeping manifest rebuild | Yes (recompute from sidecars) | No (rebuilding it) |
| External tool access (Lightroom, ExifTool) | Yes | No (unaware of manifests) |

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

### Decision: AVIF Grid Containers

Each folder stores its thumbnails as a single AVIF file using the **grid layout** (M x N tiles). Each tile is an independent AV1 stream that can be decoded without reading the full container.

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

### Folder Structure with Thumbnails

```
/2024/
├── .ouestcharly/
│   └── manifest.json             ← year-level summary (consolidates months)
├── 2024-07/
│   ├── .ouestcharly/
│   │   ├── manifest.json         ← leaf manifest (full XMP inline for ~1,000 photos)
│   │   └── thumbnails.avif       ← grid of all partition thumbnails
│   ├── IMG_001.jpg
│   ├── IMG_001.xmp
│   ├── IMG_002.heic
│   ├── IMG_002.xmp
│   └── ...
├── 2024-08/
│   └── ...
└── ...
```

The manifest records the grid layout (tile order mapping to photo files, grid dimensions, thumbnail resolution) so consumption agents can request specific tiles by index.

**References:**
- [AVIF specification - Alliance for Open Media](https://aomedia.org/specifications/avif/)
- [libavif - GitHub](https://github.com/AOMediaCodec/libavif)
- [AVIF browser support - Can I Use](https://caniuse.com/avif)
- [AVIF - Wikipedia](https://en.wikipedia.org/wiki/AVIF)
- [libavif-container](https://github.com/link-u/libavif-container) — AVIF container manipulation library

## Albums

Albums are implemented as **XMP tags + saved filters**, reusing the existing metadata and pruning infrastructure. No new data structure or storage mechanism is introduced.

### Smart Albums

A smart album is a saved predicate evaluated at query time:

```json
{ "name": "Vacation 2024", "type": "smart", "filter": "date:2024 AND tag:travel" }
```

Smart albums are pure consumption queries — they produce results by traversing the manifest tree with the same pruning pipeline used for any filter (manifest pruning → bloom filter → XMP scan). They require zero additional storage or enrichment.

### Manual Albums

Adding a photo to a manual album writes an `album/<name>` tag to the photo's XMP sidecar. The album is then a smart filter over that tag:

```json
{ "name": "Birthday Party", "type": "manual", "filter": "tag:album/birthday-party" }
```

- **Add to album**: Enrichment-level operation — write `album/birthday-party` tag to XMP sidecar, update folder manifest (tag list + bloom filter).
- **Remove from album**: Same operation in reverse — remove the tag, update manifest.
- **Multi-album membership**: A photo can have multiple `album/*` tags. No file duplication.

### Album Definitions Storage

Album definitions are **device-local**, not stored in the backend. They live alongside the device configuration:

```
~/.ouestcharly/
├── config.json            ← backend connection info
└── albums.json            ← album definitions (saved filters)
```

```json
{
  "albums": [
    { "name": "Vacation 2024", "type": "smart", "filter": "date:2024 AND tag:travel" },
    { "name": "Birthday Party", "type": "manual", "filter": "tag:album/birthday-party" },
    { "name": "Best of", "type": "smart", "filter": "rating >= 4" },
    { "name": "Landscapes", "type": "smart", "filter": "scene:landscape" }
  ]
}
```

**Why device-local, not in-backend:**

- Album definitions are queries, not data — they belong with the compute layer, not the storage layer.
- An album can span multiple backends (e.g., "Vacation 2024" may match photos on both local and S3). Storing the definition in one backend would be arbitrary.
- No cross-backend consistency problem — each device has its own `albums.json`, no concurrent writes from multiple backends.
- Manual album **tags** (`album/*`) still live in XMP sidecars within each backend — they are per-photo metadata and travel with the photos.

**Multi-device sync** of album definitions is an optional, separable concern. Devices can sync `albums.json` via a shared backend, a git repo, or a syncing service. This is a user choice, not an architectural requirement.

### Integration with Pruning Pipeline

Album queries use the same two-level pruning as any other filter:

1. **Parent manifest pruning**: The root and year manifests consolidate all tags including `album/*` tags in their bloom filters. A partition whose parent summary has no `album/birthday-party` in its bloom filter is skipped entirely.
2. **Leaf manifest scan**: For partitions that pass pruning, the leaf manifest contains full per-photo metadata inline — the album tag match is evaluated directly, no XMP sidecar reads needed.

This means album browsing has the same performance characteristics as any other metadata query — no special-casing needed.

## Consistency Model

Following Iceberg's approach, metadata updates use **optimistic concurrency** with **atomic commits**:

1. An agent reads the current manifest version
2. It computes the new manifest state locally
3. It writes the updated manifest atomically (e.g., write-then-rename on object storage)
4. If the manifest was modified by another agent in the meantime, the commit fails and the agent retries with the latest version

This avoids the need for distributed locks while preventing lost updates. Conflict resolution is straightforward since manifest files are derived from the underlying XMP files — any agent can recompute a manifest from scratch if needed.

## Content-Based Identity and Cross-Backend Deduplication

Each photo is identified by a **SHA-256 hash** of its original file content, computed at ingestion and stored in the XMP sidecar. This hash serves as the universal photo ID across all backends.

### Hash Computation and Storage

At ingestion, the agent computes `SHA-256(original_file_bytes)` and writes it to the XMP sidecar:

```xml
<ouestcharly:contentHash>sha256:a1b2c3d4e5f6...</ouestcharly:contentHash>
```

Since photos are immutable, the hash is stable — it never changes after ingestion, regardless of where the photo is stored.

### Deduplication Levels

Deduplication operates at three levels:

**1. Within-backend at ingestion**: When a photo is ingested into a backend, the ingestion agent checks if the content hash already exists in the backend's manifests. If a match is found, the duplicate is rejected or flagged. This prevents the same photo from being stored twice in the same backend.

**2. Within-backend housekeeping**: A housekeeping agent periodically scans the manifest tree for duplicate hashes within a single backend. This catches duplicates that slipped through ingestion (e.g., photos imported from two different source folders at different times). The agent can report, quarantine, or remove duplicates based on policy.

**3. Cross-backend at consumption time**: When a consumption agent queries across multiple backends, it merges results and deduplicates by content hash. If the same photo exists on both local storage and S3, the consumer sees it once and can prefer the lowest-latency source.

### Manifest Hash Consolidation

To enable efficient duplicate detection without scanning every XMP file, content hashes are consolidated into manifests:

- **Folder manifest**: includes the set of content hashes for all photos in the folder, plus a **bloom filter** over hashes for fast probabilistic membership tests.
- **Parent manifests**: consolidate child hash bloom filters, enabling top-down pruning. A housekeeping agent looking for duplicates can skip entire subtrees whose bloom filters show no overlap.

This follows the same three-level pruning pattern (manifest → bloom filter → XMP scan) used for all other queries.

### Example: Mobile Backup Scenario

1. User takes a photo on their phone → stored locally with hash `sha256:abc123` written to XMP sidecar
2. Mobile backup agent syncs the photo to S3 → the photo file and its XMP sidecar (containing the same hash) are uploaded
3. The S3 backend now has a photo with hash `sha256:abc123`, and the local backend has the same
4. When a consumption agent queries both backends, it sees two results with the same content hash and deduplicates — showing the photo once, preferring the local copy for display (lower latency)
5. If the user deletes the local copy, the consumption agent seamlessly falls back to the S3 copy — same hash, same photo, different backend

### Design Consequences

- **No coordination required**: Each backend independently stores hashes in XMP sidecars. Deduplication is computed at read time, not write time.
- **Hash collisions**: SHA-256 has a negligible collision probability (2⁻¹²⁸ for birthday attack). No collision handling is needed in practice.
- **Backend migration**: Moving photos between backends preserves identity — the content hash doesn't change, so cross-references, album tags, and enrichment metadata remain valid.
- **Partial replication**: Users can choose to replicate only some folders to a cloud backend. The hash-based identity ensures that duplicated photos are recognized regardless of their storage path.

## Agent Orchestration

Agents operate independently against the shared storage layer. They coordinate implicitly through the metadata:

- **Housekeeping agents** watch for changes (new photos, missing thumbnails, stale manifests) and update metadata accordingly. They can run in two modes:
  - *Thorough*: full scan and rebuild of manifests and thumbnails
  - *Lazy*: incremental updates based on detected changes (e.g., new files since last run)

- **Enrichment agents** traverse the photo stock, reading photos that lack specific metadata (faces, descriptions, scene tags) and writing enriched XMP sidecars. After enriching a batch, they trigger a manifest update for affected folders.

- **Consumption agents** serve user-facing applications. They are read-heavy and rely on manifests for fast filtering before fetching individual photos.

Agent execution is event-driven or scheduled — there is no central orchestrator. Each agent is self-contained and idempotent: it can be interrupted and restarted safely.

## Efficient Filtering and Pruning

Querying photos across a large collection uses a **two-level pruning strategy** inspired by data lakehouse query planning:

1. **Parent manifest pruning**: Read top-level manifests (root → year) which contain summary statistics and bloom filters for each child partition. If a partition's summary indicates no photos can match the filter (e.g., date range outside bounds, person absent from bloom filter), skip the entire subtree. Bloom filters enable fast probabilistic membership tests for high-cardinality fields — a bloom filter can confirm "this partition definitely does NOT contain photos of Alice" without listing every person.

2. **Leaf manifest scan**: For partitions that pass pruning, read the leaf manifest which contains **full per-photo metadata inline**. Evaluate the complete predicate against all entries and return matching photos. No per-photo file reads are needed — the manifest is self-contained.

This two-level approach (parent manifest pruning → leaf manifest scan) minimizes file reads. A consumption agent never reads individual XMP sidecars — it reads at most one manifest per partition that passes pruning.

### Query cost example

"Show me photos of Alice from July 2024" on a 100,000 photo library (100 leaf partitions × 1,000 photos):

1. Read root manifest (~5 KB) → year summaries → prune years without "Alice" in bloom filter
2. Read 2024 year manifest (~15 KB) → month summaries → bloom filter confirms "Alice" may exist in Jul and Sep → prune 10 other months
3. Read Jul 2024 leaf manifest (~1.5 MB) → scan 1,000 inline entries → return 12 matching photos
4. **Total: 3 file reads (~1.5 MB)** — instead of 100,000 XMP sidecar reads without pruning

## Security and Access Control

Security follows the **least privilege** principle from the HLR: each agent receives only the scope it needs. The approach differs between local and cloud storage.

### Agent Scopes

Each agent declares a required scope that defines what it can access:

| Agent type | Photos | XMP metadata | Manifests | Thumbnails |
|---|---|---|---|---|
| Housekeeping | read | read/write | read/write | read/write |
| Enrichment | read | read/write | read/write | - |
| Consumption (browse) | read | read | read | read |
| Ingestion | write | write | - | - |

Scopes are enforced at the storage access layer, not within agents themselves — agents never interact with raw storage credentials directly.

### Local Storage (laptop, mobile)

On local devices, security relies on the **OS-level filesystem permissions** and the device's own protection:

- **Filesystem permissions**: The photo library folder is owned by the application user. Agents run under the same user, scoped by the application layer.
- **Encryption at rest**: Delegated to the OS (FileVault on macOS, file-based encryption on Android/iOS). No application-level encryption — it would add complexity without benefit since the threat model is device theft, which OS encryption already covers.
- **Agent isolation**: On mobile, agents run within the app sandbox. On desktop, agents are threads/processes of the same application, and scope enforcement is in-process.

### Cloud Storage (S3, ADLS Gen2, GCS, OneDrive, Kdrive)

On cloud providers, security relies on **scoped credentials** issued per agent:

- **Credential vaulting**: A single master credential (e.g., S3 IAM user, OAuth refresh token) is stored securely on the user's device (OS keychain). It is never shared with agents directly.
- **Scoped tokens**: Before an agent runs, the application mints a short-lived, scoped credential:
  - *S3*: STS `AssumeRole` with an inline policy restricting to the required paths and actions (e.g., `s3:GetObject` on `photos/*` for a consumption agent)
  - *ADLS Gen2*: Azure AD service principal with RBAC role assignment scoped to the storage account/container, combined with POSIX ACLs on the hierarchical namespace for path-level control
  - *GCS*: IAM Conditions with `resource.name` prefix matching, or short-lived OAuth2 tokens via Workload Identity Federation scoped to specific buckets and prefixes
  - *OneDrive/Kdrive*: OAuth token with limited scope, or a shared link with read-only access for consumption agents
- **Token lifetime**: Scoped tokens are short-lived (minutes to hours). If an agent is interrupted, its token expires naturally.
- **Path-based scoping**: Agents can be restricted to specific folder subtrees, not just action types. For example, an enrichment agent processing `/2024/` photos gets no access to `/2025/`.

### Immutability and Write-Scoping Enforcement

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

| Backend | Photo immutability | Metadata write scoping | Enforcement level |
|---|---|---|---|
| S3 | IAM policy | IAM policy (path + action) | Provider-enforced |
| GCS | IAM Conditions | IAM Conditions (prefix + role) | Provider-enforced |
| ADLS Gen2 | POSIX ACLs | POSIX ACLs (path + principal) | Provider-enforced |
| Local filesystem | File permissions (chmod) | File permissions | OS-enforced |
| OneDrive / Kdrive | Application layer | Application layer | Application-enforced |

### Encryption in Transit

- Cloud storage: TLS enforced for all API calls (HTTPS). This is standard for S3, GCS, ADLS Gen2, OneDrive, and Kdrive.
- Local storage: Not applicable (no network transit).

### Threat Model Summary

| Threat | Local mitigation | Cloud mitigation |
|---|---|---|
| Unauthorized access | OS auth + filesystem permissions | Scoped short-lived tokens |
| Data exfiltration by rogue agent | App sandbox / in-process scope check | IAM policy restricts paths + actions |
| Credential theft | OS keychain | Master credential never leaves device; scoped tokens expire |
| Data at rest exposure | OS-level disk encryption | Provider-side encryption (SSE-S3, Azure Storage encryption, OneDrive encryption) |
| Man-in-the-middle | N/A (local) | TLS enforced |
