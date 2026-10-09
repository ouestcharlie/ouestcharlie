# OEC-60: Duplicate Lance rows for one photo (hash change, identical copies)

#status:ongoing

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
- Found while verifying this issue: `index_partition_scope` accepts a scope
  entry that is not an existing folder (e.g. a typo, or a stray character
  such as `2024/2024-07?`). The folder lists no files, so the run ends
  immediately and reports 0 photos, with no error. That looks like an indexing
  failure.

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
rows_per_hash: dict[str, int] = {}
existing_thumbs: dict[str, tuple[str, int]] = {}
async for row in lance_index.get_partition_rows(
    partition,
    columns=["filename", "content_hash", "thumbnail_avif_hash", "thumbnail_tile_index"],
):
    hashes_by_filename.setdefault(row["filename"], set()).add(row["content_hash"])
    filenames_by_hash.setdefault(row["content_hash"], set()).add(row["filename"])
    rows_per_hash[row["content_hash"]] = rows_per_hash.get(row["content_hash"], 0) + 1
    # existing_thumbs[hash] = (avif_hash, tile_index) when both are set
```

`rows_per_hash` catches two identical rows (same filename and hash), which the
sets collapse. `existing_thumbs` is used in step 3.

Keep `new_entries` and `deleted_filenames` on the keys of `hashes_by_filename`.
The incremental skip changes: a filename is skipped only when it has **exactly
one** row. A filename with several rows had its hash change (cause A left by an
earlier full re-index), so it is re-processed even in incremental mode to learn
which hash is current. Otherwise an incremental run could never repair it.

### 2. One representative per hash, chosen by the indexer

**File:** `ouestcharlie-whitebeard/src/whitebeard/indexer.py` (after extraction)

After extraction (step 3's write-back included), pick one representative
filename per hash among the processed entries, and drop the other copies from
`photo_entries` with a DEBUG log (identical copies are expected):

- **Incumbent:** if the hash is already indexed under a filename that still
  holds it, that filename stays the representative. A filename "still holds" a
  hash if it was processed with that hash, or skipped with that single indexed
  hash. If the hash is stale (step 3), only processed filenames qualify, since
  the row is deleted and only processed entries write it back.
- **Otherwise:** the lexicographically smallest processed filename with that
  hash.

This runs after extraction rather than per file in the extraction loop. In full
mode, a file whose hash changed must not keep its old hash as an incumbent and
push out a new copy that now holds it.

The indexer therefore never passes two entries with the same hash to
`upsert_partition`. That removes the alternating filename in incremental mode,
and the `Duplicate content_hash … skipping` warning from normal runs.

**File:** `ouestcharlie-py-toolkit/src/ouestcharlie_toolkit/lance_index.py`
(`upsert_partition`, around line 340)

Keep the batch deduplication as a safety net, and keep it a **warning**: since callers
pick one representative per hash, a duplicate here is a caller bug. Keep a
deterministic copy (the lexicographically smallest filename) instead of the
first in list order.

### 3. Delete stale and duplicate rows before the upsert

**File:** `ouestcharlie-whitebeard/src/whitebeard/indexer.py` (lines 286–293)

Build one set of stale hashes to delete:

- **Deleted files:** all hashes of filenames gone from disk.
- **Replaced hash (cause A):** for each processed entry, every existing hash for
  its filename that differs from `entry.content_hash`.
- **Duplicate key (cause B):** every hash with more than one existing row
  (`rows_per_hash[h] > 1`).

Call `lance_index.delete(partition, …)` **before** `upsert_partition`.

A stale hash may still be held by a file skipped in incremental mode: another
copy of a deleted file, or a duplicate-key row. Deleting it would drop that
photo, so it has to be written back. Whenever a stale hash is not held by any
processed entry, re-process the smallest on-disk, not-yet-processed filename
indexed under it (it moves from `photos_skipped` to `photos_processed`).
Extraction reuses the sidecar, so this is cheap. Repeat until nothing is added:
a re-processed file may reveal a changed hash, which is stale in turn. Each file
is processed at most once per run: files already attempted, including those
whose extraction failed, are never picked again.

If a stale hash is still indexed under an on-disk file whose extraction failed
(e.g. a transient read error), nothing can write it back: keep its rows instead
of deleting them (WARNING log). The photo stays in the index, and a later run
completes the repair.

Deleting before the upsert also fixes the swapped-content case. If file X's new
hash equals file Y's old hash, the upsert writes that row back instead of the
delete removing it.

`upsert_partition` reads existing thumbnails **after** the delete, so
re-inserted rows would lose their thumbnail reference. Carry the stale hashes'
thumbnails (`existing_thumbs`, read in step 1) into `thumbnail_lookup` before
deleting; freshly generated thumbnails take precedence.

In incremental mode, generate thumbnails for new filenames **and** for
re-processed files whose hash was never indexed (e.g. a filename with several
rows, re-read with `force_extract_exif=True`). Their hash has no thumbnail to
carry over, so selecting `new_entries` by filename alone would leave the row
without a thumbnail.

### 4. Reject partition scope entries that are not existing folders

**File:** `ouestcharlie-py-toolkit/src/ouestcharlie_toolkit/backend.py`
(`Backend` protocol) and `backends/local.py` (`LocalBackend`)

Add a directory check to the backend. `Backend.exists` is specified for files
only.

```python
async def dir_exists(self, path: str) -> bool:
    """True for an existing directory ("" is the root; trailing slash allowed).
    False for a missing path, a file, or a path outside the backend root."""
