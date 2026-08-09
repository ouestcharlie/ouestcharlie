# High Level Design

Key design decisions:
- **Woof as agent mediator**: Woof is the single MCP server that Claude Desktop connects to. It is the security and operational boundary between Claude and the OuEstCharlie agent ecosystem. Claude Desktop provides the user interface and orchestration intelligence; Woof enforces access control, manages credentials, controls agent lifecycle, and serves gallery UI via MCP Apps. All Claude tool calls targeting OuEstCharlie flow through Woof — agents, storage, and credentials are never exposed to Claude directly.
- **Each backend is independent**: every backend has its own root manifest and its own metadata tree. There is no cross-backend unified namespace — each is a self-contained photo collection.
- **No shared catalog service**: the config file is local to the device. Two devices accessing the same S3 bucket each have their own config pointing to it. The bucket itself is the source of truth (via its root manifest), not the config.
- **Convention-based root manifest**: within each backend, the root manifest is always at a well-known path (e.g., `/.ouestcharlie/root-manifest.json`). Agents don't need the config to tell them where the manifest is — they just need the backend connection info.
- **Agent discovery**: when Woof launches an agent, it provides the agent with the backend connection info and a scoped credential. The agent connects to its assigned backend(s), reads the root manifest to understand the current state, and navigates the hierarchical manifest tree from there.

## Woof: MCP Server and Agent Mediator

Woof runs as a local MCP server on the user's device. Claude Desktop connects to it as an MCP client. From Claude's perspective, Woof exposes the entire OuEstCharlie capability surface as MCP tools. Woof is the only component Claude interacts with — agents, storage, and credentials are invisible to Claude.

```
Claude Desktop (MCP client)
  └── Woof MCP server (single entry point)
        ├── MCP tools: search, browse, index, enrich, status, configure
        ├── MCP App: gallery iframe (React/Svelte, rendered in Claude Desktop)
        ├── Local HTTP server: thumbnails and previews (served to gallery iframe)
        ├── Credential vault (OS keychain)
        ├── Configuration (~/.ouestcharlie/)
        ├── Agent lifecycle: launch, monitor, cancel, chain
        └── Background daemons: scheduled tasks, change detection, housekeeping
              ├── Whitebeard (indexing agent — MCP server, child process)
              └── [future enrichment agents]
```

### Responsibilities

**MCP interface to Claude**: Woof exposes OuEstCharlie operations as MCP tools. Claude calls these tools in response to user requests ("index my photos", "show me photos from last July", "what's the indexing status?"). Woof translates Claude's tool calls into agent invocations or direct operations.

**Gallery UI (MCP App)**: Woof serves an interactive gallery as an MCP App — an HTML/JS application rendered inside Claude Desktop's conversation via a sandboxed iframe. The gallery calls back to Woof tools for search, browsing, and navigation. This gives Claude Desktop a rich visual interface for photo browsing without requiring a separate application. See [woof/woof_LLD_rationale.md](woof/woof_LLD_rationale.md) for the MCP Apps analysis.

**Local thumbnail server**: Woof runs a local HTTP server (loopback only) that serves thumbnail AVIF containers and on-demand JPEG previews to the gallery iframe. Thumbnails never leave the device — they are not sent through Claude's API. The gallery iframe's Content Security Policy is configured to allow fetching from this local origin only.

**Agent orchestration**: Woof decides which agents run, when, and against which backends. It handles the full lifecycle:

- **Trigger**: Woof starts agents in response to Claude tool calls (e.g., Claude calls `index_backend` → Woof triggers Whitebeard, then housekeeping for thumbnails and manifest rebuild) or on a schedule (e.g., nightly enrichment pass).
- **Scope assignment**: Before launching an agent, Woof assigns it a scope — which backend(s), which folder subtrees, and which operations (read/write on photos, metadata, manifests, thumbnails).
- **Lifecycle**: Woof monitors agent progress via MCP progress notifications and handles completion, failure, and cancellation.
- **Chaining**: Woof sequences dependent agent executions (ingestion → housekeeping → enrichment). Agents never communicate with each other directly.

**Background daemon management**: Woof manages long-running background operations that must continue independently of whether Claude Desktop is open:

- **Change detection**: OS file watching (FSEvents on macOS) triggers housekeeping when external tools modify the photo library.
- **Scheduled tasks**: Nightly enrichment passes, periodic manifest consistency checks.
- **Daemon lifecycle**: Woof starts as a background process at login and manages agent child processes. Claude Desktop connects to the already-running Woof instance.

**Authentication and credential management**: Woof owns the credential vault and is the sole component that handles long-lived secrets:

- **Long-lived credentials**: Master credentials (S3 IAM keys, OAuth refresh tokens, service account keys) are stored in the OS keychain, managed exclusively by Woof. Neither Claude nor agents ever see these.
- **Scoped short-lived tokens**: When Woof launches an agent, it mints a short-lived, narrowly scoped token derived from the master credential (see Security and Access Control for per-backend mechanisms). The agent receives only this scoped token.
- **Token lifecycle**: Tokens are scoped to the agent's assigned task and expire automatically. Woof can revoke tokens early if an agent is cancelled.

