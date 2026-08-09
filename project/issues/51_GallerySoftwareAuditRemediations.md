# OEC-51: Gallery software audit and remediations

#status:done

All five remediations implemented; full gallery suite green (170 tests) and `svelte-check` clean. New modules: `lib/pagination.js`, `lib/format.js`, `lib/hostSize.js`, `lib/mcpSession.svelte.js`, each with the extracted logic and (for the pure ones) dedicated tests.

## Audit tool conclusions

This is a Svelte 5 app (runes-based) embedded as an MCP Apps iframe in Claude Desktop/CoWork — small, but with some real architectural choices worth discussing.

**Overall shape**
"Smart root, dumb children": `App.svelte` owns essentially all state (`$state` for token, matches, view, mode, mcp connection...) and passes data + callback props (`onSelect`, `onNavigate`, `onFetchServerPage`) down. No `createEventDispatcher`, no stores in the component tree — idiomatic Svelte 5. Networking/auth-origin logic is cleanly isolated in `api.svelte.js`, which uses module-level runes as a lightweight global store (a legit pattern for genuinely cross-cutting state that isn't prop-drilled).

**Strengths**
- Consistent JSDoc prop typing across every component.
- Tests colocated with source, plus a locale-completeness test (`messages.test.js`) guarding i18n catalogs — a nice structural guardrail.
- `previewUrl`/`thumbnailUrl`/`videoUrl` builders live in the API module, not scattered in components.

**Things I'd flag**

1. **`App.svelte` is doing too much.** It bootstraps two parallel connection paths (URL params vs. MCP `app.connect()`), tracks host context (locale/theme/fullscreen), owns keyboard handling, and drives the resize-reporting policy. Given `api.svelte.js` already establishes a "module-level runes as service" pattern, the MCP bootstrap/session logic is a good candidate to extract the same way (e.g. `lib/mcpSession.svelte.js`) rather than living in the root component.

2. **Likely real bug: PreviewPanel's keydown listener stays live while hidden.** `PreviewPanel` is mounted once `selectedIndex !== null` and only toggled with `display:none` via `class:hidden` — it's never unmounted. But its `onKeydown` (ArrowLeft/Right → `onNavigate`) is registered at `window` level in `onMount` and has no visibility guard. So while the grid view is showing on top, arrow-key presses will silently advance `selectedIndex` in the background, and the user gets a surprise jump when they reopen the preview.

3. **Pagination math in `MediaGrid` is dense and untested in isolation.** `absolutePageFromMap`/`totalDisplayPages` translate variable-size server pages into fixed-size display pages — genuinely tricky logic, well-commented, but embedded in the component so it can only be exercised via mounting. Worth pulling into a pure function in `lib/` with its own unit tests.

4. **Duplicated "notify host of size" strategies.** `App.svelte` uses a fixed `INLINE_HEIGHTS` map; `IndexingProgress.svelte` measures `rootEl.scrollHeight` via rAF. Two different policies for the same host-communication concern, each reimplemented with its own `$effect`. A shared helper (or Svelte action) would keep this consistent as more views get added.

5. **Formatting helpers buried in `PreviewPanel`.** `formatAperture`, `formatExposure`, `codecUnplayable`, `formatGps`, etc. are pure and reusable but live in the component script with no dedicated test file, unlike everything else in the project which is well-tested. Extracting to `lib/format.js` would match the project's own testing conventions.

None of these are severe — the codebase is disciplined and the runes usage is genuinely idiomatic. The recurring theme is: logic that's pure/testable or cross-cutting tends to be embedded in components instead of following the `api.svelte.js` precedent the project already set for itself.

## Remediations

Ordered by priority: the one real bug first, then the refactors that pull pure/cross-cutting logic out of components to match the `api.svelte.js` precedent. Each item is independently shippable.

### R1 — Fix PreviewPanel's background keydown (bug) — **priority**

**Confirmed.** `PreviewPanel` registers `onKeydown` on `window` in `onMount` (`PreviewPanel.svelte:171`) and is never unmounted — `App.svelte` keeps it in the DOM once `selectedIndex !== null` and only hides it with `class:hidden` (`App.svelte:284-294`). While the grid is on top, ArrowLeft/Right still advance `selectedIndex` in the background, so reopening the preview lands on an unexpected item.

Fix — the panel already can't know it's hidden, so pass the active view down and guard on it:
- Add a `boolean` prop (e.g. `active`) to `PreviewPanel`, set from `App.svelte` as `active={view === 'preview'}`.
- Early-return from `onKeydown` when `!active`.

This keeps the smart-root/dumb-child shape (the parent owns `view`) and needs no unmount/remount. Add a test asserting arrow keys are ignored when `active` is false and honored when true.

Alternative considered: unmount the panel when hidden (drop `class:hidden`, gate the whole block on `view === 'preview'`). Rejected — the panel keeps `shownUrl`/load state to avoid image re-fetch flicker on reopen; unmounting throws that away.

### R2 — Extract MediaGrid pagination into a tested pure module

**Confirmed** the logic is pure and untested in isolation. `absolutePageFromMap` and `totalDisplayPages` (`MediaGrid.svelte:48-69`) map variable-size server pages onto fixed display pages and can only be exercised by mounting.

- Move both (plus the small `dpp`/`lastSize` helpers) into `lib/pagination.js` as pure functions taking `(pageMap, serverPage, localPage, displayPageSize)`.
- Import them into `MediaGrid` for the `$derived` bindings — no behavior change.
- Add `lib/pagination.test.js` covering: single server page, multiple full pages, partial last page per map entry, `displayPageSize` larger than a server page, and empty/one-item maps.

### R3 — Extract PreviewPanel formatting helpers into a tested module

**Confirmed.** `roundTrim`, `formatAperture`, `formatExposure`, `formatFocal`, `formatDuration`, `formatDimensions`, `formatCamera`, `codecLabel`, `codecUnplayable`, `formatGps`, `truncate` (`PreviewPanel.svelte:81-161`) are pure and reusable but untested, unlike the rest of the project.

- Move them to `lib/format.js`. `formatDate` reads the active locale via `getLocale()` — keep it working by passing locale in or importing the runtime inside `format.js`.
- `codecUnplayable` touches `document.createElement('video')`; it stays testable under jsdom but assert against the `canPlayType` contract via a mock rather than the host's real codec support.
- Add `lib/format.test.js` covering the EXIF-noise rounding cases the comments call out (`8.0 → 8`, sub-second exposures, GPS hemisphere signs, focal 35mm-eq suffix).

### R4 — Unify the "notify host of size" strategy

**Confirmed** two policies coexist: `App.svelte`'s fixed `INLINE_HEIGHTS` map (`App.svelte:68-73`) and `IndexingProgress`'s `rootEl.scrollHeight`-via-rAF measurement (`IndexingProgress.svelte:143-148`, plus the `ontoggle` re-measure at `:196`).

- Add one helper in `lib/hostSize.svelte.js` — a Svelte action or a small function — that both call: given an `mcpApp`, an `mcpReady`/`isFullscreen` gate, and either a fixed height or an element to measure, it debounces and calls `sendSizeChanged`.
- Keeps future views consistent and removes the duplicated `$effect`/rAF plumbing. Pure mechanics; no visible behavior change.

### R5 — Extract MCP bootstrap/session logic out of App.svelte

**Confirmed** `App.svelte` bootstraps both connection paths, host-context tracking, keyboard handling, and the resize policy. Following the `api.svelte.js` "module-level runes as service" precedent:

- Move the MCP `App` construction, `ontoolresult`/`onhostcontextchanged` wiring, and `connect()` bootstrap into `lib/mcpSession.svelte.js`, exposing runes (`mcpReady`, `isFullscreen`, `canFullscreen`, host context) and a callback for tool results that hands `App.svelte` a normalized `{ mode, session }`.
- `App.svelte` shrinks to view/selection state + rendering.
- This is the largest change and touches the most-tested file — do it last, after R1–R4, and lean on `App.test.js` (which already mocks `@modelcontextprotocol/ext-apps`) to hold behavior steady.

### Sequencing

R1 ships on its own (user-visible fix). R2–R4 are low-risk extractions that add the missing tests and can land in any order. R5 depends on R4 (it absorbs the resize policy) and should be last.

