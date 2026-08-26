# OEC-56: Fix grid thumbnail rendering in GitHub Copilot (VS Code) MCP App host

#status:done

Status flow: draft (write spec) -> open (review spec) -> todo (spec validated) -> ongoing (implementation started) -> done (merged)

## Context

GitHub Copilot in VS Code now supports MCP Apps and is a strong candidate host for Woof's
gallery UI — it works well for interactive workflows like photo enrichment. However, the
gallery's grid thumbnails do not display when the gallery MCP App resource is rendered
inside Copilot's webview, even though the same resource renders correctly in Claude Desktop
(see prior milestone: gallery embedded in Claude Desktop, OEC-50/50b/53).

### How thumbnails currently work

Each grid tile is *not* an individual thumbnail image. `browse_gallery`/`search_photos`
results reference a per-partition AVIF sprite grid (`thumbnails.avif`, 8 columns —
`AVIF_GRID_COLS` in [App.svelte](../../gallery/src/App.svelte)). For each match,
`thumbnailTile()` computes `(col, row)` from `match.tileIndex`, and
[MediaGrid.svelte](../../gallery/src/components/MediaGrid.svelte) renders the *entire* AVIF
grid image scaled up to `cols × DISPLAY_SIZE` wide (1280px, via an inline `width` style),
then clips a single 160×160 tile into view using negative `margin-left`/`margin-top` on the
`<img>` inside a `.tile` container with `overflow: hidden`.

### Confirmed root cause

VS Code's webview injects a default stylesheet that includes:

```css
img, video {
  max-width: 100%;
  max-height: 100%;
}
```

`max-width`/`max-height` resolve against the containing block — here, `.tile`'s 160px
content box — and **override** an explicit `width` style when the two conflict (per CSS
`max-width` semantics). So instead of laying out at 1280px wide as the clip math assumes,
the sprite grid image is squeezed down to 160px wide inside Copilot's webview. The
negative-margin offsets (computed for the 1280px layout, e.g. `-{col * 160}px`) then shift
this shrunken image far outside the visible tile, so nothing from the sprite ends up in the
160×160 viewport. Claude Desktop's host does not inject this default, so the same markup
renders correctly there.

This was isolated by ruling out AVIF decoding (the sprite loads and decodes fine —
devtools' own image preview shows the full 8×8 grid) and by confirming the negative-margin
values themselves are exact multiples of 160 and match `tile.col`/`tile.row` — the bug is
purely that the *image's rendered width* silently disagrees with what the margin math
assumes it to be, not the arithmetic itself.

### Related, likely unrelated finding

Copilot's webview devtools console also shows a CSP violation (`script-src` blocks
`unsafe-eval`), traced to Zod's caught `allowsEval` feature-detection probe bundled inside
`@modelcontextprotocol/ext-apps` (the MCP Apps client SDK). It's wrapped in `try`/`catch` and
does not throw, so it isn't the cause of the thumbnail bug — tracked separately below as
minor cleanup so it doesn't produce confusing signal during future debugging.

## Changes

### 1. Fix the sprite-grid image sizing

**File:** [gallery/src/components/MediaGrid.svelte](../../gallery/src/components/MediaGrid.svelte)

Make the thumbnail `<img>`'s effective width immune to host-injected `max-width: 100%`
defaults. The most direct fix is to add `max-width: none; max-height: none;` to the inline
style (or an equally-specific scoped rule) alongside the existing `width`/`margin` styles,
so it wins regardless of what a host's base stylesheet asserts on bare `img` selectors:

```svelte
<!-- Before -->
style="
  width: {tile.cols * DISPLAY_SIZE}px;
  height: auto;
  margin-left: -{tile.col * DISPLAY_SIZE}px;
  margin-top: -{tile.row * DISPLAY_SIZE}px;
  display: block;
"

<!-- After -->
style="
  width: {tile.cols * DISPLAY_SIZE}px;
  max-width: none;
  height: auto;
  max-height: none;
  margin-left: -{tile.col * DISPLAY_SIZE}px;
  margin-top: -{tile.row * DISPLAY_SIZE}px;
  display: block;
"
```

Also check the fullscreen/detail-view media rendering elsewhere in
[App.svelte](../../gallery/src/App.svelte) for the same `img`/`video` host-default risk,
since it's a general host-stylesheet hazard, not one confined to the sprite-clip technique.

### 2. Tests

**File:** `gallery/src/components/MediaGrid.test.js`

Add a test asserting the thumbnail `<img>`'s inline style includes `max-width: none` (or
whatever selector-based fix is chosen), so a regression that drops it — e.g. during a future
refactor to the clip technique — is caught even without a Copilot-specific test environment.

### 3. Documentation

Note in the gallery LLD (if one documents the thumbnail sprite-grid technique) that any
MCP App host may inject a base stylesheet with generic `img`/`video` rules, and that the
sprite-clip technique must always set explicit `max-width`/`max-height` to override such
defaults — this is a constraint on the technique itself, not a one-off Copilot fix.

### 4. CSP eval noise cleanup (unrelated, low priority)

Check whether `@modelcontextprotocol/ext-apps` has a newer release where Zod's eval
feature-detection is opt-out or removed, and bump if so. If not fixable from our side, file
it upstream against the MCP Apps SDK — a bundled dependency probing for `unsafe-eval`
support on every load is avoidable console noise under a host CSP that (correctly) omits it.

**Not done in this pass**: current pin is `^1.2.2`, latest published is `1.7.5` — a jump
across several minor versions warrants its own review/testing rather than folding into the
thumbnail fix. Left as a follow-up.

---

## Verification

- Manual: open the gallery via GitHub Copilot in VS Code and confirm grid thumbnails render
  correctly, alongside a re-check in Claude Desktop to confirm no regression.
- `npm test` (or the gallery's configured test runner) for `MediaGrid.test.js` changes.
