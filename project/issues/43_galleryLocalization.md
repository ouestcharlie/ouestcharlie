# OEC-43: Gallery localization (i18n) — FR, DE, ES, en-GB, ZH, JA

#status:done

> **Status: ✅ Implemented** in `ouestcharlie-woof/gallery`. The as-built design
> (and where it diverged from this plan — `en-GB` mirroring `en`, the
> `globalVariable` Paraglide strategy, paired `_one`/`_other` plural keys,
> model-facing text left in English) is documented in the **Localization (i18n)**
> subsection of `doc/design/woof_LLD.md` (Gallery MCP App).

## Context

The gallery UI (`woof/gallery`, a Svelte app embedded in the MCP host) ships
English-only. Every user-facing string is hardcoded inline in the components:
the header fallback (`'OuEstCharlie'`), the view/full-screen toggle titles
(`'Show preview'`, `'Back to grid'`, `'Full screen'`, `'Exit full screen'`),
the pagination buttons (`'Next ↓'`), the preview details panel headings
(`'Details'`, `'Overview'`, `'Camera'`, `'Location'`), the indexing progress
labels (`'Photos processed'`, `'Sidecars created'`, `'Errors'`, …), and the
error/loading status strings in `App.svelte` (`Error loading gallery: …`,
`Error loading page: …`).

This issue introduces a lightweight localization layer and translates the UI
into six locales, auto-selecting from the host's reported locale:

- **French** (`fr`)
- **German** (`de`)
- **Spanish** (`es`)
- **British English** (`en-GB`)
- **Chinese** (`zh`, Simplified — `zh-Hans`)
- **Japanese** (`ja`)

with **US English (`en`) as the base/default fallback**.

### Detection hook — already available, no new plumbing

The MCP Apps SDK already reports the host UI locale. `HostContext` carries an
optional `locale` string (`@modelcontextprotocol/ext-apps` —
`generated/schema.d.ts`: `locale: z.ZodOptional<z.ZodString>`), delivered
through the exact same channel the gallery already consumes for theme:
`app.getHostContext()` on connect and `app.onhostcontextchanged` on change
(both wired in `App.svelte`, alongside `applyDocumentTheme` /
`applyHostStyleVariables`). So locale selection reuses existing wiring — no
new host round-trip, no new MCP field.

Resolution order for the active locale:
1. `hostContext.locale` (BCP-47, e.g. `fr-FR`, `en-GB`, `zh-Hans-CN`).
2. `navigator.language` (standalone/dev, outside a host).
3. `'en'` fallback.

Match with graceful fallback: exact tag → primary subtag (`fr-FR` → `fr`) →
`en`. `en-GB` is kept distinct from `en` (spelling/wording differences), and
`zh-*` maps to the Simplified catalogue in V1.

### Scope note

This localizes **static UI chrome only**. Photo metadata (descriptions, tags,
place names) and the natural-language `querySummary` produced by Wally are
**not** translated here — they originate from the source data / the assistant
and are out of scope. Number/date formatting should use `Intl` with the active
locale (see below), since the preview panel already renders dates
(`formatDate`) and dimensions.

---

## Changes

### 1. Add Paraglide JS and wire it into the Vite build

