# OEC-53b: Gallery UI fixes (2nd attempt)

#status:done BUT Windows font-size regressions still open, see Verification / Open issues

## Context

First attempt (OEC-53) replaced the preview container's `aspect-ratio` sizing
with `width/height: 100%` + `object-fit`. That **broke rendering** — the preview
showed no image in both chat-flow and fullscreen — because the `<img>`/`<video>`
are absolutely positioned (`inset: 0`) and depend on the container having a
definite, aspect-ratio-derived box. Removing that collapsed the box.

Only the grid center-align survived and is already committed. Everything else was
reverted. This attempt stays **close to the current implementation**: keep the
aspect-ratio container, make small targeted changes.

Current (reverted) state to build on:
- `PreviewPanel.svelte` — `.preview-container { aspect-ratio: <inline>; width: 100%;
  max-width: 100%; max-height: 100%; flex-shrink: 0 }`, images `position: absolute; inset: 0; object-fit: contain`.
- `App.svelte` — fixed `INLINE_HEIGHTS = { gallery: 600, indexing: 280 }`.
- `IndexingProgress.svelte` — also reports its own measured `scrollHeight`.

---

## Remaining issues

### 1. Fullscreen portrait clipped, only fixed after navigating

`.preview-container` pins **width** (`width: 100%`) and derives height from
`aspect-ratio`. For a portrait in a landscape viewer the derived height far
exceeds the viewer; `max-height: 100%` is meant to clamp it but does not reliably
win on the first layout pass against `flex-shrink: 0`, so the image overflows and
is clipped by `.viewer { overflow: hidden }`. Navigating forces a reflow that
re-resolves the clamp — hence "the next portrait may display correctly."

### 2. Chat-flow inline height: empty gap / wrong size

`INLINE_HEIGHTS.gallery = 600` is a magic number unrelated to the grid geometry.
`MediaGrid` needs `GRID_MIN_HEIGHT = 3*160 + 2*4 + 32 = 520px` for 3 rows; adding
the chrome (header + 2 nav bars + status ≈ 144px) means 3 rows need ≈ **664px**.
At 600 the last row scrolls and the block height does not match its content.

### 3. Indexing view clipped on Windows

`App.svelte` reports a fixed `indexing: 280` while `IndexingProgress` reports its
measured height — the two race, and on Windows (taller default fonts) the fixed
280 can win last and clip the bottom.

---

## Changes actually shipped

Two rounds of manual verification in Claude Desktop overturned the sizing
approach originally drafted above (pin-height with `height: 100%`). It rendered
0×0 in both chat-flow and fullscreen — the top-down `height: 100%` chain is
*indefinite* in the MCP iframe, so the container's non-zero size was always
coming bottom-up from `width: 100%` + `aspect-ratio`. Removing `width: 100%`
(both the 1st attempt's and this doc's original change 1) collapses everything.
A second round then hit an **infinite reflow loop** in chat-flow from using
`dvh` as the cap there: `dvh` tracks the auto-resizing iframe itself, so a
`dvh`-based cap feeds back into its own input. The shipped fix keeps
`width: 100%` load-bearing and caps height with mode-specific, non-looping
values.

### 1. Preview container — width-driven, mode-dependent max-height cap

**File:** `gallery/src/components/PreviewPanel.svelte`

```css
/* Before */
.preview-container {
  aspect-ratio: {aspectRatio};   /* inline */
  width: 100%;
  max-width: 100%;
  max-height: 100%;              /* never actually constrains — parent height is indefinite */
  flex-shrink: 0;
}

/* After */
.preview-container {
  aspect-ratio: {aspectRatio};   /* inline — unchanged */
  width: 100%;                   /* load-bearing: gives the container (and panel) its
                                     only non-zero size, bottom-up */
  max-width: 100%;
  max-height: var(--inline-max, 520px);   /* chat-flow: FIXED px, decoupled from the iframe */
  flex-shrink: 0;
}
.preview-container.fullscreen {
  max-height: calc(100dvh - 5rem);        /* fullscreen: dvh is the fixed screen, stable */
}
```

- `isFullscreen` is now passed down from `App.svelte` and toggles the `.fullscreen`
  class.
- `--inline-max` is set from a new `inlineMaxHeight` prop (see change 2) so the
  chat-flow cap is derived from the same geometry as the inline gallery height,
  not a second magic number.
- Fullscreen keeps a `dvh`-based cap — safe there because the fullscreen viewport
  is the real screen, not a self-resizing iframe.
- Chat-flow uses a **fixed pixel** cap — `dvh` there is a feedback loop (iframe
  height → dvh → cap → content height → iframe resize → …).

### 2. Inline gallery height — computed from grid geometry, shared with the preview cap

**File:** `gallery/src/App.svelte`

