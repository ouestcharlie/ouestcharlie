# OEC-65: Re-index photos and videos whose media file changed

#status:draft

Status flow: draft (write spec) -> open (review spec) -> todo (spec validated) -> ongoing (implementation started) -> done (merged)

## Context

OEC-64 makes an incremental index pick up a **sidecar** edited by another tool.
It leaves out changes to the **media file** itself while its sidecar is
unchanged (OEC-64, Context, second "Out of scope"). OuEstCharlie never writes
to media files (HLR, "Immutable photos"), but other tools do:

- a rotation in Finder, Preview or Windows Photos (rewrites the EXIF
  orientation, sometimes the pixels);
- an edit saved over the original (GIMP, Affinity, a phone editor);
- a tool writing metadata into the file (exiftool, digiKam or Lightroom set to
  write into JPEG/DNG), e.g. to fix a camera clock or add GPS;
- a video trimmed in place (QuickTime, Photos);
- the same file replaced by a sync client with the version edited on another
  device.

Today none of these reach the index:

- **Incremental mode** skips the file. In
  `ouestcharlie-whitebeard/src/whitebeard/indexer.py`, `index_partition`
  (around line 300) compares the sidecar token only. The media file's token,
  already returned by `backend.list_files` (line 206), is discarded.
- **`force_full_index=True`** re-processes the file, but
  `XmpStore.read_or_create_from_picture`
  (`ouestcharlie-py-toolkit/src/ouestcharlie_toolkit/xmp.py`, line 497) returns
  the existing sidecar unchanged when it holds `ouestcharlie:contentHash`. The
  row keeps the old hash, the old EXIF-derived fields and, since thumbnails
  and previews are addressed by hash, the old thumbnail and preview.
- Only **`force_extract_exif=True`** refreshes them, by rebuilding the sidecar
  from the file. It also discards the rating, tags and description stored in
  the sidecar, so it is not a usable fix.

The stale hash is the worst part: the gallery shows the image as it was before
the edit, and `contentHash` no longer identifies the file.

Intended outcome: an incremental run re-hashes exactly the media files whose
version token changed since the last index. When the hash differs, the
file-derived fields are refreshed, the sidecar keeps the user's fields and gets
the new hash, and the row, thumbnail and preview follow the new content. When
the hash is the same (a `touch`, a sync client re-stamping files), only the
stored token is updated. Unchanged files are still skipped without reading them
or their sidecar.

**Dependency on OEC-64.** This issue reuses its listing of tokens, its skip
condition and its summary line in Woof. OEC-64 must be merged first.

Out of scope, as in OEC-64: **when** an incremental run happens (long-running
Woof, OpenPoints §11).

Also out of scope: **renames and moves.** A renamed file is a deletion plus an
addition today, and its sidecar is orphaned unless renamed with it. Unchanged
by this issue.

---

## Changes

### 1. Store the media file's version token

**File:** `ouestcharlie-py-toolkit/src/ouestcharlie_toolkit/schema.py`
(`PhotoEntry`, around line 75)

Add `media_version_token: str = ""` next to `xmp_version_token`, and a
`media_version_token` parameter to `PhotoEntry.from_sidecar`.

**File:** `ouestcharlie-py-toolkit/src/ouestcharlie_toolkit/lance_index.py`
(schema line 88, row conversion lines 155, 189 and 212)

Add `pa.field("media_version_token", pa.string(), nullable=True)` and map it
both ways like `xmp_version_token`. `_migrate_table` adds the column to
existing tables (null on existing rows). Additive change: `SCHEMA_VERSION` and
`LOWEST_SCHEMA_VERSION` stay at 6.

### 2. Re-hash and refresh in the sidecar store

**File:** `ouestcharlie-py-toolkit/src/ouestcharlie_toolkit/xmp.py`
(`XmpStore.read_or_create_from_picture`, line 497)

Add a `verify_media: bool = False` parameter. When an existing sidecar is found
and `verify_media` is set:

