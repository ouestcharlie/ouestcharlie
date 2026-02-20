# Open Points

## 1. Video support is never mentioned

The HLR says "photo management" but modern phone libraries are 30-50% video. The design never addresses whether video is in scope, out of scope, or deferred. If it's out of scope, it should say so explicitly — otherwise every design decision (AVIF containers, EXIF extraction, thumbnail tiers, size estimates) implicitly excludes video without acknowledging it.

## 2. No deletion or trash model

Photos are "immutable after ingestion" but there's no design for what happens when a user wants to delete a photo. No trash/soft-delete mechanism, no tombstone in manifests, no propagation of deletion across backends. This is a core user operation with no coverage.

## 3. Conflict resolution for XMP sidecars is hand-waved

The consistency model covers manifest conflicts (optimistic concurrency, retry), but XMP sidecars have a harder problem: two enrichment agents writing different tags to the same sidecar concurrently. The HLD says manifests can be recomputed from XMP, but doesn't address XMP-level conflicts. This is the actual hard conflict — manifests are derived, XMP is the source of truth.

## 4. No offline / partial-connectivity story

The architecture has local + cloud backends, but there's no design for what happens when the cloud is unreachable. Can the user still browse? Are manifests cached locally? What about writes queued for sync? This is critical for mobile use cases (mobile backup is explicitly listed as a use case).

## 5. No migration or schema evolution for manifests

Manifests are JSON files with inline metadata. As the system evolves (new enrichment fields, new summary stats), there's no versioning scheme, no migration path, and no forward/backward compatibility strategy. Iceberg solves this with schema evolution — OuEstCharlie claims Iceberg inspiration but doesn't address this.

## 6. Thumbnail invalidation and update strategy is missing

What happens when a thumbnail container needs to change? A new photo is added to a partition, a photo is deleted, or thumbnails need re-encoding. Rebuilding a 120 MB `previews.avif` for one new photo seems expensive. There's no incremental update or append strategy described.

## 7. No search or query language specification

The HLD shows filter examples like `date:2024 AND tag:travel` and `rating >= 4` but never defines the query language. Bloom filters are mentioned for pruning, but what fields are indexed? What operators are supported? This is central to how consumption agents work.

## 8. AVIF grid random access claim is under-examined

The rationale says AVIF grid tiles are "independently decodable" — this is the key technical bet for thumbnail performance. But the HLD doesn't address: how does a client request tile N from a remote AVIF file? HTTP range requests require knowing byte offsets. Is the offset table stored in the manifest? In the AVIF header? Does this require downloading the full container first, defeating the purpose?

## 9. No observability or error recovery for agents

Agents are "self-contained and idempotent" and Woof "monitors progress" — but there's no design for: how does Woof know an agent is stuck? What does the agent report? Where are logs? How does a user understand why their library is missing thumbnails for a folder?

## 10. External tool interop is one-directional

The HLR says XMP enables interop with Lightroom/darktable, and index mode preserves existing XMP. But the HLD doesn't address: what happens when an external tool modifies an XMP sidecar after OuEstCharlie has indexed it? The manifest is now stale. Is there a file-watching mechanism? A periodic housekeeping scan? How is the change detected?

---

**Most critical gaps**: deletion model (#2), XMP conflict resolution (#3), and thumbnail random access mechanics (#8) — these are areas where the current design would hit real implementation blockers.
