# Feasibility: Replace Manifest Index with LanceDB

## Context

OuEstCharlie's current index is a two-level JSON hierarchy:
- **`summary.json`** — flat list of all partitions with bloom filters, min/max stats, GPS bboxes
- **`manifest.json`** per partition — full per-photo metadata (~1,000 photos each, ~1.5 MB)

These files are written by Whitebeard (housekeeping) and queried by Wally (search).
Custom pruning logic (bloom filters, range checks) is implemented in `fields.py` / `schema.py`.

The question: could LanceDB replace this custom index with a general-purpose columnar store?

---

## TL;DR: Yes — and it's a clean fit

LanceDB is just a directory of Arrow files on disk. It would live at `.ouestcharlie/index.lance/`
inside each backend root, keeping the "no central database" constraint intact. Each backend
stays self-contained.

---

## Mapping the 3-Step Workflow to the Codebase

| User step | Current code | LanceDB equivalent |
|---|---|---|
| **1. Extract EXIF → XMP** | `xmp.py` + Whitebeard | Unchanged |
| **2. XMP → list of dicts** | `schema.py: PhotoEntry.from_sidecar()` → `serialize_leaf()` | Same `PhotoEntry` objects, converted to `pa.Table` via PyArrow |
| **3. Insert into columnar store** | `manifest.py: ManifestStore.write_leaf()` | `lancedb.upsert()` on `content_hash` |

Step 2 already exists — the `PhotoEntry.from_sidecar()` / `serialize_leaf()` round-trip produces
the exact dicts that would map to LanceDB rows. No new transformation logic needed.

---

## Proposed Schema

```python
import pyarrow as pa

PHOTO_SCHEMA = pa.schema([
    pa.field("content_hash",      pa.string()),              # upsert key
    pa.field("filename",          pa.string()),
    pa.field("partition",         pa.string()),              # "2024/2024-07"
    pa.field("date_taken",        pa.timestamp("us"), nullable=True),  # naive local time (EXIF wall-clock)
    pa.field("utc_offset_minutes", pa.int16(),        nullable=True),  # e.g. +120 for +02:00; NULL when EXIF has no offset
    pa.field("rating",            pa.int32(),  nullable=True),
    pa.field("width",             pa.int32(),  nullable=True),
    pa.field("height",            pa.int32(),  nullable=True),
    pa.field("orientation",       pa.int32(),  nullable=True),
    pa.field("make",              pa.string(), nullable=True),
    pa.field("model",             pa.string(), nullable=True),
    pa.field("tags",              pa.list_(pa.string())),
    pa.field("gps_lat",           pa.float64(), nullable=True),
    pa.field("gps_lon",           pa.float64(), nullable=True),
    pa.field("metadata_version",  pa.int64()),
    pa.field("xmp_version_token", pa.string()),              # backend-native token as str
    # Thumbnail location within the AVIF grid chunk for this photo
    pa.field("thumbnail", pa.struct([
        pa.field("avif_hash",  pa.string()),                 # identifies the .avif file
        pa.field("col",        pa.int8()),                   # 0-based column in the grid
        pa.field("row",        pa.int8()),                   # 0-based row in the grid
        pa.field("tile_size",  pa.int16()),                  # tile short-edge in px (256)
    ]), nullable=True),                                      # NULL until thumbnail is built
    # Future: vector column for semantic/embedding search
    # pa.field("vector",          pa.list_(pa.float32(), 512), nullable=True),
])
```

---

## Partition Summary for LLM Context

In the current system, `summary.json` is a pre-computed file that gives an overview of the library
(date ranges, bloom filters, GPS bboxes per partition). With LanceDB, this becomes a **live query**
— always accurate, no staleness, richer than what bloom filters can express.

### Primary summary (per-partition stats)

```sql
SELECT
    partition,
    COUNT(*)           AS photo_count,
    MIN(date_taken)    AS date_min,
    MAX(date_taken)    AS date_max,
    MIN(rating)        AS rating_min,
    MAX(rating)        AS rating_max,
    MIN(width)         AS width_min,
    MAX(width)         AS width_max,
    MIN(gps_lat)       AS gps_lat_min,
    MAX(gps_lat)       AS gps_lat_max,
    MIN(gps_lon)       AS gps_lon_min,
    MAX(gps_lon)       AS gps_lon_max
FROM photos
GROUP BY partition
ORDER BY partition
```