1. Compute the media file's identity (`create_identity()`, i.e. BLAKE3 of the
   file for a photo, header + cover frame for a video).
2. **Same hash as the sidecar's `contentHash`:** return the sidecar unchanged,
   as today.
3. **Different hash:** extract the file's metadata (`extract()`), merge it into
   the existing sidecar (below), write the sidecar with
   `write_conditional(expected_version=existing_version)`, and return the
   merged sidecar with the new version token.

Sidecars without `contentHash` (third-party, e.g. darktable) already get their
hash recomputed from the file on every read; step 1 reuses that value. In
step 3 they are not written back, consistent with the current policy for
third-party sidecars: the merged values go only to the row. The next run
recomputes the hash anyway.

Replace the `created: bool` in the return value by an outcome, so the indexer
can count each case:

```python
class SidecarOutcome(Enum):
    READ = "read"            # existing sidecar returned unchanged
    CREATED = "created"      # new sidecar written (none existed, or force=True)
    REFRESHED = "refreshed"  # media changed: file-derived fields refreshed

# Before
async def read_or_create_from_picture(self, photo_path, force=False) -> tuple[XmpSidecar, VersionToken, bool]

# After
async def read_or_create_from_picture(
    self, photo_path, force=False, verify_media=False
) -> tuple[XmpSidecar, VersionToken, SidecarOutcome]
```

The only callers are the indexer (`_extract_one`) and three tests in
`tests/test_xmp.py`.

**Merge rule** (new pure function `merge_refreshed(existing, extracted)`):

| Fields | Source after the merge | Why |
|---|---|---|
| `content_hash`, `width`, `height`, `orientation`, `camera_make`, `camera_model`, `iso_speed`, `aperture`, `exposure_time`, `focal_length`, `focal_length_35mm`, `lens_model`, `media_type`, `duration_seconds`, `video_codec`, `has_audio` | extracted | Describe the file's content. A rotation or a trim changes them. |
| `rating`, `tags`, `description`, `_excluded_tags`, `_extra` | existing sidecar | Curated by the user and other tools in the sidecar, which is the source of truth. EXIF bootstrap values (XPKeywords, ImageDescription) are only for a first extraction. |
| `date_taken`, `gps` | existing sidecar; extracted only when the sidecar has none | Both can be corrected in the sidecar (darktable geotagging, enrichment skills). See Open points. |
| `metadata_version` | existing, incremented by `write` | Unchanged write rule. |

`_recover_date_offset` runs on the merged sidecar, as on any photo sidecar read.

A `VersionConflictError` on the write (another tool rewrote the sidecar
between read and write) is raised. The indexer records it as a failed file,
and the next run retries it.

### 3. Detect changed media files in the indexer

**File:** `ouestcharlie-whitebeard/src/whitebeard/indexer.py` (`index_partition`)

- Keep the media files' tokens from the listing (line 206):
  `media_tokens: dict[str, str]` (filename → `str(f.version.value)`).
- Read `media_version_token` with the existing rows (line 243):
  `indexed_media_tokens: dict[str, str]`, `""` for null.
- In the loop (around line 300), for an indexed filename:

```python
indexed = indexed_media_tokens.get(filename, "")
media_changed = indexed != "" and media_tokens[filename] != indexed
media_unknown = indexed == ""   # rows written before this issue
```

- Process the file when `force_full_index or changed or media_changed or
  media_unknown or len(...) != 1`. Pass
  `verify_media = force_full_index or media_changed` to `_extract_one`
  (line 762), which forwards it to `read_or_create_from_picture`, and passes
  the listing token to `PhotoEntry.from_sidecar`.
- **Unknown token (upgrade):** the file is processed once **without**
  re-hashing (one sidecar read), and the row stores its token. Re-hashing
  every file on the first run after the upgrade would read the whole library.
  Changes made before the upgrade are caught by a full re-index (below).
