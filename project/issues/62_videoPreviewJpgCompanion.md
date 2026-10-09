# OEC-62: Video preview JPG next to a video (older cameras)

#status:draft

Status flow: draft (write spec) -> open (review spec) -> todo (spec validated) -> ongoing (implementation started) -> done (merged)

## Context

Some older compact cameras record each video as a pair of files with the same
stem in the same folder:

- `NAME.MOV`, the video itself;
- `NAME.JPG`, a small still at the video's frame size (e.g. 1280×720, about
  150 KB). It is a poster/preview of the video, and it carries the EXIF the
  video container lacks: `DateTimeOriginal`, `Make`, `Model`, exposure
  settings.

Lightroom Classic treats this JPG as a metadata sidecar of the video, by design:
at import, it merges the pair into one video entry. (Its option "Treat JPEG files
next to raw files as separate photos" separates them.)

OuEstCharlie indexes both files as independent media today:

- **Duplicate content in the grid:** the JPG shows as a photo right next to the
  video's tile, which shows the same frame.
- **Poor video metadata:** the video's `date_taken`, `camera_make` and
  `camera_model` come from container tags only (`Video.extract_metadata` in
  `ouestcharlie-py-toolkit/src/ouestcharlie_toolkit/video.py`). Older cameras
  often don't write make/model there, and they may write `creation_time` in
  local time labelled as UTC. The better values sit, unused, in the JPG.

### Not to be confused with Live Photos

An Apple Live Photo is also a still plus a `.MOV` with the same stem. There the
still is the primary content: full resolution (e.g. 4032×3024), with a short
clip (about 3 s) at a lower resolution. Hiding the still would lose a photo.
Live Photo stills are usually HEIC, but exported or converted ones can be JPG.

The distinguishing criterion is the still's pixel size. A video preview has the
video's frame size; a Live Photo still is much larger than its clip.

Intended outcome: a video preview JPG is not indexed as a photo. It enriches
its video's metadata instead, and the pair shows as a single video tile. Live
Photos and unrelated same-stem files are unaffected. Existing indexes are
repaired by an ordinary run.

---

## Changes

### 1. Pairing rule (toolkit)

**File:** `ouestcharlie-py-toolkit/src/ouestcharlie_toolkit/video.py`

Add a helper that confirms that a JPG is the preview of a video:

```python
PREVIEW_SUFFIXES: frozenset[str] = frozenset({".jpg", ".jpeg"})

def preview_candidates(filenames: Iterable[str]) -> dict[str, str]:
    """Map preview JPG filename → video filename, by same stem (case-insensitive)
    within one folder. Filename rule only, no file access."""

async def is_video_preview(backend: Backend, jpg_path: str, video_path: str) -> bool:
    """True when the JPG's pixel size equals the video's frame size, in either
    orientation. Reads the JPEG header (PIL, no full decode) and the video
    stream's dimensions (container open, no frame decode)."""
```

- **Candidates:** a JPEG (`.jpg`/`.jpeg`, any case) and a video
  (`VIDEO_SUFFIXES`) with the same stem, compared case-insensitively. If several
  videos share the stem (e.g. `.MOV` and `.MP4`), the JPG is not a candidate:
  the pairing is ambiguous.
- **Confirmation:** the JPG's pixel size must equal the video's frame size,
  allowing a 90° swap. Use the stored dimensions, not EXIF
  `PixelXDimension`/`PixelYDimension`, which can be missing. Any read error
  means "not a preview", so the JPG stays indexed as a photo.

A helper function, not a new schema field: the pair is rediscovered each run
from the folder listing, so renaming or deleting either file updates the index
with no stored state to keep in sync. The check only runs for same-stem pairs,
which are rare, so the cost stays negligible.

### 2. Enrich the video's metadata from its preview

**File:** `ouestcharlie-py-toolkit/src/ouestcharlie_toolkit/video.py`
(`Video.extract_metadata`)

When the sidecar is created (or re-extracted with `force`), look for a preview
JPG next to the video: same stem, confirmed with `is_video_preview`. If found,
read its EXIF with `Photo.extract_exif`, and fill in the video's fields:

| Field | Rule |
|---|---|
| `camera_make`, `camera_model`, `lens_model` | JPG value when the video has none |
| `gps` | JPG value when the video has none |
| `iso_speed`, `aperture`, `exposure_time`, `focal_length`, `focal_length_35mm` | JPG value when the video has none |
| `date_taken` | See open point: JPG `DateTimeOriginal` when the video has no timezone-aware date |
| `content_hash`, `media_type`, `width`, `height`, `duration_seconds`, `video_codec`, `has_audio`, `orientation` | Always the video's own |

The values go into the video's own sidecar (`NAME.MOV.xmp`), so the sidecar
stays the source of truth, and they survive the preview JPG being deleted later.
Sidecars that already exist are not re-extracted: enriching an already indexed
video needs `force_extract_exif=True`. See open points.

### 3. Exclude the preview JPG from indexing

**File:** `ouestcharlie-whitebeard/src/whitebeard/indexer.py` (`index_partition`)

After `backend.list_files`, compute `preview_candidates` on the filenames,
confirm each pair with `is_video_preview`, and remove the confirmed JPGs from
`photo_files` and from `disk_filenames`, before the existing rows are compared.

- The JPG is not extracted: no sidecar is created for it, and it has no row.
- A row left by an earlier index for that JPG is removed by the existing
  deleted-file path: the JPG is no longer among the indexable files, so its
  hashes become stale (OEC-60). An ordinary incremental run therefore repairs
  existing indexes.
- A JPG sidecar created by an earlier index stays on disk, unused and harmless.
  Whitebeard never deletes user files.
- Log the excluded previews at DEBUG, with a per-partition count at INFO.

### 4. Tests

**File:** `ouestcharlie-py-toolkit/tests/test_video.py`

Synthesize the pair with the existing video helper (a small `mpeg4` MP4 at
64×48) and a PIL-written JPEG with EXIF.

- `test_preview_candidates_same_stem_case_insensitive`: `a.MOV` + `a.jpg`
  pair up; `a.MOV` + `b.JPG` don't; `a.MOV` + `a.MP4` + `a.JPG` don't
  (ambiguous).
- `test_is_video_preview_matching_size`: 64×48 JPG → True; 48×64 → True
  (rotated); 640×480 → False (Live Photo-like).
- `test_is_video_preview_unreadable_jpg_is_false`.
- `test_extract_metadata_fills_camera_from_preview`: the video has no
  make/model; the preview's EXIF provides them; the video keeps its own
  hash, media type, dimensions and duration.
- `test_extract_metadata_video_values_win`: a field the video has is not
  overwritten by the preview.

**File:** `ouestcharlie-whitebeard/tests/test_indexer.py`

- `test_video_preview_jpg_not_indexed`: `clip.mp4` + matching `clip.jpg` → one
  row, the video, and no sidecar for the JPG.
- `test_live_photo_like_pair_indexes_both`: a large JPG + a small video with
  the same stem → two rows.
- `test_existing_preview_row_removed_incrementally`: index a pair with the
  pairing disabled (patch the helper), then run an ordinary incremental index:
  only the video row remains.
- `test_deleting_video_reindexes_preview_as_photo`: delete the video; the next
  run indexes the JPG as a photo.

### 5. Documentation

- `ouestcharlie-py-toolkit/py_toolkit_LLD.md`: pairing rule, confirmation by
  pixel size, and the enrichment table.
- `ouestcharlie-whitebeard/whitebeard_LLD.md`: preview JPGs are excluded from
  the indexable files, and existing rows are removed by the deleted-file path.
- `HLD.md` (media section): a video's preview JPG is treated as metadata of
  the video, as Lightroom does. Live Photos are not affected.

---

## Verification

1. From `ouestcharlie-py-toolkit/`: `uv run pytest tests/test_video.py -v`;
   from `ouestcharlie-whitebeard/`: `uv run pytest tests/test_indexer.py -v`.
2. On a folder with video + preview JPG pairs, run an incremental
   `index_library`, then query Lance: one row per pair, `media_type = "video"`,
   and no JPG row.
3. Re-index that folder with `force_extract_exif=True`: the video rows get
   `camera_make`/`camera_model` from the previews.
4. On a folder with Live Photos (JPG + MOV): both files still have a row.
5. Open the gallery on the pair folder: one video tile per pair; the preview
   shows the video's metadata.

---

## Open points

- **`date_taken` conflict:** older cameras often write the container's
  `creation_time` in local time labelled as UTC, while the JPG's
  `DateTimeOriginal` is local time with no zone. Proposal: when the video's date
  comes only from `creation_time` (no Apple creation date, no GPS or filename
  offset), take the JPG's `DateTimeOriginal` and resolve its zone the way
  photos do. To confirm on sample files before implementation.
- **Enriching already indexed videos:** existing video sidecars are reused, so
  they are enriched only on a forced re-extract. Should the indexer re-extract
  a video once when it finds a newly confirmed preview? That needs a marker in
  the sidecar (e.g. `ouestcharlie:previewFile`) to avoid doing it every run.
- **Poster frame:** the video thumbnail uses a frame decoded ~10% into the
  clip. The preview JPG is the camera's own choice of poster; it could be used
  instead, which is cheaper than decoding (old MJPEG `.MOV` files are large).
- **Sorting skills:** the photo-sorting skills move media into per-event
  folders. They must move a video and its preview JPG together, or the pair
  splits and the JPG reappears as a photo.
