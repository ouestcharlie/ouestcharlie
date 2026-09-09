# OEC-57: AVI video support (indexing + transcoded playback)

#status:draft

Status flow: draft (write spec) -> open (review spec) -> todo (spec validated) -> ongoing (implementation started) -> done (merged)

## Context

OEC-39 (video support design) scoped V1 to MOV and MP4 only, explicitly listing AVI
as out of scope alongside MKV/WebM (`39_videoSupport.md` §1). AVI support is now
wanted, and unlike MOV/MP4 it cannot reuse the transcode-free playback approach:
browsers do not play AVI natively, so making AVI videos playable in the gallery
requires a transcode step, not just cover-frame extraction.

This issue extends the OEC-39 design rather than replacing it — indexing,
identity-hashing, and data-model handling should follow the same pattern as
MOV/MP4 wherever AVI allows it, with transcoding as the one genuinely new piece.

---

## Changes

### 1. Extension/format scope

**File:** `ouestcharlie-py-toolkit/src/ouestcharlie_toolkit/video.py` (or wherever
`VIDEO_SUFFIXES` lands from OEC-39's implementation)

Add `.avi` to `VIDEO_SUFFIXES`. AVI is a container, not a codec — actual codec
support (DivX/Xvid/MPEG-4 Part 2, MJPEG, etc.) is whatever PyAV/ffmpeg was built
with, same "no hardcoded codec allow-list" stance as OEC-39 §1.

### 2. Cover-frame extraction and identity hash

Reuse the existing PyAV-based `extract_cover_frame()` and
`video_identity_hash()` from OEC-39 §2/§3 — AVI is just another container PyAV
can open. Confirm during implementation whether AVI's header/index structure
(the `idx1`/`movi` chunks, AVI's rough equivalent of MOV's `moov` atom) is
suitable for the same bounded-read header-hash approach, or whether AVI's
identity hash needs a container-specific header extractor.

### 3. Transcoding for playback — PyAV remux/encode, not a separate ffmpeg dependency

**New:** a transcode step producing a browser-playable MP4 (H.264 + AAC) rendition
of each AVI source, since — unlike MOV/MP4 — the original AVI stream cannot be
range-streamed to a `<video>` element. This stays within the project's existing
`av` (PyAV) dependency — no new `ffmpeg` CLI/subprocess dependency — since PyAV
already bundles ffmpeg's `libav*`/`libsw*` libraries and exposes both decode
(used today in `video.py`/`preview_builder.py`/`thumbnail_builder.py`) and
encode/mux, which this issue is new in using. Concretely, using PyAV's own API
(mirroring the [PyAV transcoding example](https://pyav.org/docs/stable/cookbook/basics.html)):

- Open the AVI with `av.open(local_path)` (input container), and open a new
  in-memory or temp-file MP4 with `av.open(dest, mode="w")` (output container).
- For each input video packet: decode via the existing input video stream, then
  encode into an output stream created with `output.add_stream("h264", ...)`
  (libx264 via PyAV's `av.CodecContext`) — this is a real re-encode (pixel-accurate
  decode → H.264 encode), not a stream copy/remux, since AVI's legacy codecs
  (DivX/Xvid/MPEG-4 Part 2, MJPEG) aren't browser-playable in *any* container.
- If the source has an audio stream, transcode it too via `output.add_stream("aac", ...)`
  — silently drop audio only if PyAV reports no audio stream, not on encode failure.
- Flush/mux remaining packets and close both containers when done.
- This is CPU-bound, full-file work (unlike the O(1) cover-frame decode in
  OEC-39 §2) — cost and duration scale with video length/resolution, which
  drives the eager-vs-lazy question below.

Open design questions to resolve before implementation:
- **When**: three options, not two —
  1. **Eager**, at index time, stored alongside the manifest. Avoids
     request-time latency but costs storage and indexing time across the
     library — full-file PyAV transcode, not the bounded cover-frame decode
     OEC-39 budgeted for indexing.
  2. **Lazy, cached**: transcode on first playback request, persist the
     result so later views are served straight from storage. Avoids upfront
     indexing cost but adds transcode latency to the first view and needs a
     transcode cache (complicates the stateless-agent model, HLD.md).
  3. **Live/no persisted rendition**: transcode on every request, streaming
     encoded output directly into the HTTP response as it's produced (PyAV
     decode → encode loop writing to a fragmented-MP4 output container —
     `movflags=frag_keyframe+empty_moov` so the muxer never needs to seek
     back to patch the `moov` atom, letting bytes flow out via chunked
     transfer with no fixed `Content-Length`). This is the only option with
     **zero storage** and nothing to invalidate/GC when the source changes,
     but it trades away real capabilities the other two keep for free:
     - **No HTTP Range support** → no scrubbing/seeking in the `<video>`
       element, since output size is unknown upfront and byte N of the MP4
       doesn't correspond to a fixed offset into the source. A seek would
       have to be implemented as "restart the request with a `?t=` param,
       re-open the input container, `container.seek()` to that timestamp,
       and begin a fresh transcode from there" — functional but coarse
       (only keyframe-accurate, and each scrub redoes work from that point).
     - **Repeat cost**: re-transcodes from scratch on every request, so N
       viewers (or one viewer reloading) means N full transcodes — no reuse
       across requests. Live transcode is worth considering only for
       AVI's likely-rare/one-off viewing pattern, and only if storage cost
       genuinely outweighs the CPU/latency cost of re-transcoding on demand.
     - **Real-time-rate risk**: the transcode must keep up with playback
       rate on modest hardware (Wally's host, possibly cloud-mounted-drive
       read latency added on top) or the viewer stalls/buffers.
- **Where**: which component owns the transcode (Wally's streaming endpoint,
  a dedicated agent, or an indexing-time job) — must respect "keep agents
  stateless" (CLAUDE.md) and "storage-agnostic" constraints. Option 3 above
  fits Wally's streaming endpoint most naturally (transcode-as-you-serve);
  options 1–2 could live in an indexing job or a first-request cache-fill.
- **Storage of the transcoded rendition**: does it live in the same
  backend/library as the source, or in a separate cache location? Affects
  cleanup/GC story if the source AVI is deleted or re-indexed.

### 3b. Unsupported-codec and no-audio handling

Two distinct failure/degradation modes, both server-side and detectable without
guessing — PyAV either can decode a given stream or raises, there's no partial
"maybe":

- **Video codec PyAV/ffmpeg can't decode at all.** Rare for AVI in practice
  (DivX/Xvid/MPEG-4 Part 2/MJPEG are all standard ffmpeg builds), but the build
  Wally runs on might lack a codec, or the file might be corrupt/use an exotic
  FourCC. This surfaces as `av.error.*` (e.g. `av.error.FFmpegError`, matching
  the existing `contextlib.suppress(av.error.FFmpegError)` pattern already used
  for cover-frame extraction in `video.py`) raised from `container.decode(video=0)`
  — either at indexing time (cover-frame extraction, OEC-39 §2, already has to
  handle this) or at transcode time if it somehow decodes a frame for the cover
  but fails on other frames. Treat this as **no playable rendition exists**, not
  a warning: don't attempt the transcode, don't serve a `<video>` element that
  will 404 or hang.
- **Audio codec fails to transcode but video succeeds.** E.g. a legacy AVI audio
  codec (ADPCM variants, etc.) that PyAV can decode but the AAC encoder path
  errors on, or an audio stream PyAV can't decode at all. Distinct from "no audio
  stream present" (§3, `has_audio: false`, nothing to transcode, not an error).
  Here there **is** an audio stream but transcoding it fails — fall back to a
  video-only rendition (drop the audio stream, keep the video stream; PyAV lets
  you mux an output with only the video `add_stream` call) rather than failing
  the whole transcode over an audio-only problem.

**New schema field** (`ouestcharlie-py-toolkit/src/ouestcharlie_toolkit/schema.py`,
`PhotoEntry`): `video_playable: bool` (or a small enum if a future format needs
more than boolean, e.g. `Literal["playable", "unsupported"]`) — set at index/
transcode time, persisted in the manifest so the gallery doesn't need to probe
per-request. `has_audio` already exists (OEC-39 §3) and continues to mean
"source has an audio stream"; it does **not** get overloaded to mean "audio
transcode succeeded" — if that distinction matters for the UI, it needs its own
field (e.g. `audio_playable: bool`, defaulting `true` when `has_audio` is
`false`) rather than repurposing `has_audio`.

### 4. Data model

**File:** `ouestcharlie-py-toolkit/src/ouestcharlie_toolkit/schema.py`

`PhotoEntry` already carries `media_type`/`duration_seconds`/`video_codec`/
`has_audio` from OEC-39; §3b above adds `video_playable` (and optionally
`audio_playable`). `video_codec` continues to reflect the *original* legacy AVI
codec (e.g. `mpeg4`, `mjpeg`) for display purposes even when unplayable — the
UI's codec-support warning (OEC-39 §1, #39a/#39b) already distinguishes
"decodable server-side" from "playable client-side"; §3b extends that same
distinction to "not even decodable server-side, no rendition possible."

### 5. UI adaptation

**File:** `ouestcharlie-woof/gallery/src/components/PreviewPanel.svelte`,
`ouestcharlie-wally/src/wally/http_server.py`

The video-stream endpoint from OEC-39 §4 needs to serve the transcoded MP4 for
AVI sources rather than range-streaming the original file. The cover-frame/
thumbnail path is unaffected (same AVIF grid pipeline as any other video) —
even an unplayable video still has a cover frame if PyAV managed to decode at
least one frame during indexing, so the grid tile and preview thumbnail keep
working regardless of `video_playable`.

- **`video_playable: false`**: `PreviewPanel.svelte` must check this field
  (from the search result, no request needed) and skip rendering a `<video>`
  element entirely — show a message ("playback not supported for this file")
  next to the still cover frame instead, mirroring how OEC-39 §1's HEVC warning
  is surfaced but stronger (that one still renders a `<video>` that *might*
  work; this one is a definite no). The video-stream endpoint should reject
  requests for such content (404 or 4xx) rather than attempt a transcode that's
  known to fail.
- **Audio absent or unplayable**: the `<video>` element itself handles a
  video-only MP4 correctly (no special client code needed — it just has no
  audio track). Surface this as informational only where the UI already shows
  audio presence (OEC-39 §3b/details panel, #39b) — e.g. "no audio" vs a
  distinct "audio unavailable" state if `audio_playable` is added, so a viewer
  doesn't mistake a failed audio transcode for a genuinely silent source clip.

### 6. Tests

**File:** `ouestcharlie-py-toolkit/tests/`

- AVI fixture indexing: metadata extraction, cover-frame extraction, identity
  hash stability across re-index.
- Transcode path: verify a transcoded MP4 is produced/served and is decodable.

### 7. Documentation

- `HLD.md`: extend the video data-model section (added by OEC-39's
  implementation) to note AVI's transcode requirement.
- `project/OpenPoints.md`: resolve or update the AVI-out-of-scope note left by
  OEC-39.

---

## Verification

- Index a library containing `.avi` files: confirm entries appear with
  `media_type: "video"`, correct duration/codec metadata, and a cover-frame
  thumbnail.
- Play an AVI video from the gallery UI: confirm it plays via the transcoded
  rendition (not the original AVI stream).
- Re-index the same library: confirm `content_hash` is stable for unchanged
  AVI files.
