# OEC-60: Duplicate Lance rows for one photo (hash change, identical copies)

#status:draft

Status flow: draft (write spec) -> open (review spec) -> todo (spec validated) -> ongoing (implementation started) -> done (merged)

## Context

The gallery grid (`ouestcharlie-woof/gallery/src/components/MediaGrid.svelte`)
keys tiles on `partition + '/' + filename`. When the index returns the same
filename twice in a partition, Svelte throws a duplicate-key error and stops
rendering the current grid page.

### Design rule

A row's identity is `(partition, content_hash)`, which is the merge key since
OEC-11b. Identical copies of a file within one partition must produce **a
single row**, one thumbnail and one preview. The row's `filename` names one
representative copy. So the index must hold exactly one row per
`(partition, content_hash)`, and one row per `(partition, filename)`.

### Two causes of duplicate rows

Both have been seen in a real library after a full re-index.

**A. Content hash changed.** A file keeps its name but gets a new hash. The
partition then holds two rows for that filename: one from the earlier index
with the old hash, one from the re-index with the new hash.

**B. Identical copies.** A partition holds two byte-identical files, e.g.
`IMG_0001.JPG` and `IMG_0001_modified.JPG`, whose sidecars carry the same
`contentHash`. The index holds two identical rows, both named after one copy,
with the same `_last_update` down to the microsecond, and no row for the other
copy. Having no row for the other copy is correct (one representative), but the
row is duplicated.

For cause B, the whitebeard log has one `Duplicate content_hash … skipping`
warning per pair during the re-index. It has no Lance write-conflict or retry
messages, but it logs at INFO, so Lance's internal retries would not show.

### How cause A happens

`XmpStore` reuses the hash stored in an existing sidecar
(`ouestcharlie-py-toolkit/src/ouestcharlie_toolkit/xmp.py`, around line 397).
A file gets a new hash only when its sidecar is re-read from the file:
`force_extract_exif=True`, a deleted sidecar, or a sidecar from another tool
without `ouestcharlie:contentHash` (hash recomputed on every run). Edits that
only touch the XMP sidecar keep the hash.

In `ouestcharlie-whitebeard/src/whitebeard/indexer.py`, `index_partition`:

- **Incremental mode** skips files already indexed by filename (line 215): no
  second row, but a stale one.
- **`force_full_index=True`** re-processes the file and upserts it under its new
  hash (line 288), which inserts a second row.
- Old rows are deleted only for files gone from disk (`deleted_filenames`,
  lines 201 and 291). A file that was modified but is still on disk is never
  cleaned up.

### How cause B happens

1. The index already held two rows with the same `(partition, content_hash)`,
   one per copy. They probably date from before OEC-11b, when duplicates within
   a batch were not filtered, but this is not confirmed.
2. On the full re-index, `upsert_partition` keeps one copy per hash and skips
   the other (the warning).
3. `merge_insert` matches the single source row against **both** target rows,
   and `when_matched_update_all` rewrites both from it: two identical rows.

The index never repairs this, because nothing checks that the merge key is
unique in the table.

It also leaves the representative copy unstable. This is expected from the code
but not observed. `existing_by_filename` only knows the representative's
filename, so each incremental run treats the other copy as new. It extracts it,
upserts it, and the matching row is renamed to that copy. The shown filename
then alternates between runs.

### Related gaps

- `existing_by_filename` maps each filename to a single hash (line 200). A
  filename with two rows looks like it has one, and deleting that file from
  disk removes only one of its rows.
- Deletion runs **after** the upsert (line 291). If the representative copy is
  deleted from disk while another copy remains, the upsert writes the hash
  under the remaining copy's name, and the delete then removes that row. The
  photo disappears from the index. `whitebeard_LLD.md` (LanceDB Write section)
  already says stale rows are deleted "before this step", so this corrects the
  code, not the doc.

Intended outcome: after any index run, each partition holds exactly one row per
`content_hash` and one per `filename`. The representative copy stays stable
across runs, and existing indexes are repaired by an ordinary run. No migration
script.

---

## Changes

### 1. Know every existing row, not one per filename

**File:** `ouestcharlie-whitebeard/src/whitebeard/indexer.py` (lines 196–201)

Read the partition's existing rows into two maps:

```python
# Before
existing_by_filename: dict[str, str] = {}
async for row in lance_index.get_partition_rows(...):
    existing_by_filename[row["filename"]] = row["content_hash"]

# After
hashes_by_filename: dict[str, set[str]] = {}
filenames_by_hash: dict[str, set[str]] = {}
async for row in lance_index.get_partition_rows(...):
    hashes_by_filename.setdefault(row["filename"], set()).add(row["content_hash"])
    filenames_by_hash.setdefault(row["content_hash"], set()).add(row["filename"])
```