- **Full re-index re-hashes every file.** `force_full_index=True` becomes the
  documented way to repair any stale hash, including files changed before the
  upgrade or with a preserved mtime (step 5). It already decodes every file to
  rebuild thumbnails, so the extra read is a bounded cost.

**Which token is stored:** always the token from the listing, taken before the
hash is computed. If the file changes between the listing and the hash, the row
holds the new hash with the older token. The next run sees a token mismatch,
re-hashes, finds the same hash and only updates the token. Nothing is missed;
one extra hash at most.

### 4. Hash change: row, thumbnail, preview

No new logic. A refreshed entry carries a hash the partition has never indexed,
so the OEC-60 path already does the rest:

- the former hash is added to `stale_hashes` and its row deleted before the
  upsert (line 344);
- the entry is in `new_entries` (hash not in `filenames_by_hash`), so a new
  thumbnail tile is generated (line 418);
- Wally's preview is addressed by hash (`preview_jpeg_path`), so the gallery
  requests and generates a new one on first view.
- If the file was one of several identical copies, the other copies keep the
  former hash and the OEC-60 backfill writes it back under one of them.

Leftovers: the former preview JPEG and the former thumbnail tile are no longer
referenced. This is the same as for deleted photos today, which also leave
their preview behind. See Open points.

Counting: add `IndexResult.media_changed` (outcome `REFRESHED`) and
`LibraryIndexResult.total_media_changed`, and log the filenames at INFO like
changed sidecars. A token change with the same hash is logged at DEBUG only.

### 5. Known limit: mtime as change signal

Same rule as OEC-64 step 4: equality test on the token, not ordering. In
addition, some tools rewrite a media file and **keep its mtime on purpose**:
`exiftool -P`, `touch -r`, `cp -p` or `rsync -a` copying an edited version over.
Those changes are not detected by an incremental run. `force_full_index=True`
re-hashes and catches them. Document it; do not hash every file on
incremental runs.

### 6. Report changed media in the indexing summary

**File:** `ouestcharlie-whitebeard/src/whitebeard/agent.py` (summary dicts,
next to `totalSidecarsChanged`, lines 120 and 216, and the docstrings at lines
75 and 172)

Add `"totalMediaChanged": result.total_media_changed`.

**File:** `ouestcharlie-woof/gallery/src/components/IndexingProgress.svelte`

Show the count after the changed-sidecar line from OEC-64, with a new
`indexing_media_changed` message in every `gallery/messages/*.json` file (en,
en-GB, fr, de, es, ja, zh). Hidden when absent (older whitebeard).

Release order: py-toolkit, then whitebeard, then Woof, each pinning the
previous one.

### 7. Tests

**File:** `ouestcharlie-py-toolkit/tests/test_xmp.py`

- `test_verify_media_same_hash_returns_read`: `verify_media=True` on an
  unchanged file returns `READ` and does not write the sidecar.
- `test_verify_media_changed_photo_refreshes`: rewrite the JPEG with another
  orientation and size; the outcome is `REFRESHED`, the sidecar has the new
  hash, orientation and dimensions, and keeps its rating, tags, description,
  date and GPS.
- `test_verify_media_fills_missing_date_and_gps`: a sidecar without date or GPS
  takes them from the changed file.
- `test_verify_media_third_party_sidecar_not_written`: a darktable sidecar
  (OEC-63 fixture) is not rewritten; the returned sidecar has the new hash.
- `test_verify_media_conflict_raises`: a sidecar rewritten between read and
  write raises `VersionConflictError`.
- `test_merge_refreshed`: one assertion per row of the merge table.
- Update the three existing callers to the `SidecarOutcome` return.

**File:** `ouestcharlie-py-toolkit/tests/test_lance_index.py`

- `media_version_token` round-trips; a table created without the column is
  migrated and reads `""`.

**File:** `ouestcharlie-whitebeard/tests/test_indexer.py`

- `test_incremental_picks_up_media_edit`: index, overwrite a photo with
  different pixels (new mtime), run incremental; the row has the new hash, a
  new thumbnail tile, the old hash's row is gone, the rating is kept,
  `media_changed == 1`, the other photos are skipped.
