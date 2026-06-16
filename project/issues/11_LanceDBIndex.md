# Feasibility: Replace Manifest Index with LanceDB

#status:done

## Context

OuEstCharlie's current index is a two-level JSON hierarchy:
- **`summary.json`** — flat list of all partitions with bloom filters, min/max stats, GPS bboxes
- **`manifest.json`** per partition — full per-photo metadata (~1,000 photos each, ~1.5 MB)

These files are written by Whitebeard (housekeeping) and queried by Wally (search).
Custom pruning logic (bloom filters, range checks) is implemented in `fields.py` / `schema.py`.

The question: could LanceDB replace this custom index with a general-purpose columnar store?

---

## TL;DR: Yes — and it's a clean fit

LanceDB is just a directory of table files on disk. It would live at `.ouestcharlie/index.lance/`
inside each backend root, keeping the "no central database" constraint intact. Each backend
stays self-contained.

---

## Mapping the Workflow steps to the Codebase

| User step | Current code | LanceDB equivalent |
|---|---|---|
| **1. Extract EXIF → XMP** | `xmp.py` + Whitebeard | Unchanged |
| **2. XMP → list of dicts** | `schema.py: PhotoEntry.from_sidecar()` → `serialize_leaf()` | Same `PhotoEntry` objects, converted to `pa.Table` via PyArrow |
| **3. Insert into columnar store** | `manifest.py: ManifestStore.write_leaf()` | `lancedb.upsert()` on `content_hash` |
| **4. Update the summary** | `manifest.py: ManifestStore.upsert_partition_in_summary()` | eventual summary is created as a query on the lancedb table |

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
        pa.field("tile_index", pa.int8()),                   # 0-based tile index in the grid
    ]), nullable=True),                                      # NULL until thumbnail is built
    pa.field("_last_update",     pa.timestamp("us"), nullable=False), # The technical upsert date
    # Future: vector column for semantic/embedding search
    # pa.field("vector",          pa.list_(pa.float32(), 512), nullable=True),
])
```

---

## Partition Summary for LLM Context

In the current system, `summary.json` is a pre-computed file that gives an overview of the library
(date ranges, bloom filters, GPS bboxes per partition). With LanceDB, this is created at the end of the indexing operations.

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

The summary operation at the end of indexing runs both queries and write the summary.json, including the schema version.

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
- Backend protocol (`filesystem`, `cloud_mounted`, future S3/GCS)

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
- **New dependency**: `lancedb` + `pyarrow` (~50 MB wheel); rawpy already adds weight, but still notable for cross-platform builds. No support for macos-intel
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
| Cross-platform | ⚠️ | LanceDB has wheels for macOS, Linux, Windows but must drop macOs Intel architecture |
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

Detection is based on the schemaVersion in `summary.json`, already implemented as part of issue `14_8ColumnAvidGrid.md`.
Schema version is bumped to `3`.

Old JSON files are **not deleted automatically** — they become inert once `index.lance/` exists.
Users who want to reclaim space can delete `.ouestcharlie/*/manifest.json` manually after confirming the new index is healthy.

---

## Suggested Next Step (if proceeding)

Prototype the write path first: a standalone script that:
1. Setup LanceDB is py-toolkit, drop support for macOs Intel architecture
2. Converts to `pa.Table` using `PHOTO_SCHEMA`
3. Writes to `.ouestcharlie/index.lance/` with `lancedb.connect().create_table()`
4. Create the new `.ouestcharlie/summary.json` from the queries
5. Runs a sample query (`date_taken`, `rating`, `tags`) and compares results to the existing manifest

This validates the schema, dependency footprint, and query expressiveness before any agent changes.
