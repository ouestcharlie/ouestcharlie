# OEC-53: Gallery UI fixes (again)

#status:discarded


## Context - issues

### Preview mode in full screen

- Portrait images are show at 100% of the width, leading to a clipped height
- It seems that the image layout is recomputed when switching to the next image. 
- If the next image is also a portrait it might be well displayed

### Preview within the chat flow

- There are similar layout issues
- The height of the window is variable, leading to an empty space between the Gallery UI and the next chat message. The height should be constant

### Indexing progress UI

- Mostly on Windows, the height is not large enough, the bottom of the UI is clipped


---

## Root-cause analysis

All three issues live in the Svelte gallery (`ouestcharlie-woof/gallery`).

### A. Preview sizing (fullscreen portrait clip + recompute-on-navigate)

`PreviewPanel.svelte` sizes `.preview-container` with **three** conflicting rules:

```css
.preview-container {
  aspect-ratio: {aspectRatio};  /* inline style, from match.width/height */
  width: 100%;
  max-width: 100%;
  max-height: 100%;
  flex-shrink: 0;
}
```

When a box has a **definite `width` (100%)** and an `aspect-ratio`, the browser
derives height from width: a portrait (`ar ≈ 0.66`) becomes `viewerWidth / 0.66`
— much taller than the viewer. `max-height: 100%` is supposed to clamp it, but
against `flex-shrink: 0` inside the flex `.viewer` it does not reliably win on
the *first* layout pass, so the image overflows and is clipped by
`.viewer { overflow: hidden }`. Navigating triggers a reflow that re-resolves the
constraint — which is exactly the reported "next portrait may display correctly."

There is no pure-CSS way to tightly fit a box to a container preserving aspect
ratio in **both** orientations (it requires knowing which dimension is the
binding one — a container-query / JS decision). So the container must stop
trying to be aspect-ratio-sized.

### B. Chat-flow (inline) variable height / empty gap

Inline height is a fixed `INLINE_HEIGHTS.gallery = 600` reported from
`App.svelte` — a magic number disconnected from the grid geometry.
`MediaGrid.svelte` already encodes the 3-row content height:
`GRID_MIN_HEIGHT = ROWS*DISPLAY_SIZE + (ROWS-1)*4 + 32 = 3*160 + 2*4 + 32 = 520px`.
Add the surrounding chrome (header ≈ 50, nav-top ≈ 34, nav-bottom ≈ 34,
status ≈ 26 → ≈ 144px) and 3 full rows actually need ≈ **664px**. At 600 the grid
only gets `600 − 144 ≈ 456px` (~2.6 rows), so the last row scrolls and the window
height never matches its content.

**Intent (confirmed with author):** a *fixed* inline height sized to display
exactly **3 rows** of thumbnails, constant while browsing (grid ↔ preview), and
adjusted per platform (macOS vs Windows) since the system-font chrome renders at
slightly different heights. The 160px tiles are platform-independent, so only the
chrome varies.

### C. Indexing view clipped on Windows

Two competing height reports race:
- `App.svelte` reports fixed `INLINE_HEIGHTS.indexing = 280`.
- `IndexingProgress.svelte` reports its measured `rootEl.scrollHeight`.

On Windows the content exceeds 280px (larger default fonts/line-height), and the
App's fixed 280 can be the last `sendSizeChanged` to fire, clamping the iframe and
clipping the bottom (Stop button / summary).

---

## Changes

### 1. Preview container sizing — fill the viewer, let `object-fit` fit

**File:** `gallery/src/components/PreviewPanel.svelte`

Stop sizing the container by `aspect-ratio`; make it fill the viewer and rely on
the already-present `object-fit: contain` on the `<img>`/`<video>`. This removes
the clip and the recompute-on-navigate entirely, with no JS measurement.

```svelte
<!-- Before -->
<div class="preview-container" style="aspect-ratio: {aspectRatio};">

<!-- After -->
<div class="preview-container">
```

```css
/* Before */
.preview-container {
  flex-shrink: 0;
  max-width: 100%;
  max-height: 100%;
  width: 100%;
  /* aspect-ratio applied inline */
}

/* After */
.preview-container {
  width: 100%;
  height: 100%;
}
```

The `aspectRatio` `$derived` (and its inline usage) can then be deleted.

**Trade-off:** caption/nav/info overlays now span the full viewer rectangle
(including letterbox bars) rather than hugging the image edges. This is standard
lightbox behavior and stable across orientations.

**Alternative (tight-wrap, if hugging the image is required):** keep the crossfade
"base" image (`shownUrl`) in normal flow with `max-width/max-height: 100%;
width/height: auto` so it drives the container size, and keep only the *incoming*
image absolutely positioned. The container then wraps the fitted image exactly in
both orientations, pure-CSS, at the cost of a brief transient during crossfade.

### 2. Constant inline height = 3 thumbnail rows, measured once, platform-correct

**File:** `gallery/src/App.svelte`

Replace the magic `600` with a height derived from the real rendered layout,
measured **once** at gallery mount and cached for the whole session — so it is a
*fixed* constant (never re-fires per content or per view), automatically correct
on both macOS and Windows because it uses the actual system-font chrome.

The grid already reports its 3-row content via `GRID_MIN_HEIGHT` (`flex: 1`
collapses it to exactly that when there is no surplus space), so a one-time
`scrollHeight` measurement of `.app` in grid view captures `chrome + 3 rows`
without any hand-tuned pixel sums.

