# OEC#11c — LanceDB index maintenance: compaction and version pruning

#status:done

## Context

LanceDB uses a versioned, append-only file format (Lance). Every `merge_insert` call creates a
new version snapshot and one or more small fragment files. Over time, without maintenance:

- **Fragment proliferation** — each partition upsert adds files; many small fragments hurt scan
  performance (Wally search reads every fragment).
- **Version accumulation** — all historical versions are retained on disk indefinitely. For
  OuEstCharlie, time-travel past the current session is not needed: XMP sidecars are the source
  of truth and the index is a derived cache that can be rebuilt at any time.

## Approach

Add a single `maintain()` call at the end of a full library index run. It does two things in
sequence:

1. **Compact files** — merge many small fragment files into fewer, larger files. LanceDB's
   `compact_files()` picks up all un-compacted fragments and rewrites them; subsequent scans
   read fewer files.

2. **Prune old versions** — delete version snapshots older than 1 hour via
   `cleanup_old_versions(older_than=timedelta(hours=1))`. Consecutive index runs are typically
   minutes to hours apart, so each run cleans up the previous run's leftovers without needing
   a separate scheduled job. The 1-hour window also covers any crash-recovery scenario where a
   partial run left behind unfinished version files.

Compaction must run **before** cleanup so that the compacted versions are not themselves pruned
immediately.

## LanceDB API

```python
# Compact small fragment files into larger ones.
# Returns a CompactionMetrics object (logged for observability).
stats = table.compact_files()

# Remove version history older than the given delta.
# delete_unverified=False (default) preserves fragments referenced by recent transactions.
table.cleanup_old_versions(older_than=timedelta(hours=1))
```

Both calls are synchronous and must be dispatched via `asyncio.to_thread`.

## Changes

### `ouestcharlie-py-toolkit/src/ouestcharlie_toolkit/lance_index.py`

- Add `timedelta` to the existing `from datetime import UTC, datetime` import.
- Add `maintain()` async method to `LanceIndex`:

```python
async def maintain(self) -> None:
    """Compact fragment files and prune version history older than 1 hour."""
    def _lance_worker():
        stats = self._table.compact_files()
        _log.info("Lance compaction: %s", stats)
        self._table.cleanup_old_versions(older_than=timedelta(hours=1))
    await asyncio.to_thread(_lance_worker)
```

### `ouestcharlie-whitebeard/src/whitebeard/indexer.py`

In `index_library()`, call `lance_index.maintain()` after `_prune_deleted_partitions()` and
before computing `total_duration_ms`:

```python
library_result.partitions_deleted = await _prune_deleted_partitions(
    backend, manifest_store, lance_index, indexed_paths
)

await lance_index.maintain()  # compact fragments + prune old versions

library_result.total_duration_ms = round((time.monotonic() - _t0) * 1000)
return library_result
```

## Verification

1. Run Whitebeard on a test backend — no exception from `compact_files()` or
   `cleanup_old_versions()`, and the compaction stats are logged.
2. Inspect `.ouestcharlie/index.lance/photos.lance/` before and after: fragment file count
   should decrease; `_versions/` entries older than 1 hour should be absent.
3. Run Wally search immediately after maintenance — results must be unchanged.
