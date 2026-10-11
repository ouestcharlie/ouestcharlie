# OEC-64: Re-index photos whose sidecar changed (incremental mode)

#status:done

Status flow: draft (write spec) -> open (review spec) -> todo (spec validated) -> ongoing (implementation started) -> done (merged)

## Context

OEC-63 makes OuEstCharlie read darktable-written sidecars correctly. It does
not make the index **notice** that darktable rewrote one. darktable rewrites
`NAME.EXT.xmp` at every sync (rating, tags, description, color labels), and so
do other tools sharing the sidecar (digiKam, Lightroom with `NAME.xmp`, a text
editor, OuEstCharlie's own enrichment scripts).

Today an incremental `index_library` / `index_partition_scope` never sees those
edits. In `ouestcharlie-whitebeard/src/whitebeard/indexer.py`,
`index_partition` skips every file already indexed under exactly one hash
(line 265). It decides by filename alone, without looking at the sidecar. The
only way to pick up a rating set in darktable is `force_full_index=True`, which
re-reads every sidecar of the scope and rebuilds every thumbnail container.

The design already provides for this. `HLD.md` (Change detection) states that
the index stores each photo's last-known sidecar version token and that a sweep
compares it to the current one. The column exists: `xmp_version_token` is
written on every row (`PhotoEntry.from_sidecar`, from the version returned by
`XmpStore.read_or_create_from_picture`, i.e. the sidecar's `st_mtime_ns`). It
is never read back.

`whitebeard_LLD.md` (Incremental Indexing) documents the current limit: only
new filenames are processed.

Intended outcome: an incremental run re-reads exactly the photos whose sidecar
changed, appeared or disappeared since the last index, and updates their rows.
Unchanged photos are still skipped without reading their sidecar. Thumbnails
are not rebuilt for a sidecar-only change.

**Dependency on OEC-63.** Without OEC-63, re-reading a darktable sidecar loses
the photo's date and ignores its rating and GPS. Picking these sidecars up
automatically would then degrade rows that a skip currently leaves intact.
OEC-63 must be merged first.

Out of scope: **when** an incremental run happens. The HLD's triggers, sweep
schedule and debounce need a long-running Woof (OpenPoints §11). Until then the
user, or an agent, runs `index_library` after editing in darktable. This issue
makes that run sufficient.

Also out of scope: changes to the **media file** itself (a crop, a rotation or
a re-export, on this device or synced from another one) while its sidecar is
unchanged. The skip ignores the media file's token from `list_files`, and even
`force_full_index=True` keeps the stale `ouestcharlie:contentHash` from the
existing sidecar (`XmpStore.read_or_create_from_picture`), so the hash, the
EXIF-derived fields and the thumbnail stay stale. Only `force_extract_exif=True`
refreshes them, by rebuilding the sidecar. A possible follow-up: also store the
media file's token, and re-hash the media file when it differs. The listing
already returns it at no extra cost.

---

## Changes

### 1. Resolve the current sidecar token without reading the sidecar

**File:** `ouestcharlie-py-toolkit/src/ouestcharlie_toolkit/xmp.py`

Add a pure helper next to the sidecar path function (around line 160) that
returns the candidate sidecar paths of a media file in the reader's order of
preference: `NAME.EXT.xmp`, then `NAME.xmp`. `XmpStore.read` uses it, so
the indexer and the reader agree on which sidecar is current.

```python
def sidecar_candidates(photo_path: str) -> tuple[str, str]:
    """Sidecar paths of a media file, in the order the reader tries them."""
```

### 2. List sidecars with the media files

**File:** `ouestcharlie-whitebeard/src/whitebeard/indexer.py` (`index_partition`,
line 196)

List `.xmp` files in the same call as the media files
(`MEDIA_EXTENSIONS | {".xmp"}`) and split the result. This costs no extra
directory scan. Build `sidecar_tokens: dict[str, str]` (path → `str(version.value)`),
the same string form as stored in `xmp_version_token`.

For each media file, its **current token** is the token of the first candidate
from step 1 present in `sidecar_tokens`, or `None` when it has no sidecar.

### 3. Skip only when the sidecar is unchanged

**File:** `ouestcharlie-whitebeard/src/whitebeard/indexer.py` (lines 207–221
and 265)

Also read `xmp_version_token` from the existing rows, keyed by filename
(`indexed_tokens: dict[str, str]`). The incremental skip becomes:

```python
# Before
if force_full_index or len(hashes_by_filename.get(filename, ())) != 1:

# After
if (
    force_full_index
    or len(hashes_by_filename.get(filename, ())) != 1
    or current_token(filename) != indexed_tokens.get(filename)
):
```

This covers:

- **Sidecar rewritten** (darktable sync, another tool, OuEstCharlie's skills):
  the mtime changed.
- **Sidecar deleted**: no current token. The file is re-processed and its
  sidecar re-created from the media file, instead of leaving the row pointing
  at nothing.
- **Sidecar form switched**: darktable creates `NAME.EXT.xmp` next to an older
  `NAME.xmp`. The reader now takes the new file; its token differs.
- **Rows with an empty token** (none expected, but the column defaults to `""`):
  re-processed once, then stored with their token.

A sidecar-only edit keeps the content hash (`ouestcharlie:contentHash` survives
a darktable sync, see OEC-63; without it the hash is recomputed from unchanged
bytes). The row is therefore updated in place by the `(partition, content_hash)`
merge. The file is not in `new_entries`, so no thumbnail is generated, and
`upsert_partition` keeps its existing thumbnail reference. The OEC-60 repair
logic is unchanged: a re-processed file whose hash did change is handled as
before.

Count these files in a new `IndexResult.sidecars_changed` field (they are
still counted in `photos_processed`) and log them at INFO, like deleted
photos, so the user can see that darktable edits were picked up. Add the
matching `total_sidecars_changed` property next to `total_sidecars_created`.

Race: a sidecar written between the listing and the read is read in its newer
state, and the row stores the token returned by the read. The next run compares
against that token, so nothing is missed or re-read twice.

### 4. Known limit: mtime as change signal

The comparison is an equality test, not an ordering. Any sidecar whose mtime
differs from the indexed token is re-read, whether the new mtime is later or
earlier. This covers a sidecar edited on another device and synced through a
cloud drive: sync clients usually set the edit time from the other device,
which differs from the indexed token even with clock skew or a coarser mtime
precision on the cloud side. A client that re-stamps local files after upload
only causes one extra re-read.

A sidecar whose mtime is set back to exactly the indexed value is not detected
(e.g. `touch -d`, or `cp -p` / `rsync -a` copying back the very version that
was indexed). `force_full_index=True` remains the fallback. Document it; do not
hash sidecars to work around it.

### 5. Report changed sidecars in the indexing summary

**File:** `ouestcharlie-whitebeard/src/whitebeard/agent.py` (summary dicts,
lines 115 and 206)

Add `"totalSidecarsChanged": result.total_sidecars_changed` next to
`totalSidecarsCreated`, in both `index_library` and `index_partition_scope`.

**File:** `ouestcharlie-woof/gallery/src/components/IndexingProgress.svelte`
(line 191)

Show the count after "Sidecars created", with a new
`indexing_sidecars_changed` message in every `gallery/messages/*.json` file
(en, en-GB, fr, de, es, ja, zh). A summary from an older whitebeard has no
`totalSidecarsChanged`: hide the line rather than showing an empty value.

Release order: py-toolkit (after OEC-63), then whitebeard, then Woof, each
pinning the previous one.

### 6. Tests

**File:** `ouestcharlie-whitebeard/tests/test_indexer.py`

- `test_incremental_picks_up_sidecar_edit`: index, rewrite the sidecar with a
  new rating and description (bumping its mtime), run incremental; the row has
  the new values, `sidecars_changed == 1`, the other photos are skipped.
- `test_incremental_sidecar_edit_keeps_thumbnail`: same; the row's
  `thumbnail_avif_hash`/`thumbnail_tile_index` are unchanged and the thumbnail
  builder is not called.
- `test_incremental_skips_unchanged_sidecar`: two incremental runs in a row;
  the second processes nothing and does not read any sidecar.
- `test_incremental_recreates_deleted_sidecar`: delete a sidecar, run
  incremental; it is re-created and the row's token updated.
- `test_incremental_follows_new_full_extension_sidecar`: a photo indexed from
  `NAME.xmp`, then a `NAME.EXT.xmp` with another rating is added; the row takes
  the new rating.
- `test_incremental_darktable_sidecar` (uses the OEC-63 darktable fixture):
  replace an OuEstCharlie sidecar with the darktable one, run incremental; the
  row has darktable's rating and tags, and keeps its date.

**File:** `ouestcharlie-py-toolkit/tests/test_xmp.py`

- `test_sidecar_candidates_order`, and a check that `XmpStore.read` resolves
  the same path as the first existing candidate.

**File:** `ouestcharlie-woof/gallery/src/components/IndexingProgress.test.js`

- The summary shows the changed-sidecar count; the line is hidden when
  `totalSidecarsChanged` is absent.

### 7. Documentation

- `ouestcharlie-whitebeard/whitebeard_LLD.md` (Indexing steps 1 and 4,
  Incremental Indexing): skip criterion is "indexed once **and** sidecar token
  unchanged"; sidecar edits by other tools are picked up; mtime limit (step 4).
- `ouestcharlie-whitebeard/src/whitebeard/agent.py` (`index_library` and
  `index_partition_scope` docstrings, lines 40 and 132): "only new photos and
  photos whose sidecar changed are processed".
- `HLD.md` (Change detection): the version-token comparison is implemented in
  the indexer's incremental mode; triggers, sweep and debounce remain to do.
- `ouestcharlie-woof/README.md` (feature table, line 61): "Change detection /
  automatic re-indexing" becomes "Partial — added and removed pictures, and
  sidecars edited by other tools (darktable, digiKam…); indexing is not yet
  triggered automatically".
- User-facing: the blog post from OEC-63 (§6, "Search, browse and maintain
  your darktable library with Woof") already says to reindex the folders after
  working in darktable. It relies on this issue; check its wording once merged.

---

## Verification

1. From `ouestcharlie-whitebeard/`: `uv run pytest tests/test_indexer.py -v`;
   from `ouestcharlie-py-toolkit/`: `uv run pytest tests/test_xmp.py -v`;
   from `ouestcharlie-woof/gallery/`: the `IndexingProgress` tests.
2. Index a folder, open one of its photos in darktable, change its rating and
   add a tag, and let darktable write the sidecar. Run an incremental
   `index_library` on the folder: the Woof indexing summary shows one changed
   sidecar, and
   `search_photos` on the new rating or tag finds the photo.
3. Run the incremental index again: nothing is processed.
4. In the gallery, the photo keeps its thumbnail and shows the new rating.

---

## Open points

- **Darktable clears OuEstCharlie's caption and tags** when it did not import
  them (OEC-63, concurrent edits). With this change the index follows the
  sidecar, so those values also disappear from search after the next run. This
  is correct (the sidecar is the source of truth), but it makes the darktable
  setting "look for updated XMP files on startup" more important. Should the
  indexer warn when a re-read sidecar lost a description or tags the row had?
- **Should Woof trigger the incremental run itself?** For example, at the start
  of `search_photos`/`browse_gallery` when the index is older than N minutes, on
  the partitions in scope. Cheap now that a skip costs one directory listing,
  but it adds latency to a search. Alternatively wait for the long-running Woof
  and the HLD's sweep.
- **Excluded tag prefixes** (OEC-33): changing them still requires a full
  re-index (`mcp_server.py:234`), since sidecars are unchanged. Unaffected here.
