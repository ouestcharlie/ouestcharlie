# OEC-66: Split the gallery into several bundles with dynamic loading

#status:done

Only performed the ext-apps upgrade, which decreased the bundle size enough to cancel other changes.

## Context

Vite builds the gallery (`ouestcharlie-woof/gallery`) into one JS file,
`src/woof/gallery/dist/assets/index-*.js`. Every gallery or indexing iframe downloads, parses
and compiles the whole file before anything renders, even though each view uses only part
of it.

Already done (step 0): upgrading `@modelcontextprotocol/ext-apps` from 1.7.5 to 2.0.3 (SDK
v2 split packages `@modelcontextprotocol/client` / `core`) took the bundle from **537 KB to
325 KB minified** (134 → 92 KB gzip) and removed the >500 kB Vite warning. With 1.7.5,
`ext-apps` imported the whole `z` namespace from `zod/v4`, which kept every Zod
error-message locale (~162 KB) in the bundle. 2.x no longer does. The MCP Apps wire protocol
is unchanged between 1.x and 2.x; no gallery code changed.

Approximate breakdown after the upgrade (attributed from the build source map):

| Part | Size (min) | Needed at startup? |
|---|---|---|
| `@modelcontextprotocol/client` | ~88 KB | Yes: `App` extends its `Protocol` |
| `zod` v4 (`core` ~77 KB + `classic` ~15 KB) | ~92 KB | Yes: validates host messages |
| `svelte` runtime | ~39 KB | Yes |
| `@modelcontextprotocol/ext-apps` | ~26 KB | Yes |
| `@modelcontextprotocol/core` | ~16 KB | Yes |
| Paraglide messages (7 locales) | ~18 KB | Only the active locale |
| `PreviewPanel.svelte` | ~7 KB | Only when a photo/video is opened |
| `MediaGrid.svelte` | ~5 KB | Gallery mode only |
| `IndexingProgress.svelte` | ~5 KB | Indexing mode only |
| App shell + `lib/` | ~13 KB | Yes |

App code is still about 10% of the bundle. Lazy-loading the views alone saves only ~15 KB.
The bigger remaining wins are a separate vendor chunk that stays cached across gallery views,
and possibly a lighter MCP client (§6).

Caching today: every gallery view the host opens is a new iframe that requests the bundle
from `http://127.0.0.1:{port}/gallery-static/`. Woof sends `ETag` and `Last-Modified` but no
`Cache-Control`. The browser therefore uses heuristic freshness (Chromium: ~10% of the
file's age since `Last-Modified`), then revalidates with a conditional request (304, no
body). Three limits apply:
- **The port changes on every Woof restart.** It is OS-assigned (`asgi_server.py`, bound to
  port 0). The port is part of the cache key, so the first view after each restart downloads
  the full bundle whatever the headers say.
- **The host's iframe setup decides whether views share a cache.** Chromium partitions its
  HTTP cache by top-level site and frame site. Whether views share cached files depends on
  whether the host gives MCP App iframes a stable sandbox origin, or a unique or opaque one
  per view or conversation. This has not been checked yet for Claude Desktop or claude.ai.
  Private mode uses its own temporary cache.
- **Parsing and compiling happen in every iframe.** Even when the bytes come from cache, each
  new view parses, compiles and runs the whole bundle again (V8's code cache can soften the
  compile step). Over loopback the download costs milliseconds, so this per-view work is the
  main cost. Smaller per-mode chunks reduce it; caching does not.

Intended outcome: each iframe parses only the code for its mode, and vendor code is served
from the browser cache across views within one Woof process.

Out of scope: Woof GitHub #76 (gallery not rendering on Claude Desktop for macOS). Nothing
points to bundle size as its cause.

---

## Changes

### 1. Lazy views

**File:** `ouestcharlie-woof/gallery/src/App.svelte`

Replace the static imports of `MediaGrid`, `PreviewPanel` and `IndexingProgress` with
`import()`, triggered once `modeKnown` is true:
- `mode === 'indexing'` → load `IndexingProgress` only.
- `mode === 'gallery'` → load `MediaGrid`; load `PreviewPanel` on the first switch to
  `view === 'preview'` (or prefetch it when the grid is idle).

Show a loading state while a chunk loads, and call `notifyHostHeight` only once the view is
mounted, so the host never gets a wrong height.

### 2. Vendor chunk

**File:** `ouestcharlie-woof/gallery/vite.config.js`

Use `build.rolldownOptions.output.codeSplitting` (or `manualChunks`) to put `zod`,
`@modelcontextprotocol/*` and `svelte` in a `vendor-*.js` chunk whose hash changes only
when dependencies change.

### 3. Chunk URLs inside the MCP Apps iframe

**Files:** `ouestcharlie-woof/gallery/vite.config.js`,
`ouestcharlie-woof/src/woof/http_server.py` (`get_gallery_html`)

This is the main technical risk. `get_gallery_html()` rewrites `/gallery-static/` to
`{server_url}/gallery-static/` **in `index.html` only**. With `base: '/gallery-static/'`,
Vite's preload helper and the CSS `<link>` tags it injects for lazy chunks use root-relative
URLs (`/gallery-static/assets/...`). The browser resolves those against the iframe's document
origin, not the Woof server. Lazy chunks would then fail inside the host while still working
on direct browser access to `/gallery/{session_id}/html`.

