# OEC-39: Video support in Woof (high-level design)

#status:done

## Context

OuEstCharlie currently handles photos only (JPEG/HEIC/etc., see #30). Per `HLR.md`
("A photo or video library is a collection of media files and the associated
metadata"), video was always in scope but never designed. This issue lays out the
high-level design for adding MOV/MP4 support: format scope, extraction approach,
data model changes, media identity strategy, and UI adaptation. It is a **design**
issue — implementation is tracked separately once this is reviewed.

Key constraint driving the design: videos can be large (GB-scale on cloud-mounted
drives), so the existing photo approach of hashing full file bytes for identity
(`hashing.py::content_hash`, BLAKE3 over raw bytes) is not viable — it would require
downloading and hashing entire files over the network for every indexing pass.

---

## 1. Formats/containers to support

- **V1 scope**: MOV (QuickTime, common from iPhone) and MP4 (H.264/H.265/HEVC).
- Codec support is whatever PyAV/ffmpeg can decode for cover-frame extraction — no
  hardcoded codec allow-list beyond that.
- New extension set analogous to `HEIF_SUFFIXES` in `photo.py`:
  `VIDEO_SUFFIXES = {".mov", ".mp4"}`, used the same caller-driven way as
  `Backend.local()`'s `suffixes` filter (`backend.py`).
- **Out of scope for V1**: AVI, MKV, WebM, and Live Photos (paired HEIC+MOV — see
  open points below).

### Codec landscape (two separate concerns)

Container (MOV/MP4) and video codec are independent axes, and they matter at two
different stages that should not be conflated:

- **Extraction/indexing** (server-side, PyAV/ffmpeg): decoding a single cover
  frame. Here the codec allow-list is effectively "anything ffmpeg was built
  with", which for a standard build covers H.264 (AVC), H.265 (HEVC), VP9, AV1,
  and legacy codecs. This is a superset of what browsers can play back.
- **Playback** (client-side, the `<video>` element, #39a): the browser must
  itself decode the *original* stream, since V1 does not transcode (§4, #39a §1).
  This set is **narrower** and depends on OS/browser:
  - **H.264 (AVC)** in MP4 — universally playable; the safe baseline.
  - **H.265 (HEVC)** in MOV/MP4 — the common iPhone codec, but browser support
    is uneven (Safari yes; Chrome/Edge only with OS/hardware HEVC support;
    Firefox often no). This is the main real-world gap, since iPhone captures
    default to HEVC.
  - **AV1 / VP9** — decodable server-side but unlikely as source material from
    the target photo-library use case; playable in most modern browsers if
    encountered.

The practical consequence: a video can index and thumbnail perfectly (server
decoded its cover frame) yet fail to *play* in a given browser (client can't
decode HEVC). The `videoCodec` field (§3) exists partly so the UI can warn about
this rather than showing a silently broken player — see #39a §1 and #39b.

## 2. Extraction — PyAV

- Add `av` (PyAV) as a dependency in `ouestcharlie-py-toolkit/pyproject.toml`,
  mirroring how `pillow-heif`/`Pillow` were added in #30.
- New `video.py` module in `ouestcharlie_toolkit` (parallel to `photo.py` rather than
  extending `Photo`, since video extraction differs enough from EXIF-based photo
  extraction to warrant its own class):
  - `extract_metadata()`: `av.open(local_path)`, read `container.duration`,
    `streams.video[0].codec_context.name`, `.width`, `.height`, `.average_rate` (fps),
    audio-stream presence/codec if any, and container-level tags
    (`container.metadata` — iPhone MOVs commonly carry `creation_time`, GPS via
    `com.apple.quicktime.location.ISO6709`, `com.apple.quicktime.make`/`model`).
  - `extract_cover_frame() -> PIL.Image`: decode a single frame (recommend ~10% into
    the video rather than frame 0, to avoid black/transition frames) via
    `container.decode(video=0)`, convert via `frame.to_image()`. This is the only
    frame ever decoded — no full-video decode, no audio decode.
  - `read_container_header() -> bytes`: locate and read the `moov` atom (bounded, see
    §3) — the header input to `video_identity_hash`. Uses the backend file handle
    directly (atom-size scan + seek), independent of PyAV's decode path.
  - Map overlapping fields into the same `XmpSidecar`-shaped dict used for photos
    (`date_taken`, `gps`, `camera_make`, `camera_model`, `width`, `height`); new
    video-only fields go into the schema additions below. **Time is special**:
    container `creation_time` is UTC, whereas `date_taken` is naive local wall-clock —
    do not map it directly. See OEC-39e for the offset-resolution precedence that
    converts it to local before writing `date_taken` (and populates `date_taken_utc`).
- Cost profile: opening a container and reading one frame is roughly O(1) relative to
  file size for MP4/MOV (reads the moov atom + first needed keyframe), unlike a
  full-file hash which is O(file size) — this is what makes PyAV-based extraction
  viable at 10K-media scale on cloud-mounted drives.

## 3. Data model changes — `ouestcharlie-py-toolkit/src/ouestcharlie_toolkit/schema.py`

- **Video identity (`content_hash`)**: new
  `video_identity_hash(header_bytes: bytes, cover_frame: PIL.Image) -> str` reusing
  `hashing.py::content_hash` (BLAKE3, same 22-char truncated base64url output as the
  photo hash), computed over **two** inputs concatenated:
  1. **The container header bytes** — for MP4/MOV this is the `moov` atom (the
     "video header": container/stream metadata plus the sample tables `stco`/`stsz`/
     `stts`, which encode per-frame offsets/sizes/timing and therefore fingerprint the
     exact edit/encode, not just coarse scalars). Located by scanning top-level atoms:
     read each atom's 8-byte size+type header from the start of the file, seek past
     `ftyp`/`mdat`/etc. until the `moov` atom, and read exactly its bytes. This is a
     bounded read (atom-header scan + one `moov` slice), not a full-file read — `mdat`
     (the actual media payload, the GB-scale part) is skipped entirely.
  2. **The decoded cover-frame pixels** — the raw RGB bytes of the frame already
     extracted for the thumbnail (§2), so no extra decode cost. This ties identity to
     visible content, so two files with byte-identical headers but different footage
     (or vice-versa) still differ.
  Rationale for both, not one: the header alone can be re-serialized differently by
  remux tools without changing footage; the frame alone can collide across different
  clips that happen to share a first frame (e.g. same intro card). Hashing both makes
  an accidental collision require matching *both* the full sample-table structure and
  the cover-frame pixels — strong enough to treat as a real identity, not a heuristic
  (see open points, now downgraded from the earlier metadata-scalar approach).
  - **Bounded-cost caveat**: for very long videos the `moov` sample tables can reach a
    few MB. That is still negligible versus the media payload, but cap the header read
    (e.g. 16 MB) and, on the rare overflow, hash the capped prefix — deterministic and
    still far stronger than scalar metadata.
  - **`moov`-at-end caveat**: non-faststart MOV/MP4 place `moov` after `mdat`, so the
    atom scan must follow atom sizes to seek to it rather than assuming a front
    position — this needs a ranged/seeked read of the header region, which the
    backend's `local_path()` file access already supports (see #39a §1 / open points).
- **`PhotoEntry` extended with optional video fields** (kept as one entry type rather
  than a parallel `MediaEntry`, to keep manifest/search code uniform):
  - `media_type: Literal["photo", "video"]` (default `"photo"` for back-compat)
  - `duration_seconds: float | None`
  - `video_codec: str | None`
  - `has_audio: bool | None`
  - existing `width`/`height` reused as-is, populated from the video stream
- **No new "cover" boolean.** Today there is no `is_cover` field anywhere in the
  schema — the only related concept is the AVIF `ThumbnailGridLayout`/`ThumbnailChunk`
  packing (a storage optimization, not a semantic cover flag). Each video has exactly
  one derived cover image, addressed by the video's own `content_hash` — no new field
  is needed. This should be documented explicitly so a future burst/stack-grouping
  feature doesn't conflict with this assumption.
- **`fields.py`**: add `media_type` and `duration_seconds` as searchable/filterable
  `FieldDef`s, following the pattern used for tag facets (#37c).
- Per `CLAUDE.md` ("Don't modify XMP/manifest schemas without updating HLD"), this
  schema change must be accompanied by an `HLD.md` data-model update in the
  implementation issue.

## 4. UI adaptation — `ouestcharlie-woof`

- `gallery/src/components/PhotoGrid.svelte`: render a play-icon overlay when
  `match.mediaType === "video"`. Grid tiling is otherwise unchanged since the video's
  cover frame flows through the existing AVIF grid pipeline like any photo.
- `gallery/src/components/PreviewPanel.svelte`: branch on `mediaType` — photos keep
  the current JPEG `<img>` cross-fade; videos render a `<video>` element pointing at
  a new streaming endpoint, using the cover-frame JPEG as `poster` while it loads.
  Add a duration display alongside the existing EXIF-ish metadata block.
- `gallery/src/lib/api.svelte.js`: add `videoStreamUrl(match)` alongside the existing
  `thumbnailUrl()`/`previewUrl()`.
- **Wally** (`ouestcharlie-wally/src/wally/http_server.py`): new endpoint, e.g.
  `/video/{library}/{partition}/{contentHash}.mp4`, that range-streams the original
  file from the backend so the `<video>` element can seek. This is the largest new
  piece of code implied by this design and may warrant its own implementation issue.
- **Woof HTTP server** (`ouestcharlie-woof/src/woof/http_server.py`): mirror the
  existing thumbnail/preview proxy pattern for the new video-stream route.

---

## Open points

- [ ] **Live Photos** (paired HEIC+MOV): identity/grouping strategy not designed here —
      needs a follow-up decision on whether they're linked entries or independent media.
- [x] **`content_hash` collision risk** — resolved by the header+cover-frame hash
      (§3). Identity is BLAKE3 over the full `moov` atom (sample tables included) plus
      the decoded cover-frame pixels, both bounded-cost inputs we already read/decode.
      An accidental collision now requires matching both the exact sample-table
      structure and the cover-frame pixels — treated as a real identity, not a
      heuristic. Two remaining edge cases, both acceptable for V1: (a) capped header
      read (§3) means two videos identical within the first 16 MB of `moov` and sharing
      a cover frame would collide — vanishingly unlikely; (b) re-encoding a video
      changes both inputs and so produces a new identity (same as photos, where any
      re-encode changes `content_hash`), which is the intended behavior.
- [ ] **Range-request streaming at scale**: is a simple proxy-with-range-support in
      Wally sufficient for 10K-media libraries on cloud-mounted drives, or will it need
      pre-transcoding/HLS in a later iteration?

---

## Verification

This is a design-only issue — no code changes. Verification is that the design above
is reviewed and agreed upon before an implementation issue is opened against it.
