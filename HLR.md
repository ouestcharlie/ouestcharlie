# High Level Requirements

OuEstCharly is a decentralized photo management system designed around cheap cloud storage. The architecture is inspired by data lakehouse table formats (Iceberg, Delta).

## Key Architectural Principles
Storage-agnostic: Supports local drive on laptop or mobile, and commodity object storage (S3, Azure ADLS Gen2, GCS, OneDrive, Infomaniak Kdrive) — no vendor lock-in.

No central database: Metadata lives alongside data in a hierarchical folder structure, similar to how Iceberg/Delta store manifest files within the data lake itself. This is a strong decoupling choice — the system is self-describing.

Stateless compute (agent model): Compute is decoupled from storage. Agents are independent workers that read/write to the shared storage layer. This enables horizontal scaling and flexibility.

Immutable photos: Photo files are never modified after ingestion. Embedded EXIF data is treated as read-only input — it is extracted into sidecar metadata but never written back to the image. This eliminates corruption risk and makes photos safe to replicate or deduplicate.

Open standards and royalty-free formats: All metadata and derived artifacts use open, royalty-free formats — XMP for sidecar metadata, JSON for manifests and configuration, AVIF for thumbnails. No proprietary or patent-encumbered format dependency.

# Agent Taxonomy
Three categories of agents:

| Type | Purpose | Trigger |
|---|---|---|
| Housekeeping | Maintain metadata consistency, generate thumbnails, find duplicates | Batch/lazy |
| Data enrichment | Add semantic metadata (face recognition, scene classification, descriptions) | Batch/traversal |
| Data consumption | Query & browse photos by filters (person, date, location, etc.) | User-facing (web/mobile) |

# Ingestion Paths
Interactive: Frontend app (e.g., mobile backup)
Batch: Bulk import

# Least privilege

Agents only receive the required scope to act: read or write on metadata and pictures.