**Configuration ownership**: Woof owns the device-local configuration directory (`~/.ouestcharlie/`), including:

- `config.json` — backend connection info
- `albums.json` — album definitions (saved filters)
- Credential vault (OS keychain entries)

### Woof and Agents: Control Plane vs. Data Plane

Woof is the **control plane** — it decides what happens. Agents are the **data plane** — they execute against storage. This separation means:

- Agents remain stateless and idempotent: they receive a scope and a task, execute it, and terminate.
- Woof holds all state that spans agent executions: configuration, album definitions, credentials, and orchestration history.
- Agents never communicate with each other directly. If one agent's output is another's input (e.g., ingestion → housekeeping → enrichment), Woof chains the executions.

### Root Configuration (lightweight catalog)

Iceberg requires a catalog service to locate tables. In OuEstCharlie, **Woof fills this role**: it is the central contact point that agents use to discover storage backends, obtain scoped credentials, and locate root manifests. Unlike a shared catalog service, Woof runs on each device and relies on a **local configuration file** — preserving the "no central database" principle. Claude Desktop connects to Woof; Woof connects to agents and storage. This layered topology keeps the device-local configuration entirely inside Woof's trust boundary.

The configuration is owned by Woof and lives on each device:

```
~/.ouestcharlie/config.json
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

## EXIF and the Metadata Pipeline

EXIF data embedded in images (date, GPS, camera, orientation, etc.) is treated as **read-only input** to the metadata pipeline (see HLR: immutable photos principle):

1. **Extraction**: At ingestion, a housekeeping agent reads EXIF from the image file and writes it into an XMP sidecar. This is the only time the image file is read for metadata.
2. **Enrichment**: Agents add new metadata (faces, descriptions, scene tags) to the XMP sidecar. The image file is read for pixel analysis but never written to.
3. **Consolidation**: Manifests aggregate XMP sidecars, never EXIF directly.

The XMP sidecar is the **single source of truth** for all queryable metadata (see HLR: XMP sidecar as single source of truth). Agents and consumers never need to parse EXIF from images — they only read XMP and manifests.

See [HLD_rationale.md § EXIF](HLD_rationale.md#exif-and-the-metadata-pipeline) for why this approach was chosen.

### Media types: photos and videos

A library is a collection of **media files** — photos and videos (see HLR). Both are represented by the same XMP sidecar and the same index row; a `mediaType` discriminator (`"photo"` | `"video"`, defaulting to `"photo"`) distinguishes them, so manifest, search, and deduplication code stay uniform across media types. This keeps videos metadata-browsable through the exact same conversational search path as photos — only the gallery's rendering branches on `mediaType`.

- **Extraction path differs, output does not**: photos go through EXIF extraction; videos through container/stream inspection (duration, video codec, dimensions, audio-stream presence, plus overlapping fields — capture date, GPS, make/model — mapped from container tags such as iPhone QuickTime metadata). Both populate the same sidecar shape.
- **Shared fields are reused**: a video's cover-frame dimensions populate the same `width`/`height` as a photo, and its capture date/GPS populate the same `dateTaken`/`gps`.
- **Video-only fields** added to the sidecar and index: `mediaType`, `durationSeconds`, `videoCodec`, and `hasAudio`. `mediaType`, `durationSeconds`, and `videoCodec` are searchable/filterable; they read as null on photo rows.
- **One cover image per video**: each video has exactly one derived cover frame, addressed by the video's own `contentHash` — there is no separate cover flag in the schema.
- **Playback vs. extraction are separate concerns**: extraction decodes a single cover frame server-side (broad codec support), while in-browser playback of the original stream is narrower (e.g. HEVC support is uneven across browsers). A video can therefore index and thumbnail perfectly yet be unplayable in a given browser; `videoCodec` carries the signal the UI uses to warn rather than showing a silently broken player.

### Orientation and stored dimensions

A capture's file can store its pixels rotated away from how they display: a phone held sideways writes a landscape buffer plus a rotation flag. Two fields describe this — `orientation` (EXIF values 1–8) and `width`/`height` — and the pipeline uses **two different conventions** depending on the extraction path. The invariant that holds across both: **`width`/`height` always describe the same buffer that `orientation` (or its absence) says how to display.** They must never be read independently.

- **Stored-orientation convention (standard photos).** For images read through the general EXIF path (e.g. JPEG, TIFF), `orientation` is the EXIF value verbatim and `width`/`height` are the **stored** (pre-rotation) pixel dimensions. A consumer that wants display dimensions must apply the rotation itself: for a 90°/270° orientation (values 5–8), swap the axes. Preview and thumbnail generation pass `orientation` to the image-proc step, which bakes the rotation into the derived image.
- **Upright convention (HEIC photos and all videos).** These paths decode to an already-upright buffer: the HEIC decoder applies the rotation transform and resets `orientation` to `1`, and video extraction decodes an upright cover frame and swaps `width`/`height` for a 90°/270° display-matrix rotation. Here `width`/`height` are the **display** dimensions and no further rotation is needed — for videos `orientation` is left null, since the swap has already normalized the buffer.

The consequence for consumers: **derive display dimensions from `width`/`height` together with `orientation`, never from `width`/`height` alone.** When `orientation` is null or `1`, the stored dimensions already are the display dimensions; when it is 5–8, swap the axes. Both conventions converge on this single rule, so a consumer that follows it stays correct for every media type without branching on the extraction path.

When EXIF carries no dimension tags at all (common for scans, PNG/WebP, and re-encoded JPEGs), dimensions are recovered by decoding the image header rather than left null — the fallback follows the same convention as the path that produced it.

## Folder Structure and Partitioning

OuEstCharlie supports **index mode** (preserve existing structure) and **ingest mode** (date-based partitioning). See [HLD_rationale.md § Folder Structure](HLD_rationale.md#folder-structure-and-partitioning) for per-backend considerations and partition sizing analysis.

### Index mode: original structure preserved

When OuEstCharlie indexes an existing photo library, it overlays `.ouestcharlie/` metadata directories without moving any files. The backend root `.ouestcharlie/` directory holds the LanceDB index and `summary.json`; partition-level `.ouestcharlie/` directories hold only thumbnail AVIF files:

```
/Photos/                                    ← user's existing root
├── .ouestcharlie/
│   ├── summary.json                        ← thin marker: schema version + last indexed timestamp
│   └── index.lance/                        ← LanceDB columnar index (all photos, all partitions)
├── Vacations/
│   ├── Italy 2023/
│   │   ├── .ouestcharlie/
│   │   │   └── thumbnails-Kf3QzA2_nBcR8xYvLm1P9w.avif
│   │   ├── DSC_001.jpg
│   │   ├── DSC_001.jpg.xmp                 ← generated at indexing (EXIF extraction)
│   │   ├── DSC_002.jpg
│   │   ├── DSC_002.jpg.xmp
│   │   └── ...
│   └── Japan 2024/
│       ├── .ouestcharlie/
│       │   └── thumbnails-aB1cD2eF3gH4i5jK6lM7nO.avif
│       └── ...
└── Camera Roll/
    ├── .ouestcharlie/
    │   └── thumbnails-cD2eF3gH4i5jK6lM7nO8p.avif
    └── ...