```

`LocalBackend` resolves the path with the existing root-escape check, then uses
`Path.is_dir()`. A path outside the root returns False instead of raising
`ValueError` as other methods do: "not a folder of this library" is the
correct answer, and callers need no try/except. `CloudMountedBackend` inherits
it.

**File:** `ouestcharlie-whitebeard/src/whitebeard/indexer.py`
(`index_partition_scope`)

After the schema checks and before indexing anything, call
`backend.dir_exists` on every entry. If any entry is missing, raise
`ValueError` naming all missing entries, with a hint that paths are relative to
the library root. Deleted folders are not accepted either: removing them from
the index is the job of a full `index_library`, and the message says so. Woof
reports the error as a failed indexing session.

**File:** `ouestcharlie-whitebeard/src/whitebeard/agent.py`

In the `index_partition_scope` tool docstring, state that entries are relative
to the library root and must be existing folders.

Release note: whitebeard then needs a py-toolkit version with `dir_exists`;
raise the `ouestcharlie-py-toolkit` minimum in whitebeard's `pyproject.toml`
when the toolkit is released.

### 5. Tests

**File:** `ouestcharlie-whitebeard/tests/test_indexer.py`

- `test_full_index_replaces_row_when_content_hash_changes` (A): index, change
  the file's bytes, re-index with `force_full_index=True,
  force_extract_exif=True`; one row for that filename, with the new hash.
- `test_incremental_repairs_filename_with_two_hashes` (A, existing index): seed
  the old hash's row back next to the new one; an incremental run leaves one
  row, with the new hash.
- `test_identical_copies_single_row` (B): two byte-identical files in one
  partition give one row, and that row survives both a full and an incremental
  re-index. No `Duplicate content_hash` warning is logged.
- `test_identical_copies_representative_is_stable`: add a copy whose name sorts
  first after the original is indexed, run incremental indexing twice; the
  row's `filename` does not change.
- `test_repairs_duplicate_key_rows`: seed two rows with the same
  `(partition, content_hash)`, under two filenames and under one; after an
  incremental run, one row per hash and per filename remains.
- `test_repair_preserves_thumbnail_reference`: a duplicate-key row deleted and
  written back keeps its thumbnail reference.
- `test_deleting_representative_keeps_remaining_copy`: delete the file named in
  the row while the other copy remains; the row is kept, now named after the
  remaining copy.
- `test_deleting_representative_keeps_indexed_copy`: same, when the remaining
  copy already had its own duplicate-key row.
- `test_swapped_content_keeps_both_rows`: two files swap bytes; after a full
  re-index, both filenames are present with each other's former hashes. (This
  one also passes on the old code, where `merge_insert` happens to swap the
  rows; it guards the delete-before-upsert order.)
- `test_repair_keeps_rows_when_holder_fails_extraction`: a duplicate-key row's
  only file fails extraction; its rows are kept, and a later healthy run leaves
  one row.
- `test_failed_file_is_processed_once`: in full mode, a failing file holding a
  stale hash is processed once (`photos_processed == 1`, `photos_skipped == 0`,
  one error).
- `test_reprocessed_file_with_new_hash_gets_thumbnail`: a filename with two
  rows, re-read in incremental mode with a new hash, is passed to the thumbnail
  builder.
- `test_index_partition_scope_rejects_missing_partition` (parametrized:
  `2024/2024-07?`, `2024-07`, `missing`, a file path, `/2024/2024-07`,
  `../2024`): the run raises `ValueError` naming only the bad entry, and no
  partition is indexed, not even the valid entry next to it.
- `test_index_partition_scope_accepts_existing_partition` (parametrized: `""`,
  `2024`, `2024/2024-07`, `2024/2024-07/`).

Seeding duplicate rows bypasses `merge_insert`: append the row directly to the
Lance table.

**File:** `ouestcharlie-py-toolkit/tests/test_lance_index.py`

- Rename `test_upsert_duplicate_hash_in_batch_keeps_first` (OEC-11b) to
  `test_upsert_duplicate_hash_in_batch_keeps_smallest_filename`, with the copies
  in reverse order: the kept copy is the lexicographically smallest filename.

**File:** `ouestcharlie-py-toolkit/tests/test_backend_local.py`

- `test_dir_exists_true_for_existing_dir` (parametrized: `""`, `sub`, `sub/`,
  `sub/inner`).
- `test_dir_exists_false_for_missing_file_or_outside` (parametrized: a missing
  path, a file, `..`, `/sub`, `sub/../../x`).

### 6. Documentation

**File:** `ouestcharlie-whitebeard/whitebeard_LLD.md` (LanceDB Write section)

- State the design rule: one row per `(partition, content_hash)`; identical
  copies share one row, one thumbnail and one preview; `filename` names a stable
  representative copy.
- Describe the delete-then-upsert order, and the repair of duplicate-key rows
  on every run.
- State that the indexer picks the representative, and that the batch deduplication in
  `upsert_partition` is a safety net that warns.

---

## Verification

1. From `ouestcharlie-whitebeard/`: `uv run pytest tests/test_indexer.py -v`;
   from `ouestcharlie-py-toolkit/`:
   `uv run pytest tests/test_lance_index.py tests/test_backend_local.py -v`.
2. On a library whose index already holds duplicate rows, run an incremental
   `index_library`, then query Lance. There should be no
   `(partition, content_hash)` and no `(partition, filename)` with more than
   one row.
3. Run it a second time: for a partition with identical copies, the row's
   `filename` stays the same.
4. Open the gallery on that partition: no duplicate-key error, every grid page
   renders, and the identical copies show as one tile.
5. Call `index_library` with a scope entry that does not exist (e.g.
   `["2024/2024-07?"]`): the indexing session fails with an error naming that
   entry, instead of reporting 0 photos.

---

## Open points

- Should the gallery show that a photo has identical copies, for example a
  "2 copies" note in the details panel? That would need the other filenames,
  which the row does not store.
- Related, done: tags are now deduplicated on insert in `photo_entry_to_row`
  (py-toolkit).
