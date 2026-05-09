# Per-Partition Lock

#status:done

## Context

When an agent indexes or enriches a partition of N photos it calls `write_conditional` N+1 times (N XMP sidecars + 1 leaf manifest). Each call used to go through the full per-file lock protocol:

1. Compute sidecar lock path (`.ouestcharlie/{partition}/{filename}.lock`)
2. Create parent directory if needed
3. Open the `.lock` file
4. Acquire `fcntl.flock(LOCK_EX)` / `msvcrt.locking(LK_LOCK, 1)` (blocks until exclusive)
5. Stat the file, check version, write atomically
6. Release the lock

For a 1 000-photo partition this meant ≈ 1 001 lock files on disk and ≈ 1 001 cross-process lock acquisitions.

**Thumbnail / preview grids were already exempt.** They are written with `write_new()` (using `os.link()` for atomic create-exclusive) because their filenames include a content hash.

---

## Solution Implemented

Cross-process locking was moved entirely out of the store methods and into the callers that own the operation.

### Design principles

1. **`write_conditional(path, data, version)`** — no lock parameters. Holds only a per-path `threading.Lock` (intra-process safety for `run_in_executor` dispatches). No lock files created.
2. **`Backend.partition_lock(partition)`** — async context manager that acquires a single `_CrossProcessLock` on `.ouestcharlie/{partition}/partition.lock`. Pass `partition=""` for the root (summary.json) lock → `.ouestcharlie/partition.lock`.
3. **Store write methods (`write_leaf`, `write_summary`, `XmpStore.write`)** — no lock management. Each method's doc comment states the required precondition ("caller must hold `partition_lock()`").
4. **The partition processor (`index_partition` in whitebeard)** owns the partition lock for the entire read → process → write cycle.

### Lock ownership map

| Operation | Lock owner |
|-----------|-----------|
| XMP sidecar writes (batch) | `index_partition` via `partition_lock(partition)` |
| Leaf manifest write | `index_partition` via `partition_lock(partition)` |
| Thumbnail writes | None (content-addressed, `write_new`) |
| Root summary update | `upsert_partition_in_summary` via `partition_lock("")` |
| Root summary prune | `_prune_deleted_partitions` via `partition_lock("")` |

---

## Files Changed

### `ouestcharlie-py-toolkit`

| File | Change |
|------|--------|
| `backend.py` | Added `PartitionLockToken` data class; added `partition_lock()` to `Backend` Protocol; `write_conditional` signature reduced to `(path, data, version)` |
| `backends/local.py` | `write_conditional` — threading lock only, no lock files; `partition_lock()` — `_CrossProcessLock` on `.ouestcharlie/{partition}/partition.lock`; empty partition string → `.ouestcharlie/partition.lock` |
| `xmp.py` | `XmpStore.write` — removed `partition_lock` param, calls `write_conditional` directly; removed `xmp_lock_dir_for` (dead code) |
| `manifest.py` | `write_leaf`, `write_summary`, `read_modify_write_leaf` — removed `partition_lock` params; `upsert_partition_in_summary` — acquires `partition_lock("")` around `write_summary` |
| `__init__.py` | Removed `xmp_lock_dir_for` from public API |

### `ouestcharlie-whitebeard`

| File | Change |
|------|--------|
| `indexer.py` — `index_partition` | Wrapped entire read → process → write cycle in `async with backend.partition_lock(partition):`. Manifest read moved inside the lock so version token stays valid for the write. `list_files` stays outside (read-only). Summary update stays outside (uses its own root lock). |
| `indexer.py` — `_prune_deleted_partitions` | Added `async with backend.partition_lock(""):` around `write_summary`. |

---

## Outcome

| | Before | After |
|---|---|---|
| Lock files per partition (1 000 photos) | ~1 001 (one per XMP + one per manifest) | 1 (`partition.lock`) |
| Cross-process lock acquisitions per indexing run | ~1 001 | 1 |
| `write_conditional` signature | `(path, data, version, lock_dir=None, partition_lock=None)` | `(path, data, version)` |
| Thumbnail / preview writes | 0 (already lock-free) | 0 (unchanged) |
