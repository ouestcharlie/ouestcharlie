# High Level Design

## Hierarchical Metadata

Photos are organized in folders (partitions). Each folder contains:

- **Photo files**: the original images
- **Sidecar XMP files**: per-photo metadata (EXIF, tags, faces, descriptions) stored in standard XMP format
- **Folder manifest**: a consolidated metadata file summarizing all photos in the folder — think of it as a partition-level statistics file (min/max dates, list of people, location bounding box, photo count, etc.)

The folder manifest is the key enabler for efficient querying without a central database. It aggregates individual XMP metadata into a single file per folder, allowing agents to make pruning decisions by reading manifests alone, without scanning every photo.

Manifests are structured hierarchically: a parent folder's manifest consolidates its children's manifests, forming a metadata tree that mirrors the storage hierarchy.

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