Keep the existing membership checks (incremental skip, `new_entries`,
`deleted_filenames`) on the keys of `hashes_by_filename`.

### 2. Keep the representative copy stable

**File:** `ouestcharlie-whitebeard/src/whitebeard/indexer.py` (extraction loop)

After extracting a file whose filename isn't indexed yet, check whether its hash
is already indexed under another filename that is still on disk. If it is, the
file is an extra copy: drop it from `photo_entries`, and log it at DEBUG, not as
a warning. This removes the alternating filename in incremental mode.

**File:** `ouestcharlie-py-toolkit/src/ouestcharlie_toolkit/lance_index.py`
(`upsert_partition`, around line 340)

When a batch holds several copies of one hash, keep a deterministic one (the
lexicographically smallest filename) instead of the first in list order. Log the
other copies at DEBUG: identical copies are expected, not an anomaly.

### 3. Delete stale and duplicate rows before the upsert

**File:** `ouestcharlie-whitebeard/src/whitebeard/indexer.py` (lines 286–293)

Build one set of hashes to delete:

- **Deleted files:** all hashes of filenames gone from disk.
- **Replaced hash (cause A):** for each processed entry, every existing hash for
  its filename that differs from `entry.content_hash`.
- **Duplicate key (cause B):** every hash with more than one existing row
  (`len(filenames_by_hash[h]) > 1`, or two rows with the same filename).

Call `lance_index.delete(partition, …)` **before** `upsert_partition`.

A duplicate-key hash is deleted, so it has to be written back even in
incremental mode, where its file was skipped. Add its representative file to the
extraction list whenever the hash is in the delete set but not in
`photo_entries`. Extraction reuses the sidecar, so this is cheap.

Deleting before the upsert also fixes the swapped-content case. If file X's new
hash equals file Y's old hash, the upsert writes that row back instead of the
delete removing it.

Trade-off: `upsert_partition` reads existing thumbnails **after** the delete, so
re-inserted rows lose their thumbnail reference and get one regenerated. To
avoid that, read thumbnails for the deleted hashes before deleting and pass them
through `thumbnail_lookup`.

### 4. Tests

**File:** `ouestcharlie-whitebeard/tests/test_indexer.py`

- `test_full_index_replaces_row_when_content_hash_changes` (A): index, change
  the file's bytes, re-index with `force_full_index=True,
  force_extract_exif=True`; one row for that filename, with the new hash.
- `test_identical_copies_single_row` (B): two byte-identical files in one
  partition give one row, and that row survives both a full and an incremental
  re-index.
- `test_identical_copies_representative_is_stable`: run incremental indexing
  twice; the row's `filename` does not change.
- `test_repairs_duplicate_key_rows`: seed two rows with the same
  `(partition, content_hash)`; after an incremental run, one row remains.
- `test_deleting_representative_keeps_remaining_copy`: delete the file named in
  the row while the other copy remains; the row is kept, now named after the
  remaining copy.
- `test_swapped_content_keeps_both_rows`: two files swap bytes; after a full
  re-index, both filenames are present with each other's former hashes.

**File:** `ouestcharlie-py-toolkit/tests/test_lance_index.py`

- Update `test_upsert_duplicate_hash_in_batch_keeps_first` (OEC-11b): the kept
  copy is now the lexicographically smallest filename.

### 5. Documentation

**File:** `ouestcharlie-whitebeard/whitebeard_LLD.md` (LanceDB Write section)

- State the design rule: one row per `(partition, content_hash)`; identical
  copies share one row, one thumbnail and one preview; `filename` names a stable
  representative copy.
- Describe the delete-then-upsert order, and the repair of duplicate-key rows
  on every run.

---

## Verification

1. From `ouestcharlie-whitebeard/`: `uv run pytest tests/test_indexer.py -v`;
   from `ouestcharlie-py-toolkit/`: `uv run pytest tests/test_lance_index.py -v`.
2. On a library whose index already holds duplicate rows, run an incremental
   `index_library`, then query Lance. There should be no
   `(partition, content_hash)` and no `(partition, filename)` with more than
   one row.
3. Run it a second time: for a partition with identical copies, the row's
   `filename` stays the same.
4. Open the gallery on that partition: no duplicate-key error, every grid page
   renders, and the identical copies show as one tile.

---

## Open points

- Should the gallery show that a photo has identical copies, for example a
  "2 copies" note in the details panel? That would need the other filenames,
  which the row does not store.
- Related, done: tags are now deduplicated on insert in `photo_entry_to_row`
  (py-toolkit).
