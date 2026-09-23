# OEC-59: Gallery video playback fixes and better grid alt text

#status:done

Status flow: draft (write spec) -> open (review spec) -> todo (spec validated) -> ongoing (implementation started) -> done (merged)

## Context

Three small gallery UI issues in `ouestcharlie-woof/gallery`:

1. **Bug**: `PreviewPanel` is kept mounted (hidden) when switching to the grid view, to preserve
   image load state. A video that is playing keeps playing (audio included) after the switch,
   because `pauseVideo()` is only called on prev/next navigation and on destroy.
2. **Improvement**: a video shown in preview requires a manual click on play. It should start
   automatically.
3. **Improvement**: grid tile images use the filename as `alt`, which says nothing about the
   content. Use a short, localized datetime so screen-reader users can tell tiles apart.

---

## Changes

### 1. Pause when leaving the preview

**File:** `gallery/src/components/PreviewPanel.svelte`

Add an `$effect` on the `active` prop: when it becomes `false`, call `pauseVideo()`.
`App.svelte` already passes `active={view === 'preview'}`.

### 2. Autoplay in preview

**File:** `gallery/src/components/PreviewPanel.svelte`

In the same effect, when `active` is true and the selected item is a video, call
`videoEl.play()` (swallow the rejection). This covers opening a video from the grid,
navigating prev/next onto a video, and returning from the grid to the preview.
Update the "No autoplay — user-initiated playback only" comment on the `<video>` element.

Open point: browsers and iframe hosts (e.g. an MCP client embedding the gallery) may block
unmuted autoplay, and the `allow="autoplay"` attribute is outside our control. Fallback is
the current behavior: poster shown, controls available. Decide whether to retry muted.

### 3. Grid tile alt text

**File:** `gallery/src/components/MediaGrid.svelte` (tile `<img alt>`)

Build `alt` from the media type and a short datetime, e.g. "Photo, 12 Mar 2026, 14:32".
Fall back to the filename when `dateTaken` is missing. Keep `title={match.filename}`.

- Add a short-date formatter next to `formatDate` (shared format helpers), using
  `Intl.DateTimeFormat` with `dateStyle: 'medium'` and `timeStyle: 'short'` in the active locale.
- Add inlang messages for the "Photo" / "Video" prefix in every locale under `gallery/messages/`.

### 2. Tests

Component tests for `PreviewPanel` (`active` true→false pauses; autoplay calls `play()` for
videos only, never for photos) and `MediaGrid` (alt content with and without `dateTaken`);
unit test for the new formatter.

### 3. Documentation

None expected (UI behavior only). Rebuild `src/woof/gallery/dist` per the existing build flow.

---

## Verification

- `npm test` in `ouestcharlie-woof/gallery`, then rebuild the bundle.
- Manual: open a video in preview and check it plays automatically; switch to the grid and
  check playback stops; return to preview; inspect a grid tile's `alt`.