```js
// Before — magic number, wrong (only ~2.6 rows fit), platform-blind
const INLINE_HEIGHTS = { gallery: 600, indexing: 280 };
$effect(() => {
  if (!modeKnown || !mcpApp || !mcpReady || isFullscreen) return;
  notifyHostHeight(mcpApp, INLINE_HEIGHTS[mode] ?? 400);
});

// After — measured once in grid view, cached, reused for grid AND preview
let galleryHeight = $state(null); // cached fixed height for the session
let appEl = $state(null);         // bind:this on the .app / gallery root

$effect(() => {
  if (mode !== 'gallery' || !modeKnown || !mcpApp || !mcpReady || isFullscreen) return;
  if (galleryHeight == null && appEl && view === 'grid' && !loading) {
    // Measure once, after the grid has laid out its 3 rows.
    requestAnimationFrame(() => {
      if (galleryHeight != null) return;
      galleryHeight = appEl.scrollHeight; // chrome + GRID_MIN_HEIGHT, real fonts
      notifyHostHeight(mcpApp, galleryHeight);
    });
  } else if (galleryHeight != null) {
    notifyHostHeight(mcpApp, galleryHeight); // constant across grid ↔ preview
  }
});
```

Notes / guards:
- Measure only when `view === 'grid'` and `!loading`, so preview or the loading
  skeleton never sets the cached value (preview would vary with portrait vs
  landscape — the value must come from the grid).
- Because the grid is `flex: 1` with `min-height: GRID_MIN_HEIGHT`, the measured
  height equals `chrome + 3 rows` regardless of how many results loaded — a small
  result set no longer collapses the window.
- Preview reuses the same cached `galleryHeight`, keeping the window constant
  while browsing.
- Indexing height is handled separately in change 3 (measured by
  `IndexingProgress`), so it is removed from `INLINE_HEIGHTS`.
- Reuse the existing `notifyHostHeight` helper from `lib/hostSize.js`; no new host
  API is needed.

**Rejected alternatives:** a fully-computed `GRID_MIN_HEIGHT + CHROME +
PLATFORM_PAD` constant (brittle — the `CHROME` sum breaks whenever header/nav/
status styling changes); measuring per view (breaks the "constant while browsing"
requirement — preview height would track image orientation).

### 2b. Center-align the thumbnail grid

**File:** `gallery/src/components/MediaGrid.svelte`

The grid is a `flex-wrap` row defaulting to `justify-content: flex-start`, so
tiles pack against the left and the leftover space becomes an uneven right margin.
Center the rows so left and right margins are identical:

```css
/* .grid */
.grid {
  /* …existing… */
  justify-content: center;
}
```

Note: with `align-content: flex-start` retained, rows still start at the top;
only the horizontal distribution changes. The column count math
(`Math.floor((gridWidth + 4) / TILE_STRIDE)`) is unaffected — `justify-content`
only distributes the surplus width that was previously all on the right.

### 3. Indexing height — single source of truth

**File:** `gallery/src/App.svelte`

Let `IndexingProgress` own its height (measured) and stop the App from also
reporting a fixed 280 for indexing, removing the race that clips on Windows.

```js
// Before
const INLINE_HEIGHTS = { gallery: 600, indexing: 280 };
$effect(() => {
  if (!modeKnown || !mcpApp || !mcpReady || isFullscreen) return;
  notifyHostHeight(mcpApp, INLINE_HEIGHTS[mode] ?? 400);
});

// After — only the gallery declares a fixed height; indexing is measured
// by IndexingProgress.notifyHostMeasured().
const INLINE_HEIGHTS = { gallery: 600 };
$effect(() => {
  if (!modeKnown || !mcpApp || !mcpReady || isFullscreen) return;
  if (mode === 'indexing') return; // IndexingProgress reports its own scrollHeight
  notifyHostHeight(mcpApp, INLINE_HEIGHTS[mode] ?? 400);
});
```

Also add a small bottom safety so the measured height never crops the last row on
Windows: keep `box-sizing: border-box` (already set) and ensure the measured
`scrollHeight` includes the `.stop-row` padding (it does). Optionally add a few px
of bottom padding to `.indexing` as a cushion.

Update `hostSize.js`'s module comment: indexing is now a measured (not fixed) view.

### 4. Tests

**Files:** `gallery/src/components/PreviewPanel.test.js`,
`gallery/src/components/IndexingProgress.test.js`, `gallery/src/App.test.js`

- PreviewPanel: assert the container no longer carries an `aspect-ratio` inline
  style and that `<img>`/`<video>` keep `object-fit: contain` (wiring only — the
  fit itself is a browser concern).
- App/indexing: assert that in `indexing` mode the App does **not** call
  `sendSizeChanged` with a fixed 280 (only `IndexingProgress`'s measured call
  fires). Reuse the `fetch`-mock + `waitFor` pattern from `IndexingProgress.test.js`.

### 5. Documentation

- `gallery/src/lib/hostSize.js` — update the header comment: indexing is measured.
- No HLD/LLD data-model change (pure UI/layout). If `INLINE_HEIGHTS` policy
  changes, note it wherever the inline-height rationale is recorded.

---

## Verification

- `cd gallery && npm test` — all component/lib suites pass.
- Manual (Claude Desktop, macOS + Windows):
  - **Fullscreen preview:** open a portrait as the *first* image → it fits within
    the viewer height with no clipping, before any navigation.
  - **Inline preview in chat:** portrait and landscape both fit; the gallery block
    keeps a constant height with no empty gap before the next chat message.
  - **Indexing on Windows:** the Stop button (running) and the summary card
    (completed, with the errors `<details>` expanded) are fully visible, not
    clipped at the bottom.