Options to evaluate:
- `base: './'`, so chunk URLs resolve against the importing module (`import.meta.url` = Woof
  server). The HTML rewrite in `get_gallery_html()` then has to target the new relative paths.
- `experimental.renderBuiltUrl` returning `{ relative: true }` for JS/CSS.
- `build.modulePreload: false`, checking how lazy CSS is then attached.

Chunks come from the same origin as the entry script, so the gallery resource CSP
(`resource_domains = server_urls` in `mcp_server.py`) should need no change. Verify on each
host.

### 4. Cache headers for hashed assets

**File:** `ouestcharlie-woof/src/woof/http_server.py` (`/gallery-static` mount)

Serve `/gallery-static/assets/*` with `Cache-Control: public, max-age=31536000, immutable`.
Starlette `StaticFiles` sends only ETag/Last-Modified today, which still costs one
revalidation request per file per session once heuristic freshness expires. `index.html`
and the gallery MCP resource must not get this header.

This only helps within one Woof process: the OS-assigned port changes the asset URLs on
every restart (see Context). Open point: is a cache that survives restarts worth a stable
port, e.g. a preferred fixed port with fallback to an OS-assigned one when it is taken? That
would touch discovery, the CSP `server_urls` and the bridge. Or do we accept one full
download per Woof start and rely on smaller chunks? Decide during spec review; a stable port
is out of scope for this issue unless agreed.

### 5. Per-locale messages (optional)

**Files:** `ouestcharlie-woof/gallery/vite.config.js`, `gallery/src/lib/locale.js`

Load only the active locale's Paraglide messages after `applyLocale()`, if Paraglide v2
supports it without breaking the `globalVariable` strategy (OEC-43). Drop this step if it
does not.

### 6. MCP client footprint (investigation)

After step 0, `@modelcontextprotocol/client`, `core`, `ext-apps` and Zod still weigh about
220 KB of the 325 KB, all needed at startup. Options:
- **Keep `ext-apps`** and rely on the vendor chunk (§2) and caching (§4). No maintenance
  cost.
- **Hand-written client.** The gallery uses only the `connect()` handshake,
  `getHostContext()`, the `ontoolresult` / `onhostcontextchanged` notifications,
  `requestDisplayMode`, `updateModelContext`, `sendMessage`, `sendSizeChanged`, and the
  `applyDocumentTheme` / `applyHostStyleVariables` DOM helpers. A JSON-RPC-over-`postMessage`
  client of ~200–300 lines would bring the bundle to an estimated ~100 KB. Cost: following
  MCP Apps spec changes ourselves (protocol version negotiation, new host-context fields,
  host quirks) and losing message validation.
- **Not viable:** aliasing `zod` to `zod/mini`. The SDK schemas use the full API
  (`.extend`, `.passthrough`, …).

Decide once the iframe-origin check (Verification) shows whether vendor code is actually
cached across views. If it is, the hand-written client is worth much less.

### 7. Tests

**Files:** `ouestcharlie-woof/gallery/src/App.test.js`, `ouestcharlie-woof/tests/test_asgi_server.py`

- `App.test.js`: indexing mode never loads the grid/preview modules; gallery mode never
  loads `IndexingProgress`; the loading state renders until the chunk resolves.
- Existing component tests that import the views directly keep working unchanged.
- Python: hashed assets carry the immutable `Cache-Control`; `index.html` and the gallery
  HTML route do not. If `get_gallery_html()` changes, test the rewritten URLs.

### 8. Documentation

- `ouestcharlie-woof/doc/design/woof_LLD.md`: gallery build section (chunks, base URL,
  rewrite in `get_gallery_html()`, cache headers).
- `ouestcharlie-woof/gallery/README.md`: build output layout.

---

## Verification

- `cd ouestcharlie-woof/gallery && npm run build`: emits an entry chunk, a vendor chunk and
  separate view chunks, with no >500 kB warning. Record sizes before and after.
- `npm test` and `make test-python test-python-int` in `ouestcharlie-woof` pass.
- In the network panel: an indexing session does not request the grid/preview chunks, and a
  gallery session does not request the indexing chunk. With the **same Woof process**, a
  second gallery view serves vendor/view chunks from the cache with no request. After a Woof
  restart, the full download on the next view is expected.
- In the host's DevTools, record the gallery iframe's origin (stable sandbox origin vs.
  unique/opaque per view or conversation) on Claude Desktop and claude.ai, and whether a
  second view in the same and in a new conversation hits the cache. Note the result in
  this issue: it decides how much §2 and §4 are worth.
- Lazy chunks and their CSS load in the MCP Apps iframe on Claude Desktop (macOS, Windows)
  and claude.ai, and on direct browser access to `/gallery/{session_id}/html`.
- `make pack`: the `.mcpb` / wheel contains every chunk (`artifacts =
  ["src/woof/gallery/dist"]`), and a gallery opened from the installed package renders.