```js
// Before
const INLINE_HEIGHTS = { gallery: 600, indexing: 280 };

// After — 3 rows (matches MediaGrid's GRID_MIN_HEIGHT) + grid nav bars + header/status
const GRID_ROWS_HEIGHT = 3 * 160 + 2 * 4 + 32;               // 520
const HEADER_STATUS = 76;                                     // header bar + status bar
const GRID_NAV = 68;                                          // nav-top + nav-bottom bars
const INLINE_GALLERY_HEIGHT = GRID_ROWS_HEIGHT + GRID_NAV + HEADER_STATUS; // 664
const INLINE_PREVIEW_MAX = INLINE_GALLERY_HEIGHT - HEADER_STATUS;         // 588 — preview has no nav bars
const INLINE_HEIGHTS = { gallery: INLINE_GALLERY_HEIGHT };
```

`INLINE_PREVIEW_MAX` is passed to `PreviewPanel` as `inlineMaxHeight`, which sets
`--inline-max` (change 1) — so the grid height and the preview cap are derived
from one shared computation instead of two independent magic numbers.

> The chrome constants (76, 68) are estimates, not measured. If they prove
> fragile across themes/platforms, revisit a measure-once approach — deferred
> for now since the fixed model was enough to pass verification.

**Dropped:** the platform pad (`IS_WINDOWS` / `navigator.userAgent`) proposed in
the original draft was not needed — Windows-specific sizing turned out to matter
only for the indexing view (change 3), not the gallery grid.

### 3. Indexing height — remove the App's fixed value, let IndexingProgress own it

**File:** `gallery/src/App.svelte`

```js
$effect(() => {
  if (!modeKnown || !mcpApp || !mcpReady || isFullscreen) return;
  // Indexing reports its own measured height (IndexingProgress.notifyHostMeasured) —
  // a fixed value here raced it and could clamp the iframe below the real content
  // height (e.g. clipping the Stop button / summary on Windows).
  if (mode === 'indexing') return;
  notifyHostHeight(mcpApp, INLINE_HEIGHTS[mode] ?? 400);
});
```

Shipped as originally drafted. Updated the `hostSize.js` header comment:
indexing is a measured view, gallery is a computed fixed value.

### 4. Grid — horizontal centering only

**File:** `gallery/src/components/MediaGrid.svelte`

```css
.grid {
  align-content: flex-start;   /* unchanged */
  justify-content: center;     /* added — equal left/right margins */
}
```

Vertical centering (`align-content: center`, and the `safe center` variant) was
tried and reverted: it broke the height sizing — centering pushed the first row
out of the reachable scroll area when content overflowed the fixed inline
height, interfering with the change-2 sizing. **Out of scope for this issue.**

### 5. Tests

**File:** `gallery/src/components/PreviewPanel.test.js`

Added: the container carries no leftover `.info-toggle`/etc. regressions and
(guarding the render-collapse failure mode) that `.preview-container` is present
with a non-empty inline `aspect-ratio` style. Height-race behavior (change 3) and
the geometry constants (change 2) are not unit-testable — `scrollHeight`/`dvh`
don't resolve meaningfully in jsdom — so they rely on the manual verification
below.

### 6. Documentation

- `gallery/src/lib/hostSize.js` — header comment: indexing measured, gallery fixed.
- No HLD/LLD data-model change (pure UI/layout).

---

## Verification

- `cd gallery && npm test` — all suites pass (182/182 + 1 new).
- Manual, Claude Desktop — confirmed:
  - **Fullscreen portrait** — fits within the viewer on first display, no clip,
    no navigate-to-fix. **Correct and smooth.**
  - **Chat-flow preview** — constant height across portrait/landscape, no reflow
    on exiting fullscreen.
  - **Inline grid (macOS)** — all 3 rows fully visible, no bottom clip.
  - **Grid** — left/right margins equal (vertical centering intentionally
    skipped).
- **Failed / still open on Windows:**
  - **Indexing widget** — still clipped at the bottom, even after change 3
    removed the App-vs-IndexingProgress height race. The remaining cause is not
    the race; see Open issues below.
  - **Inline gallery grid** — does not fit vertically on a laptop screen.

---

## Open issues (Windows)

Windows renders **noticeably larger default fonts** than macOS. Every chrome
height in this doc (`HEADER_STATUS = 76`, `GRID_NAV = 68`, the `5rem` fullscreen
allowance, indexing's own measured elements) was tuned by eye on macOS and is too
small once Windows' larger text and line-heights are taken into account — this is
a bigger gap than change 3's fixed-vs-measured race, which only addressed the
*ordering* of the two height reports, not their *values*.

Consequences:
- **Indexing** — `IndexingProgress` measures its own `scrollHeight`, so it should
  self-correct in principle, but it is still clipped in practice. Needs
  investigation on Windows directly (possible causes: the measurement firing
  before Windows web fonts/line-heights are fully laid out, or `notifyHostMeasured`
  losing a race against a later paint).
- **Inline gallery grid** — `INLINE_GALLERY_HEIGHT` is a fixed constant computed
  from macOS-tuned chrome estimates; on Windows the real chrome is taller, so the
  fixed 664px under-reports and the bottom of the 3-row grid doesn't fit on a
  laptop screen (limited vertical space to begin with).

Not re-attempted in this pass — needs either real Windows measurements to correct
the constants, or a switch to measuring the gallery chrome (not just indexing)
instead of hard-coding it. Left open for a follow-up.
