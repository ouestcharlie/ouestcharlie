# OEC-39a: Video support — MCP server and frontend low-level design

#status:done

## Context

#39 laid out the high-level design for video support (formats, PyAV extraction,
metadata-based `content_hash`, schema additions). This issue drills into the two
areas #39 left at "needs its own design": how the **MCP servers** (Woof, Wally) expose
video streaming end-to-end, and how the **gallery frontend** plays video inline in
`PreviewPanel.svelte`. It also documents the two Range-request gaps #39 flagged as the
largest unknowns (Wally has no Range support at all today; Woof's proxy buffers whole
bodies).

---

## 1. Wally — video streaming endpoint

Wally's `MediaMiddleware.__call__` (`ouestcharlie-wally/src/wally/http_server.py`)
dispatches purely on path prefix (`/previews/`, `/thumbnail/`). Add a third prefix,
`/video/`, handled by a new `_handle_video` method following the same
`{backend_name}/{partition}/{file}` path-parsing convention as `_handle_preview`/
`_handle_thumbnail`.

Unlike previews/thumbnails, video is **not pre-generated content** (no derived
AVIF/JPEG asset to look up) — it streams the original file straight from the backend,
resolved by `content_hash` → filename via the same LanceDB lookup `_generate_preview`
already does (query by `content_hash` + `partition`).

**Range support is new work, required here** (photos never needed it since
thumbnails/previews are small pre-generated JPEGs served whole-body). Needed because
`<video>` seeking sends `Range: bytes=...` requests; without honoring them, playback
can only ever restart from byte 0.

- Parse the incoming `Range` header (single-range form, `bytes=start-end`, per
  RFC 7233 — no multipart-range support needed for V1, browsers don't request it for
  `<video>`).
- Resolve the file via `await backend.local_path(path)` (same call
  `_generate_preview` already makes) and range-read it with plain file I/O
  (`open`/`seek`/`read`) — no new `Backend` protocol method needed, since both
  existing backends (`local.py`, `cloud_mount.py`) are filesystem-path-based (see
  open points).
- Respond `206 Partial Content` with `Content-Range`, `Content-Length` (of the slice),
  `Accept-Ranges: bytes`; respond `200` with the full stream when no `Range` header is
  present (initial `<video>` metadata probe often does a small ranged request first —
  verify against real browser behavior during implementation).
- No transcoding — served as the original container/codec. If a browser can't decode
  the source codec (e.g. some HEVC-in-MOV cases), playback fails client-side; out of
  scope for V1 per #39's open point on possible future transcoding/HLS.

**Codec-precise `Content-Type` (matters for playback, not just container).** The
open point below resolves container→mimetype (`.mp4`→`video/mp4`,
`.mov`→`video/quicktime`), but note the container mimetype alone does **not**
tell the browser which codec is inside. Browsers decide playability from a codec
parameter, e.g. `video/mp4; codecs="avc1.640028"` (H.264) vs
`codecs="hvc1"`/`codecs="hev1"` (HEVC). V1 does **not** attempt to build the
precise `codecs=` string (it requires reading profile/level from the stream and
is error-prone) — Wally sends the bare container type and lets the browser probe
the actual bytes, which is correct and self-consistent. The consequence is that
the *server* cannot cheaply predict playability from the `Content-Type`; that
signal lives in the `videoCodec` field instead (surfaced to the UI per #39b),
which is why HEVC playback failures are handled as a UI concern (a warning),
not a server-side reject.

## 2. Woof — HTTP proxy and MCP tool surface

**HTTP proxy** (`ouestcharlie-woof/src/woof/http_server.py`): the existing catch-all
route `/{kind}/{library}/{rest:path}` → `proxy_media` already matches `kind="video"`
with zero routing changes. However, `proxy_media`'s current implementation
(`client.get(...)` then `Response(content=upstream.content, ...)`) **buffers the full
response body** before forwarding — fine for JPEG thumbnails, wrong for video: it
would defeat the whole point of Range support (Wally would still stream a 206
correctly, but Woof would buffer that chunk fully before replying, which is
acceptable for a single ranged chunk, but the proxy must also **forward the
`Range` request header** to Wally and **relay `206`/`Content-Range`/`Accept-Ranges`**
response headers, which the current `proxy_media` does not do — it only forwards
`Authorization` upstream and only sets `content-type` downstream (l.152-166)).
Concretely: `proxy_media` needs to (a) forward `Range` if present, (b) pass through
`upstream.status_code` instead of always 200, (c) copy `content-range`/`accept-ranges`
alongside `content-type`.

**MCP tool surface** (`mcp_server.py`): no new MCP tool is needed for video itself —
video items flow through the existing `search_photos`/`browse_gallery` session
mechanism exactly like photos (the `PhotoMatch`-shaped session payload gains
`mediaType`/`durationSeconds`, see #39's schema additions, surfaced the same way
`avifHash`/`tileIndex` already are). This confirms #39's UI decision: video is
metadata-browsable through the same conversational search path, only the gallery's
rendering branches on `mediaType`. No `get_video`/`get_photo` single-item tool is
introduced, consistent with today's photo behavior (per-item detail is an HTTP fetch
by the gallery, never surfaced back to the model).