### Tag inventory (replaces bloom filters with exact counts)

```sql
SELECT partition, tag, COUNT(*) AS count
FROM photos, UNNEST(tags) AS t(tag)
GROUP BY partition, tag
ORDER BY partition, count DESC
```

The Woof MCP tool `get_library_overview()` runs both queries and returns compact JSON or
markdown to the LLM. The LLM uses it to plan which partitions to filter in follow-up queries.

| `summary.json` | LanceDB GROUP BY |
|---|---|
| Written at housekeeping time — can be stale | Always current |
| Bloom filter: probabilistic ("might contain") | Exact distinct tags + counts per partition |
| Fixed fields chosen at write time | LLM can request any aggregation |
| Custom serialization/deserialization | Plain SQL → dict → LLM context |

---

## What Gets Replaced / Simplified

| Current component | Replaced by |
|---|---|
| `summary.json` + bloom filters | LanceDB aggregation query at query time |
| `manifest.json` per partition | Rows in the LanceDB table (one row per photo) |
| `ManifestStore` class (`manifest.py`) | `LanceIndex` wrapper around `lancedb.Table` |
| Custom bloom filter logic (`schema.py`) | LanceDB scalar index on `tags` / `date_taken` |
| Two-level pruning pipeline | Single LanceDB SQL/Arrow filter |
| `deserialize_leaf` / `serialize_leaf` | PyArrow record batch construction from `PhotoEntry` |
| `VersionConflictError` retry loop | LanceDB MVCC (built-in, per-transaction) |

---

## What Stays Unchanged

- XMP sidecars as the **source of truth** — never replaced
- EXIF extraction pipeline (Step 1)
- `PhotoEntry` dataclass and `PHOTO_FIELDS` in `fields.py`
- Agent architecture (Whitebeard for housekeeping, Wally for search)
- Content hash identity (`content_hash` becomes the LanceDB upsert key)
- Thumbnail/preview system (AVIF grid, JPEG previews)
- Backend protocol (`LocalBackend`, `CloudMountedBackend`, future S3/GCS)

---

## Trade-offs

### Advantages
- **Simpler query logic**: date range, rating filter, GPS bbox — all SQL predicates, no custom bloom filter code
- **No partition boundary** in queries: a single `WHERE date_taken BETWEEN ...` spans all months
- **Built-in upsert**: `tbl.upsert(data, on="content_hash")` replaces the optimistic-concurrency loop
- **Vector search ready**: add a `vector` column later for semantic/embedding queries with no schema migration pain
- **ANN indices**: LanceDB builds IVF-PQ / HNSW indices — sub-linear search on 100k+ rows
- **Arrow-native**: data stays in columnar format through the whole pipeline (no JSON parse/serialize overhead at query time)

### Disadvantages
- **New dependency**: `lancedb` + `pyarrow` (~50 MB wheel); rawpy already adds weight, but still notable for cross-platform builds
- **Cloud backend story**: LanceDB supports S3/GCS/Azure natively, but via its own abstraction — this bypasses the existing `Backend` protocol and adds a second storage abstraction layer. Needs careful design for V2 cloud backends.
- **Not human-readable**: `manifest.json` can be inspected/debugged with a text editor; `.lance` files cannot
- **Concurrent writes**: LanceDB MVCC works well for single-writer, but multi-agent concurrent upserts need evaluation (Lance uses optimistic transactions, similar to what we have now)
- **Blob storage compatibility**: some FUSE mounts (kDrive, OneDrive) may not handle the random-access patterns Lance uses for its index files — needs testing with `CloudMountedBackend`

---

## Architecture Compatibility Check