**Library:** [Paraglide JS](https://inlang.com/m/gerre34r/library-inlang-paraglideJs)
(`@inlang/paraglide-js`), the standard inlang i18n library. It is a
**compiler**: at build time it turns per-locale message files into
tree-shakeable, fully-typed message functions — there is no runtime message
parser and no dictionary shipped as data, which suits a bundle that is inlined
into a single HTML file (see the singlefile note below).

**Files (new / changed):**
- `woof/gallery/project.inlang/settings.json` — inlang project config.
- `woof/gallery/vite.config.js` — add the Paraglide Vite plugin.
- `woof/gallery/package.json` — add `@inlang/paraglide-js` to `devDependencies`.

Steps:
- Scaffold with `npx @inlang/paraglide-js init` (creates
  `project.inlang/settings.json` and the initial `messages/` files), then set
  the locale list.
- In `settings.json`: `baseLocale: "en"` and
  `locales: ["en", "en-GB", "fr", "de", "es", "zh", "ja"]`.
- In `vite.config.js`, register the plugin so messages compile on build/dev:

  ```js
  import { paraglideVitePlugin } from '@inlang/paraglide-js';
  // plugins: [
  //   svelte(),
  //   paraglideVitePlugin({
  //     project: './project.inlang',
  //     outdir: './src/paraglide',
  //     // programmatic control from the MCP host context — see §3
  //     strategy: ['variable'],
  //   }),
  //   viteSingleFile(),
  // ]
  ```

- Generated output goes to `src/paraglide/` (gitignore it; it is a build
  artifact — messages are the source of truth). Confirm the Paraglide plugin
  runs **before** `vite-plugin-singlefile` so the compiled message modules get
  inlined into the single-file bundle like the rest of the app.

### 2. Message files (one per locale)

**Files (new):** `woof/gallery/messages/{en,en-GB,fr,de,es,zh,ja}.json`
(inlang message format).

- `en.json` is the canonical key set — extract every hardcoded string listed
  in Context. Keys are stable identifiers, not English text
  (e.g. `preview_details`, `preview_overview`, `preview_camera`,
  `preview_location`, `nav_show_preview`, `nav_back_to_grid`,
  `nav_fullscreen`, `nav_exit_fullscreen`, `grid_next`, `grid_prev`,
  `status_error_loading_gallery`, `indexing_photos_processed`, …).
- Parameterised messages use Paraglide's placeholder syntax for the values
  that embed data — e.g.
  `"status_error_loading_gallery": "Error loading gallery: {message}"`,
  `"indexing_photos_processed": "Photos processed: {count}"`.
- The other six files mirror the same keys. `en-GB` differs from `en` only in
  spelling/wording; keep it a full file (Paraglide requires every locale to
  define each message, falling back to `baseLocale` at compile time for any it
  omits).

### 3. Locale selection from the MCP host context

**File:** `woof/gallery/src/App.svelte`

Paraglide's runtime exposes `setLocale` / `getLocale` / `locales` /
`baseLocale` from the generated `./paraglide/runtime.js`. Drive it from the
same host-context channel the gallery already uses for theme:

- Use the `variable` strategy (above) so `setLocale` switches the active
  locale **in memory** without a page reload — call it as
  `setLocale(tag, { reload: false })`, since the gallery lives in an embedded
  iframe and must not navigate.
- On mount / connect:
  `applyLocale(app.getHostContext()?.locale ?? navigator.language)`.
- In `onhostcontextchanged`: `if (ctx?.locale) applyLocale(ctx.locale)` —
  mirrors the existing `if (ctx?.theme) applyDocumentTheme(ctx.theme)` line so
  locale tracks live host changes.
- `applyLocale(tag)` is a thin wrapper resolving the host's BCP-47 tag against
  Paraglide's `locales`: exact match (`en-GB`) → primary subtag (`fr-FR` →
  `fr`, `zh-Hans-CN` → `zh`) → `baseLocale`. Then `setLocale(resolved, { reload: false })`
  and set `document.documentElement.lang`.

### 4. Replace hardcoded strings in components

**Files:** `App.svelte`, `components/PreviewPanel.svelte`,
`components/PhotoGrid.svelte`, `components/IndexingProgress.svelte`.

- `import * as m from '../paraglide/messages.js'` and replace each inline
  literal with the corresponding message function, e.g. `{m.preview_details()}`,
  `{m.status_error_loading_gallery({ message: err.message })}`,
  `{m.indexing_photos_processed({ count })}`.
- Because these are plain reactive function calls, Svelte re-renders them when
  `setLocale` changes the active locale — no extra store needed.
- Route dates/counts through `Intl` with `getLocale()` so `formatDate` and
  numeric counters follow the active locale (Paraglide localises the strings,
  not number/date formatting).
- **Constraint (project CLAUDE.md):** no inline JS / no `onX` in raw HTML —
  keep everything in the Svelte `<script>` blocks, as today.

### 5. Tests

**Files:** `woof/gallery/src/lib/locale.test.js` (new, for the `applyLocale`
resolver) and updates to the existing component `*.test.js`.

- Resolution: `fr-FR` → `fr`; `en-GB` stays `en-GB`; `zh-Hans-CN` → `zh`;
  unknown tag → `en` (`baseLocale`).
- Missing-key fallback: a key absent from `fr` renders the `en` value, never
  blank.
- Interpolation: `{placeholder}` substitution works.
- Catalogue completeness: every non-`en` catalogue exposes exactly the `en`
  key set (guards against drift). `en-GB` may be a sparse override — assert its
  keys are a subset of `en`.
- Component render: with locale `fr`, the preview panel headings and nav
  titles render the French strings.

### 6. Documentation

- Frontend-only; no HLD/LLD/schema/XMP/Wally change.
- If a gallery README/UI doc exists under `woof/gallery/`, add a short
  "Localization" note: where catalogues live, how the active locale is
  resolved (host `locale` → `navigator.language` → `en`), and how to add a new
  locale (drop a catalogue file, register it in the barrel). Do **not**
  enumerate individual keys in prose.

---

## Verification

- `cd woof/gallery && npm run test` — new `i18n` tests and updated component
  tests pass; the catalogue-completeness test passes for all six locales.
- Manual, via the gallery embedded in an MCP client whose UI language is set
  to each target locale:
  - Header, nav toggles (preview / full-screen), pagination, preview details
    headings (Overview / Camera / Location), and indexing progress labels all
    appear translated.
  - Switching the host UI language live re-renders the gallery strings
    (exercises `onhostcontextchanged`).
  - Dates and counts follow the locale (`Intl`).
  - Force an unknown/unsupported locale → falls back cleanly to English, no
    blank strings.
  - Standalone/dev (outside a host) → picks up `navigator.language`.
