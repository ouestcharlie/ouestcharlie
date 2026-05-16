# OEC#11b — Deduplicate Lance index rows

#status:done

## Context

`LanceIndex.upsert_partition` merges rows into LanceDB using `content_hash` as the sole merge key. This causes two correctness bugs.

### Bug 1 — Cross-partition hash collision

If the same `content_hash` appears in two partitions (duplicate files across folders), the `merge_insert("content_hash")` in partition B matches the existing row from partition A and overwrites its `partition` column with `"B"`. After indexing both partitions, partition A's photo is absent from the index even though the file still exists on disk. On the next incremental run, partition A sees no existing rows for that hash, processes it again, and overwrites partition B's row — creating an unstable oscillation.

### Bug 2 — Within-batch duplicate hashes

If two files in the same partition share a `content_hash` (identical content, different filenames), both go into `rows_to_write`. LanceDB's behavior with duplicate merge keys in the source batch is undefined — it may create duplicate rows or silently drop one.

### Root cause

The correct unique identity for a row is `(content_hash, partition)` — a specific piece of content at a specific location. Using `content_hash` alone conflates global content identity with per-partition row identity.

## Fix

1. **Change the merge key** from `"content_hash"` to `["content_hash", "partition"]` in `upsert_partition`. LanceDB `merge_insert` accepts `str | Iterable[str]`.

2. **Deduplicate the source batch** before building `rows_to_write`: skip entries whose `content_hash` was already seen in the current batch and log a warning. Guard against an all-duplicate batch producing an empty list.

No schema change is needed — `(content_hash, partition)` is a logical key, not a new physical column.

## ToDo

- [ ] Fix `ouestcharlie-py-toolkit/src/ouestcharlie_toolkit/lance_index.py`: change merge key to `["content_hash", "partition"]` and add within-batch dedupe
- [ ] Add two regression tests to `ouestcharlie-py-toolkit/tests/test_lance_index.py`:
  - `test_upsert_same_hash_different_partitions_creates_two_rows`
  - `test_upsert_duplicate_hash_in_batch_keeps_first`
- [ ] Update `ouestcharlie-whitebeard/whitebeard_LLD.md` — LanceDB Write section to document the new merge key and within-batch dedupe
