# High Level Requirements

OuEstCharlie is a decentralized photo management system designed around cheap cloud storage. The architecture is inspired by data lakehouse table formats (Iceberg, Delta).

## Concepts

### Libraries and partitions

A photo or video **library** is a collection of media files and the associated metadata. 

A library is organized in **partitions**. A partition regroups photo files in a directory. It might have a semantic similar to an album, or

Metadata is either at the photo level, 

### Albums and tags

**Albums** and **Tags** are close concepts of adding metadata to photos to group them using filters. See also the section "Albums" here below.

### Gallery and views

The **gallery** is a display of the photos or metadata within the user interface. Several **views** are possible: grid, preview, geo map, stream...
The gallery is also able **edit information to add metadata** to the photos.

### Backends

**Backend** is the management of the persistency of photos. It may be on local, synchronized or remote drives.


## Key Architectural Principles

**Thought for the agentic world**: OuEstCharlie is "agent native", acting as a companion to MCP host providing access to rich content. It is also architected as a crowd of agent, allowing for responsibility segregation and extensibility.

**Woof as agent mediator**: Woof is the bridge-head, it is the single MCP server through which Claude Desktop orchestrates all OuEstCharlie operations. Claude Desktop provides the conversational user interface and acts as the orchestration intelligence; Woof is the security and operational boundary between Claude and the OuEstCharlie agent ecosystem. Woof owns the device-local configuration, manages credentials, controls agent lifecycle, and manages background daemons. All Claude interactions with OuEstCharlie flow through Woof's MCP interface. Claude has no direct access to agents, storage, or credentials — everything is mediated by Woof.

**Segregation of responsibility**: Each MCP agent (Woof, Wally, Whitebeard...) has a well defined scope of responsibility and the corresponding authorization following the least privilege principle.

**Privacy is preserved**: by default, OuEstCharlie and its Woof head only share part of the metadata to the MCP host. **Media selection is shared only on explicit user request**.

**Storage-agnostic**: Supports local drive on laptop or mobile, and commodity object storage (S3, Azure ADLS Gen2, GCS, OneDrive, Infomaniak Kdrive) — no vendor lock-in.

**No central database lock-in**: Metadata lives alongside data , similar to how Iceberg/Delta store manifest files within the data lake itself. This is a strong decoupling choice — the system is self-describing.

**XMP sidecar as single source of truth**: The XMP sidecar is the authoritative record for all per-photo metadata — extracted EXIF, enrichments (faces, tags, descriptions), and album membership. This ensures **metadata ownership** stays with the user: XMP is an ISO standard (ISO 16684) readable by Lightroom, Darktable, ExifTool, and any XMP-compatible tool. If the user abandons OuEstCharlie, their metadata remains fully accessible. It also enables **interoperability**: external tools can read and write the same sidecars, and OuEstCharlie honors existing XMP produced by other applications.

**Stateless compute (agent model)**: Compute is decoupled from storage. Agents are independent workers that register with Woof, declare the scope they require, and receive user-approved scoped credentials. They read/write to the shared storage layer but never hold long-lived secrets or communicate with each other directly. This enables horizontal scaling and flexibility.

**Immutable photos**: Photo files are never modified after ingestion. Embedded EXIF data is treated as read-only input — it is extracted into sidecar metadata but never written back to the image. This eliminates corruption risk and makes photos safe to replicate or deduplicate.

**No edit or delete**: OuEstCharlie does not provide photo editing, renaming, moving, or deleting operations. Photo management happens through external tools or the filesystem directly. OuEstCharlie detects external changes (additions, deletions, metadata edits) and keeps its metadata in sync.

**Least privilege**: Agents register with Woof and declare the scope they require. At deployment time, the user explicitly approves the requested grants. Once approved, Woof can trigger agent runs autonomously — issuing scoped, short-lived credentials within the approved grants without further user confirmation.

**Content-based identity**: Each photo is identified by a compact hash of its original file content, stored in the XMP sidecar at ingestion. This hash is the universal photo ID — it is stable (photos are immutable), backend-independent, and enables cross-backend deduplication without coordination.

**Open standards and royalty-free formats**: All metadata and derived artifacts use open, royalty-free formats — XMP for sidecar metadata, JSON for manifests and configuration, AVIF for thumbnails. No proprietary or patent-encumbered format dependency.

**Two operating modes (index and ingest)**: The system supports two ways of onboarding photos. **Index mode** scans an existing photo library in place — no files are moved, the user's original folder structure is preserved, and existing XMP sidecars (from Lightroom, Darktable, ExifTool, etc.) are read and honored rather than overwritten. **Ingest mode** receives new photos (mobile backup, bulk import) and places them into an optimized date-based folder structure controlled by the system.

**Date-based partitioning**: In ingest mode, photos are organized by capture date (`YYYY/YYYY-MM/`) as the primary partitioning dimension. Date is chosen because it is the most common query filter, produces naturally balanced partitions, and aligns the physical storage layout with the manifest pruning tree for efficient queries.

## Agent Taxonomy
Three categories of agents, all orchestrated by Woof:

| Type | Purpose | Trigger |
|---|---|---|
| Housekeeping | Maintain metadata consistency, generate thumbnails, find duplicates | After ingestion, on schedule, or on-demand |
| Data enrichment | Add semantic metadata (face recognition, scene classification, descriptions) | After housekeeping, on schedule, or on-demand |
| Data consumption | Query & browse photos by filters (person, date, location, etc.) | User browses/searches in UI |
| Data consumption | Memories: surface highlights like "on this day", notable trips, people milestones | User views feed in UI, or on schedule |

## Albums

Albums are virtual collections implemented as XMP tags and saved filters — no separate data structure needed.

- **Smart albums**: Saved predicates over existing metadata (e.g., "Vacation 2024" = `date in 2024 AND tag contains "travel"`). Pure read queries, zero additional storage.
- **Manual albums**: Adding a photo to an album writes an `album/<name>` tag to its XMP sidecar. The album is then a filter: `tag contains "album/<name>"`. A photo can belong to multiple albums without copying.

Album definitions (saved filters) are stored in the device configuration (`~/.ouestcharlie/albums.json`), not in the backend. This allows albums to span multiple backends and avoids cross-backend synchronization of definitions.

## Ingestion Paths
Interactive: User imports via UI (e.g., mobile backup)
Batch: bulk import

