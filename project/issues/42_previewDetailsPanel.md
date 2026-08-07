# OEC-42: Gallery preview — collapsible details side panel + image caption bar

#status:done

## Context

The gallery's preview view (`PreviewPanel.svelte`) currently shows the image
with prev/next navigation and a small centered `.meta` block underneath
(filename, date, make/model, comma-joined tags). This wastes most of the
metadata that already reaches the browser and reads poorly on both narrow
screens and full-screen.

This issue enriches the preview with two independent UI pieces:

1. **A collapsible details side panel**, rendered as an overlay on top of the
   image, organized into three subpanes:
   - **Subpane 1 — Overview**: description, tags (as pills), date taken,
     file name, partition, dimensions (W×H).
   - **Subpane 2 — Camera**: make, model, lens, ISO, aperture, exposure time,
     focal length (+ 35 mm equivalent).
   - **Subpane 3 — Location**: GPS coordinates (lat/lon). An embedded map is
     a possible future addition (see caveats), but no placeholder is shown in
     V1 — only the coordinates.

2. **An always-visible caption bar** overlaid at the bottom of the image:
   description (truncated to 100 characters), the first 5 tags as pills,
   filename, and date.

Both must behave correctly in inline mode, full-screen mode
(`isFullscreen`), and on narrow viewports.

### What data is missing from XMP / the index?

**Nothing.** Every field the panel needs is already indexed and already
reaches the browser. Wally's `_match_to_dict` (`wally/agent.py`) iterates
over **all** `PHOTO_FIELDS` and emits each non-null value under its camelCase
`name`. So each `match` object already carries — when present in the source —
`description`, `tags`, `dateTaken`, `filename`, `partition`, `width`,
`height`, `make`, `model`, `lensModel`, `isoSpeed`, `aperture`,
`exposureTime`, `focalLength`, `focalLength35mm`, and `gps` (as a
`[lat, lon]` list), on top of `contentHash` / `avifHash`.

The XMP model (`schema.py: XmpSidecar`) and the Lance schema
(`fields.py: PHOTO_FIELDS`) both already store all of these. No schema, XMP,
index, or Wally change is required — this is a **frontend-only** change.

Two caveats, both out of scope here:
- **GPS is only present if the source photo carried EXIF GPS.** Many photos
  have none; the Location subpane must degrade gracefully (hide, or show
  "No location data").
- **No reverse-geocoded place name is stored** (only raw lat/lon). The future
  map subpane will need either client-side geocoding or a new stored field —
  tracked separately, not in V1 of this panel.

---

## Changes

### 1. Details side panel + caption bar

**File:** `woof/gallery/src/components/PreviewPanel.svelte`

- Add a collapsible side-panel overlay (toggle button, e.g. an "info" icon in
  the viewer corner; default collapsed). Panel state is local component
  `$state` — no persistence needed for V1.
- Render the three subpanes from the existing `match` fields. Only show a row
  when its value is present (mirror the current `{#if match.field}` pattern).
  Reuse the existing `formatDate` helper for `dateTaken`.
- Render tags as pills (shared pill style — factor a `.pill` class; the
  caption bar reuses it).
- Replace the centered `.meta` block with the bottom **caption bar** overlaid
  on the image:
  - Description truncated to 100 chars (append `…` when cut).
  - First 5 tags as pills (`match.tags?.slice(0, 5)`); if more exist, a
    `+N` pill is acceptable but optional.
  - Filename and formatted date.

**Layout / responsiveness (the tricky part):**

- **Overlay, not reflow**: the side panel sits *over* the image
  (`position: absolute`) so the image never resizes when it opens. The
  existing `.preview-container` aspect-ratio sizing stays untouched.
- **Full screen**: verify against `isFullscreen` in `App.svelte`. The panel
  and caption bar must stay within the viewer bounds and above the nav arrows
  (`z-index` above `.nav`, which is currently `z-index: 1`).
- **Narrow screens**: below a breakpoint (~600px) the side panel should become
  a full-width bottom sheet (or full-width overlay) instead of a right rail,
  and the caption bar tags must wrap rather than overflow. Use
  `@media` + flexbox; no JS measurement (consistent with the existing
  comment that layout is CSS-driven).
- Keep overlay text legible over arbitrary photos: semi-transparent dark
  scrim behind the caption bar and panel, matching the existing nav-arrow
  approach (`rgba(0,0,0,…)` regardless of theme).

**Constraint (project CLAUDE.md):** no inline JS / no `onX` inline handlers in
raw HTML — this is Svelte, so keep all logic in the `<script>` block as today.

### 2. Tests

**File:** `woof/gallery/src/components/PreviewPanel.test.js`

- Panel collapsed by default; toggling shows the three subpanes.
- Fields render only when present (e.g. a match with no `gps` hides the
  Location subpane / shows the empty state; a match with no camera EXIF hides
  the Camera rows).
- Caption bar: description truncated at 100 chars; at most 5 tag pills shown.
- Tags render as individual pill elements, not a comma-joined string.

### 3. Theming — host tokens vs. photo overlays (design decision)

The gallery consumes the MCP host's design tokens at runtime via
`applyHostStyleVariables` (from `@modelcontextprotocol/ext-apps`, wired in
`App.svelte`); `global.css` only supplies fallback values for standalone/dev.
The new UI splits deliberately into two zones with respect to those tokens:

- **Structural chrome respects host tokens.** Radii use
  `var(--border-radius-xs, …)`, weights use `var(--font-weight-medium, …)`,
  and all panel text inherits `--font-sans` from the body. These track the
  host theme.
- **Photo-overlay surfaces deliberately opt out.** The caption bar, info
  toggle, tag pills, and details side panel are hardcoded to a dark scrim +
  white text, **regardless of theme** — mirroring the existing `.nav` arrows
  ("keep semi-transparent black regardless of theme"). Rationale: these float
  over arbitrary photographs, where host tokens like `--color-text-primary` /
  `--color-background-secondary` would be unreadable or invisible against the
  image. Honoring the theme tokens there would be a legibility bug, not
  compliance.

**Trade-off accepted:** the details panel does not adopt the host's
light/dark appearance (no light panel in light mode). We chose guaranteed
legibility-over-photos over theme consistency for the overlay layer. A future
theme-adopting panel variant is possible but out of scope here.

### 4. Documentation

- No HLD/LLD/schema change (frontend-only, no data-model impact).
- If a gallery-specific README or UI doc exists under `woof/gallery/`, note the
  new panel there. Do **not** enumerate fields in prose that duplicate
  `PHOTO_FIELDS`.

---

## Verification

- `cd woof/gallery && npm run test` (or the project's configured runner) —
  new `PreviewPanel.test.js` cases pass.
- Manual, via the gallery embedded in an MCP client:
  - Open a photo with rich EXIF (camera + GPS): all three subpanes populate;
    caption bar shows truncated description + ≤5 tag pills + filename + date.
  - Open a photo with no GPS and no camera EXIF: Location/Camera subpanes show
    empty state, no layout breakage.
  - Toggle full screen: panel + caption stay in bounds, above nav arrows.
  - Shrink the window to a narrow width: side panel becomes a bottom sheet /
    full-width overlay; tag pills wrap; body never scrolls horizontally.
