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

## Folder Structure and Partitioning

OuEstCharlie supports **index mode** (preserve existing structure) and **ingest mode** (date-based partitioning). See [HLD_rationale.md § Folder Structure](HLD_rationale.md#folder-structure-and-partitioning) for per-backend considerations and partition sizing analysis.

### Index mode: original structure preserved

When OuEstCharlie indexes an existing photo library, it overlays `.ouestcharlie/` metadata directories without moving any files. Any folder that directly contains photos gets a `manifest.json`; a single `summary.json` at the backend root lists all indexed partitions:

```
/Photos/                                    ← user's existing root
├── .ouestcharlie/
│   └── summary.json                        ← flat index of ALL partitions (for pruning)
├── Vacations/
│   ├── Italy 2023/
│   │   ├── .ouestcharlie/
│   │   │   ├── manifest.json               ← partition manifest (full XMP inline, ~350 photos)
│   │   │   └── thumbnails.avif
│   │   ├── DSC_001.jpg
│   │   ├── DSC_001.xmp                     ← generated at indexing (EXIF extraction)
│   │   ├── DSC_002.jpg
│   │   ├── DSC_002.xmp
│   │   └── ...
│   └── Japan 2024/
│       ├── .ouestcharlie/
│       │   ├── manifest.json
│       │   └── thumbnails.avif
│       └── ...
└── Camera Roll/
    ├── .ouestcharlie/
    │   ├── manifest.json                   ← partition manifest (~2,500 photos — may be large)
    │   └── thumbnails.avif
    └── ...
```

### Ingest mode: storage-optimized structure

When OuEstCharlie ingests new photos (mobile backup, bulk import), it controls placement using date-based partitioning optimized for the target backend.

#### Local filesystem and ADLS Gen2 (true hierarchical namespace)

```
/photos/                                    ← backend root
├── .ouestcharlie/
│   └── summary.json                        ← flat index of ALL partitions
├── 2024/
│   ├── 2024-01/
│   │   ├── .ouestcharlie/
│   │   │   ├── manifest.json               ← partition manifest (~1,000 photos)
│   │   │   └── thumbnails.avif
│   │   ├── IMG_001.jpg
│   │   ├── IMG_001.xmp
│   │   └── ...
│   ├── 2024-07/
│   │   ├── .ouestcharlie/
│   │   │   ├── manifest.json
│   │   │   └── thumbnails.avif
│   │   └── ...
│   └── 2024-12/
│       └── ...
└── 2025/
    └── ...
```

Two-level structure: `root/year/month`. Intermediate year folders do not have manifests.

#### S3 and GCS (flat namespace, prefix-simulated folders)

```
photos/                                     ← bucket prefix (not a real directory)
├── .ouestcharlie/summary.json               ← flat index of ALL partitions
├── 2024/2024-01/.ouestcharlie/manifest.json ← partition manifest
├── 2024/2024-01/.ouestcharlie/thumbnails.avif
├── 2024/2024-01/IMG_001.jpg
├── 2024/2024-01/IMG_001.xmp
├── 2024/2024-07/.ouestcharlie/manifest.json
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

- **Local / ADLS Gen2 / OneDrive / Kdrive**: Sub-partition by day — `2024/2024-07/2024-07-14/`. The day folder becomes a leaf manifest node.
- **S3 / GCS**: Sub-partition by ingestion batch — `2024/2024-07/batch-001/`. The batch threshold is configurable (default: 1,000 photos per batch).

### Metadata files

Photos are organized in folders (partitions). Each folder that directly contains photos has:

- **Photo files**: the original images (immutable)
- **Sidecar XMP files**: per-photo metadata (extracted EXIF + enrichments) in standard XMP format
- **`manifest.json`**: contains the **full XMP metadata inline** for every photo in the partition, plus partition-level summary statistics (min/max dates, bloom filters, photo count, location bounding box)

The backend root also has:

- **`summary.json`**: a **flat index of all partitions** across the entire backend, each entry holding the same summary statistics as the partition's `manifest.json` summary block. Used for search pruning without reading individual manifests.

The `manifest.json` is the key enabler for efficient querying without a central database. By embedding full per-photo metadata, a consumption agent reads **one file per partition** instead of scanning individual XMP sidecars.

The `summary.json` enables two-level pruning: reading a single small file at the backend root is enough to skip entire partitions before fetching any manifest.

| Manifest level | Content | Typical size (100K library) |
|---|---|---|
| Root | Consolidates year summaries | ~5 KB |
| Year | Consolidates month summaries (bloom filters, min/max dates, tag unions) | ~10-20 KB |
| Leaf (month) | Full per-photo metadata inline + partition summary | ~1-1.5 MB |

### Schema evolution

Manifests carry a `schemaVersion` field scoped to the `ouestcharlie:` namespace — the only namespace whose semantics OuEstCharlie controls. Schema evolution rules:

- **Unknown fields are ignored and preserved**: an agent encountering an unrecognized field passes it through unchanged, both in manifests and XMP sidecars. This is standard XMP behavior, extended to manifests.
- **`schemaVersion` governs `ouestcharlie:` fields only**: it tells agents how to interpret OuEstCharlie-specific fields (e.g., a new `ouestcharlie:locationBoundingBox` added in schema v2). Fields outside the `ouestcharlie:` namespace (standard XMP, Dublin Core, EXIF) are unaffected.
- **Migration = housekeeping rebuild**: when the schema advances, Woof triggers a housekeeping agent that re-reads XMP sidecars and writes manifests in the new format. No separate migration tooling — this is already a supported operation.

### When XMP sidecars are read

XMP sidecars are read only by write-path agents, never by consumption:

| Operation | Reads XMP? | Reads manifest? |
|---|---|---|
| Consumption query (browse, search, filter) | No | Yes |
| Enrichment agent (add tags, faces) | Yes (read-modify-write) | Yes (to find unenriched photos) |
| Housekeeping manifest rebuild | Yes (recompute from sidecars) | No (rebuilding it) |
| External tool access (Lightroom, ExifTool) | Yes | No (unaware of manifests) |

### Change detection

Per the HLR, OuEstCharlie does not provide edit or delete operations — changes happen externally. The change detection mechanism covers XMP modifications, photo deletions, and photo additions. Woof detects changes through two complementary mechanisms — **triggers** for near-real-time awareness and **sweep** as a catch-all:

| Backend | Trigger | Sweep |
|---|---|---|
| Local filesystem | OS file watching (`FSEvents`, `inotify`, `ReadDirectoryChangesW`) | Compare XMP `mtime` against value stored in manifest |
| S3 | S3 Event Notifications → SNS/SQS on `PutObject` for `*.xmp` | Compare `ETag` / `LastModified` against manifest |
| GCS | Pub/Sub object change notifications | Compare `generation` number against manifest |
| ADLS Gen2 | Azure Event Grid blob events | Compare `ETag` against manifest |
| OneDrive | Microsoft Graph delta query | Delta query *is* the sweep |
| Kdrive | Webhook or polling API | API listing with `modified_at` filter |

The leaf manifest stores each XMP sidecar's **last-known version token** (mtime, ETag, or generation depending on backend). The sweep compares current tokens against stored ones — no XMP content reads needed to detect changes.

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
├── .ouestcharlie/
│   └── manifest.json             ← year-level summary (consolidates months)
├── 2024-07/
│   ├── .ouestcharlie/
│   │   ├── manifest.json         ← leaf manifest (full XMP inline for ~1,000 photos)
│   │   ├── thumbnails.avif       ← 256px grid for gallery browsing (eager)
│   │   └── previews/
│   │       ├── sha256:a1b2....jpg ← 1440px JPEG per photo (lazy, generated on demand)
│   │       └── sha256:c3d4....jpg
│   ├── IMG_001.jpg
│   ├── IMG_001.xmp
│   ├── IMG_002.heic
│   ├── IMG_002.xmp
│   └── ...
├── 2024-08/
│   └── ...
└── ...
```

The manifest records the thumbnail grid layout so consumption agents can request specific tiles by index:

```json
"thumbnailGrid": {
  "cols": 32,
  "rows": 4,
  "tileSize": 256,
  "photoOrder": ["sha256:a1b2...", "sha256:c3d4...", ...]
}
```

- **`cols` / `rows`**: grid dimensions (determined by `cols = ceil(sqrt(n))`, `rows = ceil(n / cols)`)
- **`tileSize`**: short-edge pixel size (256 for thumbnails)
- **`photoOrder`**: content hashes of photos in row-major tile order, **sorted ascending by `content_hash`**

Ordering tiles by `content_hash` rather than filename ensures stable tile indices: a photo's position only changes when its content changes, not when it is renamed or when other photos are added or removed.

### Access strategy

**Thumbnail AVIF containers** are downloaded in full and **cached on device**. At ~5-8 MB per partition, a full download is a single HTTP request. For local backends, containers are read directly from disk — no caching layer needed.

Cache invalidation: when Whitebeard rebuilds a thumbnail container, it updates the `thumbnailsHash` in the manifest. Consumption agents compare the manifest hash against their cached copy and re-fetch on mismatch.

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

Smart albums are pure consumption queries — they produce results by traversing the manifest tree with the same two-level pruning pipeline used for any filter. They require zero additional storage or enrichment.

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

### Integration with Pruning Pipeline

Album queries use the same two-level pruning as any other filter:

1. **Parent manifest pruning**: The root and year manifests consolidate all tags including `album/*` tags in their bloom filters. A partition whose parent summary has no `album/birthday-party` in its bloom filter is skipped entirely.
2. **Leaf manifest scan**: For partitions that pass pruning, the leaf manifest contains full per-photo metadata inline — the album tag match is evaluated directly, no XMP sidecar reads needed.

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

At ingestion, the agent computes `SHA-256(original_file_bytes)` and writes it to the XMP sidecar:

```xml
<ouestcharlie:contentHash>sha256:a1b2c3d4e5f6...</ouestcharlie:contentHash>
```

Since photos are immutable, the hash is stable — it never changes after ingestion, regardless of where the photo is stored.

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

Querying photos across a large collection uses a **two-level pruning strategy** inspired by data lakehouse query planning:

1. **Parent manifest pruning**: Read top-level manifests (root → year) which contain summary statistics and bloom filters for each child partition. If a partition's summary indicates no photos can match the filter (e.g., date range outside bounds, person absent from bloom filter), skip the entire subtree.

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