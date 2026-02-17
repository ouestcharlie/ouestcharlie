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

## Hierarchical Metadata

Photos are organized in folders (partitions). Each folder contains:

- **Photo files**: the original images (immutable)
- **Sidecar XMP files**: per-photo metadata (extracted EXIF + enrichments) stored in standard XMP format
- **Folder manifest**: a consolidated metadata file summarizing all photos in the folder — think of it as a partition-level statistics file (min/max dates, list of people, location bounding box, photo count, etc.)

The folder manifest is the key enabler for efficient querying without a central database. It aggregates individual XMP metadata into a single file per folder, allowing agents to make pruning decisions by reading manifests alone, without scanning every photo.

Manifests are structured hierarchically: a parent folder's manifest consolidates its children's manifests, forming a metadata tree that mirrors the storage hierarchy.

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
/2024/vacation/
├── .ouestcharly/
│   ├── manifest.json
│   └── thumbnails.avif      ← grid of all folder thumbnails
├── IMG_001.jpg
├── IMG_001.xmp
├── IMG_002.heic
├── IMG_002.xmp
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

Album definitions live in `/.ouestcharly/albums.json` at the backend root, alongside the root manifest:

```
/.ouestcharly/
├── root-manifest.json
└── albums.json
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

### Integration with Pruning Pipeline

Album queries use the same three-level pruning as any other filter:

1. **Manifest pruning**: The root manifest consolidates all tags including `album/*` tags. A folder whose manifest has no `album/birthday-party` tag is skipped entirely.
2. **Bloom filters**: Album tags are included in the bloom filter for the `tag` field. High-cardinality album names are handled efficiently.
3. **XMP scan**: For folders that pass pruning, XMP sidecars are scanned for the exact tag match.

This means album browsing has the same performance characteristics as any other metadata query — no special-casing needed.

## Consistency Model

Following Iceberg's approach, metadata updates use **optimistic concurrency** with **atomic commits**:

1. An agent reads the current manifest version
2. It computes the new manifest state locally
3. It writes the updated manifest atomically (e.g., write-then-rename on object storage)
4. If the manifest was modified by another agent in the meantime, the commit fails and the agent retries with the latest version

This avoids the need for distributed locks while preventing lost updates. Conflict resolution is straightforward since manifest files are derived from the underlying XMP files — any agent can recompute a manifest from scratch if needed.

## Agent Orchestration

Agents operate independently against the shared storage layer. They coordinate implicitly through the metadata:

- **Housekeeping agents** watch for changes (new photos, missing thumbnails, stale manifests) and update metadata accordingly. They can run in two modes:
  - *Thorough*: full scan and rebuild of manifests and thumbnails
  - *Lazy*: incremental updates based on detected changes (e.g., new files since last run)

- **Enrichment agents** traverse the photo stock, reading photos that lack specific metadata (faces, descriptions, scene tags) and writing enriched XMP sidecars. After enriching a batch, they trigger a manifest update for affected folders.

- **Consumption agents** serve user-facing applications. They are read-heavy and rely on manifests for fast filtering before fetching individual photos.

Agent execution is event-driven or scheduled — there is no central orchestrator. Each agent is self-contained and idempotent: it can be interrupted and restarted safely.

## Efficient Filtering and Pruning

Querying photos across a large collection uses a multi-level pruning strategy inspired by data lakehouse query planning:

1. **Manifest pruning**: Read top-level manifests first. If a folder's manifest indicates no photos match the filter (e.g., date range outside bounds, person not listed), skip the entire subtree.

2. **Bloom filters**: Manifests include bloom filters for high-cardinality fields (e.g., person names, tags). This enables fast probabilistic membership tests — a bloom filter can confirm "this folder definitely does NOT contain photos of Alice" without listing every person.

3. **XMP scan**: For folders that pass pruning, read individual XMP sidecars to evaluate the full predicate and return matching photos.

This three-level approach (manifest → bloom filter → XMP) minimizes the number of file reads required, which is critical for performance on object storage where each read has latency cost.

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
