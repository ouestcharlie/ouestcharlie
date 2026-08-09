# OEC-39b: Preview details side panel — video adaptations

#status:done

## Context

#42 added the gallery preview's collapsible **details side panel** (three
subpanes: Overview, Camera, Location) and the always-visible **caption bar**,
built entirely from photo `match` fields. #39/#39a designed video support:
`PreviewPanel.svelte` branches on `match.mediaType` to render a `<video>`
instead of an `<img>`, and the schema gains `mediaType`, `durationSeconds`,
`videoCodec`, and `hasAudio` (#39 §3).

This issue covers how the details panel and caption bar adapt when the item
is a **video**. #42 built the panel around EXIF-photo semantics (make/model,
lens, ISO, aperture…), most of which are meaningless for video. Rather than
show empty camera-photography rows, the panel should surface the video-only
fields #39 introduced. This is a **frontend-only** change layered on top of
both #42 (panel) and the #39/#39a video work — it does not land until those do.

### What data is available for a video?

From #39's schema additions, a video `match` carries, in addition to the shared
fields (`description`, `tags`, `dateTaken`, `filename`, `partition`, `width`,
`height`, `gps`, `contentHash`):

- `mediaType === "video"`
- `durationSeconds` (float)
- `videoCodec` (e.g. `"h264"`, `"hevc"`)
- `hasAudio` (bool)

Container-level capture metadata (iPhone MOVs) may populate `make`/`model` and
`gps` from the QuickTime tags #39 §2 maps into the shared dict — but the
lens/ISO/aperture/exposure/focal-length group is **photo-only** and absent for
video.

---

## Changes

### 1. Details side panel — media-type branching

**File:** `woof/gallery/src/components/PreviewPanel.svelte`

- **Overview subpane**: unchanged fields (description, tags as pills, date
  taken, filename, partition, dimensions W×H). Add, when
  `mediaType === "video"`:
  - **Duration** — `formatDuration(match.durationSeconds)` (mm:ss; reuse the
    helper #39a §3 already introduces for the metadata line rather than adding a
    second formatter).
- **Camera subpane → conditional**:
  - For photos: unchanged (make/model/lens/ISO/aperture/exposure/focal length).
  - For videos: the photography rows (lens, ISO, aperture, exposure time, focal
    length, 35 mm equiv.) do not apply — **do not render them**, even if some
    stray value leaks through. Instead show a **"Video" subpane** with:
    `videoCodec`, `hasAudio` (render as "Audio: yes/no" — a boolean, so mirror
    the `{#if match.field != null}` presence check, not `{#if match.field}`,
    since `false` is a real value), and capture `make`/`model` **only if
    present** (iPhone container tags). Keep the existing per-row presence
    pattern from #42.
  - **Codec display + playability hint.** Render `videoCodec` with a
    human-friendly label rather than the raw ffmpeg name (`"h264"` → "H.264",
    `"hevc"` → "H.265 / HEVC", else the raw value). Because V1 does not
    transcode (#39a §1), an HEVC source may index and thumbnail fine yet fail to
    play in the current browser (#39 "Codec landscape"). Detect this with the
    standard `document.createElement('video').canPlayType('video/mp4;
    codecs="hvc1"')` probe (returns `""` when unsupported) and, when the source
    codec is unplayable, show a small inline note next to the codec row (e.g.
    "This browser may not be able to play H.265 video"). This keeps a failed
    `<video>` from looking like a broken app. Keep the probe in the
    `<script>` block (no inline JS, project rule); it's a pure capability check,
    no autoplay.
  - Simplest structure: keep one subpane slot, switch its heading
    ("Camera" vs "Video") and body on `mediaType`, so the panel stays a
    three-subpane layout in both cases.
- **Location subpane**: unchanged — GPS may be present for videos (QuickTime
  `com.apple.quicktime.location.ISO6709`, mapped in #39 §2) and degrades the
  same way (#42's "no location data" behavior).

### 2. Caption bar

- No structural change. Description (truncated 100 chars), first 5 tag pills,
  filename, and date already work from shared fields.
- Optionally append duration to the caption bar for videos (`mm:ss`), reusing
  the same `formatDuration`. Keep it out if it crowds narrow-screen layout —
  it's already in the Overview subpane, so this is cosmetic and low priority.

### 3. Theming / layout

No new decisions. The overlay-opt-out theming (dark scrim + white text over
photos, #42 §3) and the responsive bottom-sheet behavior apply identically to
video — the panel floats over the video frame / `poster` exactly as over a
photo. No `z-index` or full-screen change beyond what #42 and #39a already
establish (note the video `controls` chrome sits at the bottom of the frame:
verify the caption bar and native `<video>` controls don't overlap in
full-screen — nudge the caption bar above the controls band if they collide).

### 4. Tests

**File:** `woof/gallery/src/components/PreviewPanel.test.js`

- A `mediaType: "video"` match renders the **Video** subpane (codec, audio,
  duration), not the photo Camera rows (lens/ISO/aperture absent).
- `hasAudio: false` renders "Audio: no" (presence check, not truthiness).
- A video with `gps` populates the Location subpane; without it, empty state.
- A video with container `make`/`model` shows them; without, those rows hide.
- Duration appears in the Overview subpane (mm:ss formatting).
- Photo matches are unaffected — existing #42 cases still pass (Camera subpane
  unchanged for `mediaType` absent / `"photo"`).

### 5. Documentation

- No HLD/LLD/schema change (frontend-only; all fields already scoped in #39 §3).
- If a gallery UI doc exists under `woof/gallery/`, note the video branch of the
  details panel. Don't enumerate fields in prose that duplicate `PHOTO_FIELDS`.

---

## Dependencies

- **#42** (details panel + caption bar) — must be merged; this modifies it.
- **#39 / #39a** (video support) — must be merged; this relies on `mediaType`,
  `durationSeconds`, `videoCodec`, `hasAudio` reaching the browser and on
  `PreviewPanel.svelte` already branching on `mediaType` for the `<video>`
  render.

---

## Verification

- `cd woof/gallery && npm run test` — new video panel cases pass; #42 photo
  cases unchanged.
- Manual, via the gallery embedded in an MCP client:
  - Open a video with rich container metadata (make/model + GPS): Overview shows
    duration; the Video subpane shows codec + audio flag + make/model; Location
    populates.
  - Open a video with no GPS and no capture tags: Video subpane shows codec +
    audio only; Location shows empty state; no photo-EXIF rows appear.
  - Toggle full screen: panel, caption bar, and native video controls stay in
    bounds and don't overlap.
  - Confirm a photo's preview is visually identical to pre-#39b (no regression).