`list_search_fields` (proxied from Wally, cached per-library in
`self._library_fields`) automatically exposes `mediaType`/`durationSeconds` once added
to Wally's `PHOTO_FIELDS` (#39, `fields.py`) — no Woof-side change beyond the schema
work already scoped in #39.

## 3. Gallery frontend

**`lib/api.svelte.js`**: add `videoUrl(match)`, structurally identical to
`previewUrl()` — `${origin}/video/{library}/{partition}/{contentHash}.mp4{tokenQueryParam}`
(extension driven by `match.mediaType`/original container, default `.mp4`; MOV sources
still serve as `.mov` — browsers key off `Content-Type`, not the URL extension, so this
is cosmetic). Token passed as `?token=` query param exactly like existing thumbnail/
preview URLs, since `<video src>` can't set an `Authorization` header any more than
`<img src>` can.

**`App.svelte`**: `thumbnailTile()`/session-application logic needs no change —
videos are tiled into the AVIF grid identically to photos via their cover frame
(#39 §4). The only new piece of shared state is passing `mediaType`/`durationSeconds`
through from the session payload into `match` objects (already flows through
generically since `applySession` copies the full searchable payload).

**`PhotoGrid.svelte`**: render a small play-icon overlay (new inline SVG or a
`play-icon.svg` asset, referenced via `<img>`/CSS `background-image` — no inline
`<script>`/`onX`, consistent with project JS rules) positioned absolutely over the
tile when `match.mediaType === 'video'`. No change to the column/pagination math
(`columns`, `displayPageSize`, `TILE_STRIDE`) since tiles remain uniform-size AVIF
grid cells regardless of media type.

**`PreviewPanel.svelte`** — the main new work:
- Branch on `match.mediaType`. Photos: unchanged `<img>` cross-fade path. Videos:
  render `<video controls preload="metadata" poster={coverFrameUrl} src={videoUrl(match)}>`.
  `poster` reuses the existing `previewUrl(match)` (the cover-frame JPEG generated by
  Wally's normal preview pipeline per #39 §4) so the panel shows an image instantly
  while the video buffers/seeks its first frame.
- `aspectRatio = match.width / match.height` logic is reused unchanged (video cover
  frame's dimensions populate `width`/`height` exactly like a photo, per #39 schema).
- Metadata block gains a duration line (`formatDuration(match.durationSeconds)`,
  mm:ss) alongside the existing filename/dateTaken/make/model/tags block.
- Keyboard nav (`ArrowLeft`/`ArrowRight` → `prev()`/`next()`) needs one adjustment:
  switching away from a playing video should pause it (store a ref to the active
  `<video>` element, call `.pause()` in `prev()`/`next()`/on unmount) — otherwise audio
  keeps playing after the user navigates off-screen.
- No autoplay — `controls` + user-initiated play only, consistent with not wanting
  unexpected audio in a gallery browsing flow.

---

## Open points (carried from #39, refined here)

- [x] **Range-read primitive per backend** — checked `Backend` (Protocol,
      `ouestcharlie-py-toolkit/src/ouestcharlie_toolkit/backend.py:71-214`) and both
      implementations that currently exist, `backends/local.py` and
      `backends/cloud_mount.py`. There is no remote-API backend today — both are
      filesystem-path-based (`cloud_mount.py` is a FUSE-mounted cloud drive). Neither
      needs a new offset+length read method on the `Backend` protocol: every backend
      already implements `local_path(path) -> Path` (`backend.py:188-196`), resolving
      to a real path on disk (`local.py:153-155` just returns `self._resolve(path)`;
      `cloud_mount.py` resolves through the FUSE mount point the same way). Wally's
      `_handle_video` can `await backend.local_path(path)` exactly like
      `_generate_preview` already does, then open that path with plain Python file I/O
      (`open(path, "rb")`, `seek(start)`, `read(end - start + 1)`) to serve a 206 —
      no `Backend` protocol change needed for V1.

      This does carry a caveat worth flagging rather than silently assuming away:
      `Backend.local_path()`'s docstring says "Backends that need to fetch the file
      remotely may download it to a temporary location and return that path instead"
      — i.e. the protocol already anticipates a future non-FUSE remote backend where
      `local_path()` downloads the *whole* file before a range read can happen, which
      would defeat the purpose of Range support for that backend (full download either
      way, just deferred to first byte request instead of eliminated). That's fine for
      V1 since no such backend exists, but the moment one is added, seekable range
      reads need revisiting — worth a one-line note in `Backend.local_path()`'s
      docstring when that backend is built, not before.
- [x] **Woof proxy status/header passthrough** — confirmed by direct test against
      `proxy_media`'s exact logic (`http_server.py:141-167`): it uses
      `client.get(url, headers=headers, ...)`, which fully buffers the upstream body
      (`resp.is_stream_consumed` is already `True`, `num_bytes_downloaded` equals the
      full response size, before `proxy_media` builds its `Response`). Worse, the
      `headers` dict it sends upstream only ever contains `Authorization` — the
      incoming request's `Range` header is never read from `request.headers` and never
      forwarded. Net effect: as written today, a `<video>` seek's `Range` request is
      silently dropped, Wally always returns the full file, and Woof buffers the
      entire video into memory before replying. This is not an edge case to verify
      later — it blocks both seeking and reasonable memory use, and must be fixed as
      part of implementation:
      1. `proxy_media` must forward `request.headers.get("range")` upstream when
         present.
      2. `proxy_media` must switch to `client.stream("GET", url, ...)` and stream the
         response body back (`StreamingResponse`) instead of `client.get()` +
         `Response(content=upstream.content, ...)`, so neither Woof nor Wally ever
         holds a full video in memory.
      3. `proxy_media` must pass through `upstream.status_code` (currently it always
         returns whatever Wally sent, which today is always 200 since Wally has no
         206 path yet — once Wally's Range support (§1) lands, 206 needs to flow
         through unchanged) and copy `content-range`/`accept-ranges` headers, not just
         `content-type`.
      This fix is generic to the `/{kind}/...` proxy route, so thumbnail/preview
      traffic (small, whole-file today) is unaffected in practice but benefits from
      the same streaming change for consistency.
- [x] **MOV `Content-Type` handling** — checked `http_server.py`'s two existing
      handlers: both hardcode their `content-type` (`b"image/jpeg"` at l.115,
      `b"image/avif"` at l.182), which works today only because previews/thumbnails
      are always Wally-generated in one fixed format regardless of the source photo's
      original extension. Video breaks that assumption — `_handle_video` serves the
      **original** file, whose container varies per item (MOV vs MP4), so a single
      hardcoded content-type is wrong for at least one of the two formats.
      No mimetype mapping exists anywhere in the codebase today (grepped
      `ouestcharlie-wally`, `ouestcharlie-woof`, `ouestcharlie-py-toolkit` — no hits
      for `mimetypes`/`.mov`/`.mp4`/`quicktime`), so this is new, small code:
      `_handle_video` must derive content-type from the resolved file's suffix,
      e.g. `{".mp4": "video/mp4", ".mov": "video/quicktime"}[suffix]`, keyed off the
      same `VIDEO_SUFFIXES` set introduced in #39 §1 rather than introducing a second
      extension list — a local dict is enough, `mimetypes.guess_type()` is unreliable
      cross-platform for `.mov` (some stdlib builds return `None` or
      `application/octet-stream`) so should not be relied on alone.
      Woof's `proxy_media` already forwards whatever `content-type` Wally sends
      (l.166, `upstream.headers.get("content-type", ...)`), so no Woof-side change is
      needed here beyond what §2's streaming fix already covers — this open point is
      Wally-only.

## Verification

Design-only issue — no code changes. Verification is design review; implementation
lands as a follow-up issue once #39 and #39a are both agreed.