- `test_incremental_touched_media_keeps_hash`: bump only the mtime; the row
  keeps its hash and thumbnail, its `media_version_token` is updated,
  `media_changed == 0`, and the next run skips it.
- `test_incremental_adopts_missing_media_token`: rows without
  `media_version_token` are processed once without hashing (spy on
  `content_hash`), then skipped.
- `test_full_index_rehashes_preserved_mtime`: change the file content and
  restore its mtime; incremental misses it, `force_full_index=True` refreshes
  it.
- `test_incremental_media_edit_identical_copy`: two identical copies, one
  edited; both rows exist afterwards, under their own hashes.
- `test_incremental_video_trim`: same as the first test for a video fixture.

**File:** `ouestcharlie-woof/gallery/src/components/IndexingProgress.test.js`

- The summary shows the changed-media count; hidden when `totalMediaChanged`
  is absent.

### 8. Documentation

- `ouestcharlie-whitebeard/whitebeard_LLD.md` (Incremental Indexing): replace
  the "EXIF changes … NOT detected" bullet: media files whose token changed are
  re-hashed, and refreshed when the hash differs (merge rule, thumbnail via the
  hash change). `force_full_index=True` re-hashes everything; preserved-mtime
  limit.
- `ouestcharlie-py-toolkit/py_toolkit_LLD.md` (XmpStore): `verify_media`, `SidecarOutcome`,
  merge rule.
- `HLD.md` (Change detection): the sweep also compares the media file's token,
  stored in `media_version_token`; a content change re-keys the row by its new
  hash. Step 4 of the flow mentions the refresh.
- `HLR.md` ("Immutable photos"): clarify that OuEstCharlie never writes to
  media files, but follows changes made to them by other tools.
- `ouestcharlie-woof/README.md` (feature table, line 61): add "and media files
  edited in place" to the Partial entry from OEC-64.

---

## Verification

1. From `ouestcharlie-py-toolkit/`: `uv run pytest tests/test_xmp.py
   tests/test_lance_index.py -v`; from `ouestcharlie-whitebeard/`:
   `uv run pytest tests/test_indexer.py -v`; from `ouestcharlie-woof/gallery/`:
   the `IndexingProgress` tests.
2. Upgrade an existing index and run an incremental `index_library`: every
   photo is processed once (sidecar read only, no full file reads), and the
   next run processes nothing.
3. Rate a JPEG in darktable and index its folder. Rotate the JPEG in
   Finder/Preview, then run an incremental `index_library` on the folder: the
   summary shows one changed media file, the gallery thumbnail and preview
   show the rotated image, and the rating is kept.
4. `touch` another file and run again: nothing is refreshed, and the run after
   that processes nothing.

---

## Open points

- **Date and GPS on a changed file.** The merge keeps the sidecar's values.
  This is wrong when the external edit was precisely a date or GPS fix (e.g.
  exiftool shifting a wrong camera clock): the fix is ignored. Alternative:
  take the extracted value when the sidecar's value still equals what the
  *previous* file contained, which requires remembering the extracted values
  (e.g. in the sidecar, under the `ouestcharlie:` namespace). Worth it?
- **Should the refresh also re-read embedded user metadata** (embedded XMP
  rating, keywords) when the sidecar has none? Today extraction only
  bootstraps tags and caption from Windows XP fields.
- **Orphaned previews and thumbnail tiles.** A hash change, like a deletion,
  leaves the former preview JPEG and tile behind. A cleanup step in
  `index_partition` (delete previews of hashes no longer in the partition)
  would cover both; separate issue?
- **Remote backends.** The design relies on the backend's version token for
  media files (ETag, generation, `modified_at`), as OEC-64 does for sidecars.
  On S3, a multipart ETag is not a content hash, so a re-upload of identical
  bytes is seen as a change and re-hashed; `Backend.content_hash` can use the
  provider checksum there without downloading.