| Constraint | Compatible? | Notes |
|---|---|---|
| No central database | ✅ | LanceDB dataset lives at `.ouestcharlie/index.lance/` inside each backend root |
| Agents stateless | ✅ | Agents open the table, write/query, close — no persistent connection |
| Cross-platform | ✅ | LanceDB has wheels for macOS, Linux, Windows |
| Storage-agnostic | ⚠️ | Works for local/cloud-mount; for S3/GCS, LanceDB has its own cloud connector (different from our `Backend` protocol) |
| XMP as source of truth | ✅ | LanceDB is a derived index, rebuilt from XMP by housekeeping agent |

---

## Files That Would Change (if implemented)

| File | Change |
|---|---|
| `manifest.py` | Replaced by `lance_index.py` with `LanceIndex` class |
| `schema.py` | `serialize_leaf` / `deserialize_leaf` replaced by `PhotoEntry → pa.RecordBatch` helper |
| Whitebeard housekeeping tool | Write to LanceDB instead of (or alongside) `manifest.json` |
| Wally search tool | Query LanceDB instead of reading `manifest.json` + custom filter |
| `pyproject.toml` (py-toolkit) | Add `lancedb` dependency |

---

## Migration Strategy

**No migration function.** Reindexing from XMP sidecars is the migration — it avoids the risk of
a JSON→LanceDB copy producing a stale or inconsistent index if XMP files have been updated since
the last manifest rebuild.

### Detection (in Woof, at first MCP tool call per backend)

| State | Action |
|---|---|
| `.ouestcharlie/index.lance/` exists | Use LanceDB — fully migrated |
| `summary.json` exists, no `index.lance/` | Old JSON index detected → return warning to LLM |
| Neither | Fresh backend → prompt user to index |
| Both | Partial migration → treat as old index, prompt reindex |

### User-facing flow

```
Woof detects old index
  → MCP tool returns: "Old JSON-based index found at <backend>.
                       Please ask me to reindex to use the new format."
  → User asks AI Assistant to reindex
  → AI Assistant calls reindex MCP tool
  → Whitebeard runs housekeeping on all partitions (reads XMP → writes LanceDB)
  → Old manifest.json / summary.json files left in place (harmless, ignored)
```

Old JSON files are **not deleted automatically** — they become inert once `index.lance/` exists.
Users who want to reclaim space can delete `.ouestcharlie/*/manifest.json` and
`.ouestcharlie/summary.json` manually after confirming the new index is healthy.

### Thumbnail positions: the one justified JSON read during migration

Generating thumbnails is expensive (Rust AVIF encoding, potentially hours for large libraries).
During reindex, Whitebeard reads thumbnail chunk positions from the old `manifest.json`
and inserts them into the `thumbnail` struct column — **without regenerating the AVIF files**.

```
For each partition during migration:
  1. Read all XMP sidecars → PhotoEntry objects (metadata, searchable fields)
  2. Read old manifest.json → extract thumbnailChunks[].grid.photoOrder
     → build content_hash → {avif_hash, col, row, tile_size} lookup
  3. Merge: for each PhotoEntry, attach thumbnail struct if found in lookup
  4. Upsert combined rows into LanceDB
  5. If a photo has no thumbnail entry (new photo added since last housekeeping),
     thumbnail column is NULL — Whitebeard will fill it on next housekeeping run
```

After successful migration of a partition, old `manifest.json` and `summary.json` are left
in place (ignored by Wally once `index.lance/` exists).

### Why not read JSON and insert into LanceDB (for everything else)

- XMP is the source of truth; JSON manifests may be stale for all metadata fields
- Whitebeard already implements the full XMP → index pipeline
- Thumbnail positions are the exception: AVIF files already exist on disk, positions are stable

---

## Suggested Next Step (if proceeding)

Prototype the write path first: a standalone script that:
1. Reads all XMP sidecars from a test partition
2. Builds `PhotoEntry` objects (existing code, no change)
3. Converts to `pa.Table` using `PHOTO_SCHEMA`
4. Writes to `.ouestcharlie/index.lance/` with `lancedb.connect().create_table()`
5. Runs a sample query (`date_taken`, `rating`, `tags`) and compares results to the existing manifest

This validates the schema, dependency footprint, and query expressiveness before any agent changes.