```

### Ingest mode: storage-optimized structure

When OuEstCharlie ingests new photos (mobile backup, bulk import), it controls placement using date-based partitioning optimized for the target backend.

#### Local filesystem and ADLS Gen2 (true hierarchical namespace)

```
/photos/                                    ← backend root
├── .ouestcharlie/
│   ├── summary.json                        ← thin marker: schema version + last indexed timestamp
│   └── index.lance/                        ← LanceDB columnar index (all photos, all partitions)
├── 2024/
│   ├── 2024-01/
│   │   ├── .ouestcharlie/
│   │   │   └── thumbnails-Kf3QzA2_nBcR8xYvLm1P9w.avif
│   │   ├── IMG_001.jpg
│   │   ├── IMG_001.jpg.xmp
│   │   └── ...
│   ├── 2024-07/
│   │   ├── .ouestcharlie/
│   │   │   └── thumbnails-aB1cD2eF3gH4i5jK6lM7nO.avif
│   │   └── ...
│   └── 2024-12/
│       └── ...
└── 2025/
    └── ...
```

Two-level structure: `root/year/month`. Intermediate year folders do not have manifests.

#### S3 and GCS (flat namespace, prefix-simulated folders)

```
photos/                                                          ← bucket prefix (not a real directory)
├── .ouestcharlie/summary.json                                    ← thin marker: schema version + last indexed timestamp
├── .ouestcharlie/index.lance/                                    ← LanceDB columnar index
├── 2024/2024-01/.ouestcharlie/thumbnails-Kf3QzA2_nBcR8x….avif
├── 2024/2024-01/IMG_001.jpg
├── 2024/2024-01/IMG_001.jpg.xmp
├── 2024/2024-07/.ouestcharlie/thumbnails-aB1cD2eF3gH4i5….avif
├── 2024/2024-07/IMG_001.jpg
└── ...
```

#### OneDrive and Kdrive (API-based hierarchical)

Same logical structure as local filesystem.

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

- **Local / ADLS Gen2 / OneDrive / Kdrive**: Sub-partition by day — `2024/2024-07/2024-07-14/`. The day folder becomes its own partition in the LanceDB index.
- **S3 / GCS**: Sub-partition by ingestion batch — `2024/2024-07/batch-001/`. The batch threshold is configurable (default: 1,000 photos per batch).

### Metadata files

Photos are organized in folders (partitions). Each folder that directly contains photos has:

- **Photo files**: the original images (immutable)
- **Sidecar XMP files**: per-photo metadata (extracted EXIF + enrichments) in standard XMP format

**Sidecar naming**: OuEstCharlie always writes new sidecars with the photo's extension kept in the filename (`IMG_001.cr3` → `IMG_001.cr3.xmp`), matching Darktable, digiKam, and Immich's preferred convention, and avoiding the collision risk where two photos sharing a stem but differing only in extension (`photo.cr3`, `photo.jpg`) would otherwise resolve to the same sidecar. When reading, OuEstCharlie looks for the full-extension sidecar first and falls back to the extension-stripped form (`IMG_001.xmp`, as written by Lightroom) if that's what's present — this is not a hard rename, so libraries with existing stripped-extension sidecars keep working, and edits to those sidecars are written back in place rather than forking a duplicate under the new name.

The backend metadata directory (`.ouestcharlie/`) at the backend root holds:

- **`index.lance/`**: a LanceDB columnar store containing **all photos across all partitions** in a single table. Each row stores full per-photo metadata (date, GPS, rating, tags, camera, thumbnail tile location). Consumption agents execute a **single SQL query** against this table to filter across the entire library without per-partition file reads.
- **`summary.json`**: a **thin marker file** — just `{schemaVersion, lastIndexedAt}`. Written once per full indexing session (not per partition). Agents verify the schema version falls within the supported compatibility window before opening the index (see Schema evolution); a version outside the window prompts a full re-index or a software upgrade.

| Metadata file | Content | Typical size (100K library) |
|---|---|---|
| `index.lance/` | All per-photo metadata in columnar format (one table, all partitions) | ~10–30 MB |
| `summary.json` | Schema version + last indexed timestamp | <1 KB |

### Schema evolution

`summary.json` carries a `schemaVersion` field that agents check before opening the index. Current version: **4** (LanceDB columnar index with media-type/video columns). Schema evolution rules:

- **Unknown fields are ignored and preserved**: an agent encountering an unrecognized field in `summary.json` or XMP sidecars passes it through unchanged.
- **`schemaVersion` governs the index format**: version 4 means the primary media store is the LanceDB table at `.ouestcharlie/index.lance/`. A future version may change the table schema or storage format.
- **Compatibility window `[LOWEST_SCHEMA_VERSION, SCHEMA_VERSION]`**: the software also declares the oldest schema version it can still read *in place*. An index whose version falls in this window is used as-is: additive-only changes (e.g. new nullable LanceDB columns) are applied by an in-place column migration on open, with no full rebuild. Newly introduced columns read as null on rows written by the older version, and the writer's defaults apply going forward. As of version 4 the window is **[3, 4]** — a version-3 (photo-only) index is read directly and upgraded to version 4 additively.
- **Migration outside the window**:
  - *Newer than supported* (`> SCHEMA_VERSION`): agents refuse to open the index and prompt a software upgrade.
  - *Older than the window* (`< LOWEST_SCHEMA_VERSION`): the change is not additive-safe, so a full re-index (Whitebeard) rebuilds the LanceDB table in the new format. No separate migration tooling — this is already a supported operation. A scoped (partition-subset) index, which cannot rebuild the whole library, refuses instead and asks for a full re-index.

### Runtime Summaries

Rather than reading a precomputed statistics file, consumption agents compute aggregate statistics (photo count, date/rating/width/height ranges, GPS bounding box) on demand with a single DuckDB aggregation over the same LanceDB-query result a photo search would use — scoped by the same filter predicate syntax as a search (an empty predicate summarizes the whole library). This lets the host agent narrow a summary to a directory subtree, a date range, or any other filter before deciding whether to run a full (potentially large) search, without ever materializing or storing a global statistics blob.

### When XMP sidecars are read

XMP sidecars are read only by write-path agents, never by consumption:

| Operation | Reads XMP? | Reads index? |
|---|---|---|
| Consumption query (browse, search, filter) | No | Yes (LanceDB SQL query) |
| Enrichment agent (add tags, faces) | Yes (read-modify-write) | Yes (to find unenriched photos) |
| Housekeeping / re-index | Yes (recompute from sidecars) | No (rebuilding it) |
| External tool access (Lightroom, ExifTool) | Yes | No (unaware of OuEstCharlie index) |

### Change detection (partial implementation)

Per the HLR, OuEstCharlie does not provide edit or delete operations — changes happen externally. The change detection mechanism covers XMP modifications, photo deletions, and photo additions. Woof detects changes through two complementary mechanisms — **triggers** for near-real-time awareness and **sweep** as a catch-all:

| Backend | Trigger | Sweep |
|---|---|---|
| Local filesystem | OS file watching (`FSEvents`, `inotify`, `ReadDirectoryChangesW`) | Compare XMP `mtime` against value stored in manifest |
| S3 | S3 Event Notifications → SNS/SQS on `PutObject` for `*.xmp` | Compare `ETag` / `LastModified` against manifest |
| GCS | Pub/Sub object change notifications | Compare `generation` number against manifest |
| ADLS Gen2 | Azure Event Grid blob events | Compare `ETag` against manifest |
| OneDrive | Microsoft Graph delta query | Delta query *is* the sweep |
| Kdrive | Webhook or polling API | API listing with `modified_at` filter |

The LanceDB index stores each photo's **last-known XMP version token** (`xmp_version_token` column — mtime, ETag, or generation depending on backend). The sweep compares current tokens against stored values — no XMP content reads needed to detect changes.

**Debouncing**: Changes are not acted on individually. Woof accumulates dirty partitions and schedules housekeeping after a quiet period (default: 10 minutes since the last detected change in a partition). This avoids thrashing when an external tool writes many sidecars in sequence (e.g., Lightroom batch-editing 500 photos).

The flow:
1. Trigger or sweep detects a change (XMP version token mismatch, missing photo file, or new photo file) → partition marked dirty
2. Woof waits for the debounce window to expire (no new changes in the partition for 10 minutes)
3. Woof schedules a housekeeping agent on the dirty partition
4. Housekeeping reconciles the partition: re-reads changed XMP sidecars, removes entries for deleted photos, cleans up orphaned XMP sidecars (sidecar exists but photo file is gone), generates XMP for new photos (EXIF extraction), and rebuilds the manifest and thumbnail/preview containers

## Thumbnail Storage

Thumbnails use a **two-tier** system:

| Tier | File | Resolution | Generation | Purpose | Size per 1,000 photos |
|---|---|---|---|---|---|
| Grid thumbnail | `thumbnails.avif` | 256px (short edge, center-crop) | Eager — at index time | Gallery grid browsing | ~5-8 MB |
| Preview | `{content_hash}.jpg` | 1440px (long edge, aspect-ratio preserved) | Lazy — on first view | Single-photo panel | ~0.5-1 MB each |

The thumbnail tier is an AVIF grid container (M × N tiles, each tile independently decodable), generated by Whitebeard at indexing time. The preview tier is **individual JPEG files per photo**, generated on-demand by Wally's HTTP server when first requested by the gallery and cached on disk.

See [HLD_rationale.md § Thumbnail Storage](HLD_rationale.md#thumbnail-storage) for the format analysis, industry standards research, size estimates math, and alternatives comparison.

```
/2024/
├── 2024-07/
│   ├── .ouestcharlie/
│   │   ├── thumbnails-Kf3QzA2_nBcR8xYvLm1P9w.avif  ← 256px chunk (≤64 photos, max 8×8)
│   │   ├── thumbnails-aB1cD2eF3gH4i5jK6lM7nO.avif  ← next chunk if partition > 64 photos
│   │   └── previews/
│   │       ├── Kf3QzA2_nBcR8x....jpg ← 1440px JPEG per photo (lazy, generated on demand)
│   │       └── aB1cD2eF3gH4i5....jpg
│   ├── IMG_001.jpg
│   ├── IMG_001.jpg.xmp
│   ├── IMG_002.heic
│   ├── IMG_002.heic.xmp
│   └── ...
├── 2024-08/
│   └── ...
└── ...
```

Thumbnail chunk location is stored in the LanceDB index as two flat columns per photo:

- **`thumbnail_avif_hash`**: 22-char BLAKE3 of the AVIF file content. The backend path is reconstructed as `{partition}/.ouestcharlie/thumbnails-{avif_hash}.avif`.
- **`thumbnail_tile_index`**: row-major position of this photo inside the AVIF grid (0-based).

Photos are sorted by `content_hash` and split into chunks of at most 64 before encoding. This sort order ensures stable tile indices: a photo's position only changes when its content changes, not when it is renamed or when other photos are added or removed.

### Access strategy

**Thumbnail AVIF chunks** are downloaded in full and **cached on device**. At ≤64 photos per file, each chunk is small enough for a fast single HTTP request. For local backends, chunks are read directly from disk — no caching layer needed.

Cache invalidation: when Whitebeard rebuilds thumbnails, the AVIF filename changes (content-addressed). Consumption agents detect the change via `avifHash` in the manifest and re-fetch stale chunks.

**Preview JPEGs** are generated lazily: on first request, Wally decodes the original photo, resizes it to 1440px on the long edge (preserving aspect ratio), and caches the result at `{partition}/.ouestcharlie/previews/{content_hash}.jpg`. Subsequent requests are served directly from disk. The gallery shows the (blurred) thumbnail tile immediately and fades in the JPEG once loaded — no perceived wait on cache hits.

### Rebuild strategy

When a partition changes (photo added, deleted, or re-encoded), the thumbnail AVIF container is **rebuilt in full** — AVIF grid containers do not support incremental tile append. The housekeeping agent maintains a **tile cache** of individual encoded AV1 bitstreams, so only new or changed tiles are re-encoded; unchanged tiles are reused byte-for-byte. The rebuild reduces to reassembling the container from cached tiles.

Stale preview JPEGs (for photos that changed content) are deleted during housekeeping so they are regenerated on next request.

See [HLD_rationale.md § Thumbnail Rebuild Strategy](HLD_rationale.md#thumbnail-rebuild-strategy) for why full rebuild is acceptable and alternatives analysis.

## Albums

Albums are implemented as XMP tags + saved filters (see HLR: Albums).

### Smart Albums

A smart album is a saved predicate evaluated at query time:

```json
{ "name": "Vacation 2024", "type": "smart", "filter": "date:2024 AND tag:travel" }
```

Smart albums are pure consumption queries — they produce results by executing a LanceDB SQL query with the same predicate evaluation used for any filter. They require zero additional storage or enrichment.

### Manual Albums

Adding a photo to a manual album writes an `album/<name>` tag to the photo's XMP sidecar. The album is then a smart filter over that tag:

```json
{ "name": "Birthday Party", "type": "manual", "filter": "tag:album/birthday-party" }
```

- **Add to album**: Enrichment-level operation — write `album/birthday-party` tag to XMP sidecar, update folder manifest (tag list + bloom filter).
- **Remove from album**: Same operation in reverse — remove the tag, update manifest.
- **Multi-album membership**: A photo can have multiple `album/*` tags. No file duplication.

### Album Definitions Storage

Album definitions are **device-local**, not stored in the backend. They are managed by Woof alongside the rest of the device configuration:

```
~/.ouestcharlie/
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

See [HLD_rationale.md § Albums](HLD_rationale.md#albums) for why definitions are device-local and multi-device sync options.

### Integration with the Query Engine

Album queries execute the same LanceDB SQL query as any other filter. A manual album adds a tag condition: `array_has(tags, 'album/birthday-party')`. The columnar store evaluates tag array membership directly — no per-partition traversal or bloom filter pass is needed.

## Consistency Model

Following Iceberg's approach, metadata updates use **optimistic concurrency** with **atomic commits**. This applies to both XMP sidecars (source of truth) and manifests (derived).

### XMP sidecar concurrency

XMP sidecars carry a version counter that agents use for optimistic concurrency:

```xml
<ouestcharlie:metadataVersion>3</ouestcharlie:metadataVersion>
```

1. An agent reads the XMP sidecar and notes its `metadataVersion` (and/or the backend-native version token — see below)
2. It applies its changes locally (e.g., adds face tags)
3. It writes the updated sidecar with `metadataVersion` incremented, using a **conditional write** to ensure no other agent modified the file in the meantime
4. If the condition fails (another agent wrote first), the agent re-reads the latest sidecar, merges its changes, and retries

Conditional write mechanisms per backend:

| Backend | Condition mechanism |
|---|---|
| S3 | `PutObject` with `If-None-Match` on ETag (conditional writes, Aug 2024) |
| GCS | `generation` match on upload |
| ADLS Gen2 | `If-Match` on ETag |
| Local filesystem | Write to temp file, rename — atomic on POSIX; version check before rename |
| OneDrive / Kdrive | Application-level version check before PUT |

Since agents write **non-overlapping fields** (a face-detection agent writes `ouestcharlie:faces`, a scene-classification agent writes `ouestcharlie:scene`), most retries are simple merges rather than true conflicts.

### Manifest concurrency

Manifests use the same optimistic concurrency pattern:

1. An agent reads the current manifest version
2. It computes the new manifest state locally
3. It writes the updated manifest atomically (e.g., write-then-rename on object storage)
4. If the manifest was modified by another agent in the meantime, the commit fails and the agent retries with the latest version

Conflict resolution for manifests is straightforward since they are derived from the underlying XMP files — any agent can recompute a manifest from scratch if needed.

### Thumbnail and preview concurrency

Thumbnail and preview AVIF containers use the same optimistic concurrency as manifests — they are derived artifacts that can be rebuilt from source photos. The housekeeping agent writes the container atomically (write-then-rename or conditional PUT), and the manifest records the container's content hash. If two agents attempt to rebuild the same container concurrently, the same retry logic applies: the losing write detects the version mismatch and re-evaluates whether a rebuild is still needed.

## Content-Based Identity and Cross-Backend Deduplication

This section details the deduplication mechanisms enabled by the content-based identity principle (see HLR: content-based identity).

### Hash Computation and Storage

At ingestion, the agent computes a BLAKE3 hash of the original file bytes, truncated to 128 bits and base64url-encoded (no padding), yielding a 22-character string. This is written to the XMP sidecar:

```xml
<ouestcharlie:contentHash>Kf3QzA2_nBcR8xYvLm1P9w</ouestcharlie:contentHash>
```

128 bits gives a collision probability below 10⁻²⁸ for a library of 1 million photos — negligible.

Since photos are immutable, the hash is stable — it never changes after ingestion, regardless of where the photo is stored.

**Video identity.** Videos cannot use a full-file byte hash: they can be GB-scale on cloud-mounted drives, so hashing every byte on each indexing pass is prohibitive. Instead a video's `contentHash` is a BLAKE3 (same 22-character truncated base64url output) over two **bounded-cost** inputs that are already read during extraction:

1. **The container header** — for MP4/MOV, the `moov` atom (stream metadata plus the sample tables that fingerprint the exact edit/encode). This is a bounded read (located by scanning top-level atoms and following their sizes, so it works even when `moov` sits after `mdat`); the GB-scale `mdat` payload is skipped entirely. The header read is capped (16 MB) — on the rare overflow the capped prefix is hashed, keeping the result deterministic.
2. **The decoded cover-frame pixels** — the single representative frame already extracted for the thumbnail, tying identity to visible content.

Hashing both makes an accidental collision require matching *both* the full sample-table structure and the cover-frame pixels, so a video `contentHash` is treated as a real identity (not a heuristic) and flows through the same deduplication levels below as a photo hash. Re-encoding a video changes both inputs and therefore yields a new identity — the same behavior as photos, where any re-encode changes `contentHash`.

### Deduplication Levels

Deduplication operates at three levels:

**1. Within-backend at ingestion**: When a photo is ingested into a backend, the ingestion agent checks if the content hash already exists in the backend's manifests. If a match is found, the duplicate is rejected or flagged.

**2. Within-backend housekeeping**: A housekeeping agent periodically scans the manifest tree for duplicate hashes within a single backend. This catches duplicates that slipped through ingestion (e.g., photos imported from two different source folders at different times).

**3. Cross-backend at consumption time**: When a consumption agent queries across multiple backends, it merges results and deduplicates by content hash. If the same photo exists on both local storage and S3, the consumer sees it once and can prefer the lowest-latency source.

### Manifest Hash Consolidation

To enable efficient duplicate detection without scanning every XMP file, content hashes are consolidated into manifests:

- **Folder manifest**: includes the set of content hashes for all photos in the folder, plus a **bloom filter** over hashes for fast probabilistic membership tests.
- **Parent manifests**: consolidate child hash bloom filters, enabling top-down pruning.

See [HLD_rationale.md § Content-Based Identity](HLD_rationale.md#content-based-identity-and-deduplication) for an illustrative mobile backup scenario and design consequences.

## Agent Orchestration

Woof orchestrates all agent execution. Agents do not self-schedule or communicate with each other — Woof triggers them, assigns their scope, and chains dependent executions.

### Agent types

- **Housekeeping agents** maintain metadata consistency — generate thumbnails, rebuild manifests, find duplicates. They can run in two modes:
  - *Thorough*: full scan and rebuild of manifests and thumbnails
  - *Lazy*: incremental updates based on detected changes (e.g., new files since last run)

- **Enrichment agents** traverse the photo stock, reading photos that lack specific metadata (faces, descriptions, scene tags) and writing enriched XMP sidecars. After enriching a batch, Woof triggers a housekeeping agent to update manifests for affected folders.

- **Consumption agents** serve Woof's UI layer. They are read-heavy and rely on manifests for fast filtering before fetching individual photos. Woof invokes them in response to user queries.

### Execution model

Each agent is self-contained and idempotent: it receives a scoped token and a task from Woof, executes it, and terminates. It can be interrupted and restarted safely. Woof chains dependent agents — for example, after ingestion completes, Woof triggers housekeeping (thumbnails + manifest rebuild), then enrichment.

### Agent-to-controller communication

Agents communicate with Woof using the **Model Context Protocol (MCP)**. Woof is the MCP client; each agent is an MCP server that exposes its capabilities as MCP tools.

**Transport**: stdio for agents running as child processes (default). Streamable HTTP for agents running as separate processes or containers.

**Protocol mapping**:

| Concern | MCP mechanism |
|---|---|
| Agent registration | `initialize` handshake — agent declares its tools and capabilities |
| Capability declaration | MCP tool definitions — each agent exposes typed tools (e.g., `rebuild_partition`, `enrich_faces`) |
| Progress reporting | `notifications/progress` on the tool call's progress token |
| Completion | Tool call result — returns a structured summary |
| Failure | Tool call error — returns error detail with category, affected photo, and operation |
| Non-fatal per-photo errors | `notifications/message` (log level: error) — agent logs per-photo errors without aborting |
| Cancellation | `notifications/cancelled` — Woof cancels a running tool call; agent terminates gracefully |

Woof detects stuck agents via progress token timeout (default: 5 minutes without progress notification) and cancels the tool call.

See [controller_api.json](controller_api.json) for MCP tool definitions (per-agent `tools/list` responses with JSON Schema input/output).

For detailed Woof requirements, design, and rationale, see:
- [woof/woof_LLR.md](woof/woof_LLR.md) — low-level requirements
- [woof/woof_LLD.md](woof/woof_LLD.md) — low-level design
- [HLD_rationale.md § Agent Communication](HLD_rationale.md#agent-communication-why-mcp) — rationale for the MCP approach

## Efficient Filtering and Pruning

Querying photos uses a **single SQL query** against the LanceDB columnar index at `.ouestcharlie/index.lance/`. All filter predicates (date range, rating, GPS bounding box, tags, camera make/model) are expressed as a SQL WHERE clause evaluated by LanceDB's query engine in one pass.

Before executing the query, consumption agents read the thin `summary.json` marker to verify `schemaVersion` falls within the supported compatibility window (see Schema evolution). A version outside the window returns an error prompting a full re-index (too old) or a software upgrade (too new).

### Query cost example

"Show me photos from July 2024 with rating ≥ 4" on a 100,000 photo library:

1. Read `summary.json` (<1 KB) → verify `schemaVersion` is in the supported window (`3 ≤ v ≤ 4`)
2. Execute SQL: `date_taken >= TIMESTAMP '2024-07-01 00:00:00' AND date_taken <= TIMESTAMP '2024-07-31 23:59:59' AND rating >= 4`
3. **Total: 1 JSON read + 1 SQL query** — LanceDB's columnar predicate pushdown reads only the date and rating columns

The same pattern applies to a runtime summary request ("how many photos, and what date range, in this directory?"): 1 JSON read for the schema check + 1 DuckDB aggregation over the LanceDB-filtered rows for that predicate — never a precomputed file to read or keep in sync.

A consumption agent never reads individual XMP sidecars or per-partition manifest files.

## Security and Access Control

Security follows the **least privilege** principle from the HLR: each agent receives only the scope it needs. The approach differs between local and cloud storage.

### Agent Scopes

Agents register with Woof and declare the scope they require. Woof presents the requested grants to the user for explicit approval before issuing credentials:

| Agent type | Photos | XMP metadata | Manifests | Thumbnails |
|---|---|---|---|---|
| Housekeeping | read | read/write | read/write | read/write |
| Enrichment | read | read/write | read/write | - |
| Consumption (browse) | read | read | read | read |
| Ingestion | write | write | - | - |

Scopes are enforced at the storage access layer, not within agents themselves — agents never interact with raw storage credentials directly.

### Local Storage (laptop, mobile)

On local devices, security relies on the **OS-level filesystem permissions** and the device's own protection:

- **Filesystem permissions**: The photo library folder is owned by the application user. Agents run under the same user, scoped by Woof.
- **Encryption at rest**: Delegated to the OS (FileVault on macOS, file-based encryption on Android/iOS).
- **Agent isolation**: On mobile, agents run within the app sandbox. On desktop, agents are threads/processes managed by Woof, and scope enforcement is in-process.

### Cloud Storage (S3, ADLS Gen2, GCS, OneDrive, Kdrive)

On cloud providers, security relies on **scoped credentials** issued per agent:

- **Credential vaulting**: Master credentials (e.g., S3 IAM user, OAuth refresh token) are stored in the OS keychain, managed exclusively by Woof. They are never shared with agents directly.
- **Scoped tokens**: Before launching an agent, Woof mints a short-lived, scoped credential matching the user-approved grants:
  - *S3*: STS `AssumeRole` with an inline policy restricting to the required paths and actions (e.g., `s3:GetObject` on `photos/*` for a consumption agent)
  - *ADLS Gen2*: Azure AD service principal with RBAC role assignment scoped to the storage account/container, combined with POSIX ACLs on the hierarchical namespace for path-level control
  - *GCS*: IAM Conditions with `resource.name` prefix matching, or short-lived OAuth2 tokens via Workload Identity Federation scoped to specific buckets and prefixes
  - *OneDrive/Kdrive*: OAuth token with limited scope, or a shared link with read-only access for consumption agents
- **Token lifetime**: Scoped tokens are short-lived (minutes to hours). If an agent is interrupted, its token expires naturally.
- **Path-based scoping**: Agents can be restricted to specific folder subtrees, not just action types.

### Immutability Enforcement Summary

| Backend | Photo immutability | Metadata write scoping | Enforcement level |
|---|---|---|---|
| S3 | IAM policy | IAM policy (path + action) | Provider-enforced |
| GCS | IAM Conditions | IAM Conditions (prefix + role) | Provider-enforced |
| ADLS Gen2 | POSIX ACLs | POSIX ACLs (path + principal) | Provider-enforced |
| Local filesystem | File permissions (chmod) | File permissions | OS-enforced |
| OneDrive / Kdrive | Application layer | Application layer | Application-enforced |

### Encryption in Transit

- Cloud storage: TLS enforced for all API calls (HTTPS).
- Local storage: Not applicable (no network transit).

See [HLD_rationale.md § Security](HLD_rationale.md#security-and-access-control) for detailed per-backend enforcement mechanisms and threat model analysis.