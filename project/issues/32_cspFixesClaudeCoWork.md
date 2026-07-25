# OEC-32: Fix Woof gallery CSP for both Claude Desktop Chat and CoWork

#status:done

## Context

The Woof gallery MCP App works in Claude Desktop Chat but fails with a CSP violation in Claude
CoWork — API calls from the gallery iframe to the Woof HTTP server are blocked.

**Root cause:** Woof's HTTP server binds to `127.0.0.1` but exposes its `server_url` using the
hostname `localhost` (`server.py:56`, `http_server.py:114`) — a deliberate fix from a past
milestone (`_register_gallery_resource`, `server.py:370-384`, see issue #19) that made Chat's
iframe CSP matching work. CoWork, however, blocks `localhost` as a CSP domain outright and
requires `127.0.0.1`.

Swapping the hardcoded hostname to `127.0.0.1` fixes CoWork but breaks Chat — the two hosts have
opposite hostname requirements. Per-session `clientInfo` sniffing was considered and rejected:
it relies on a private fastmcp attribute (`ctx.session._client_params`) and only works if Chat and
CoWork open genuinely distinguishable MCP sessions, which is unconfirmed. Instead, the server
becomes the single source of truth for **all valid loopback origins for its port**, and that list
is threaded through to both the CSP declaration and the client — no hostname string manipulation
or per-host branching anywhere.

1. **Server computes both origins once**, directly from the bound port (`http://localhost:{port}`
   and `http://127.0.0.1:{port}`), as a list.
2. **CSP declares both** as valid (`ResourceCSP.resource_domains`/`connect_domains` accept
   `list[str]`, confirmed in `fastmcp/apps/config.py:28,34` — no wildcard support exists, so exact
   origins must be listed).
3. **Client receives the same list** (via tool results and the gallery HTML) and tries each origin
   in order, adopting whichever one actually succeeds for the rest of the session.

This generalizes to any future host with an unknown hostname policy — just append another
candidate origin to the one list, no per-host branching anywhere.

---

## Changes

### 1. Compute candidate origin list at bind time

**File:** `ouestcharlie-woof/src/woof/server.py` (`__init__`, lines 51-56)

```python
# Before
_sock.bind(("127.0.0.1", 0))
self._http_sock = _sock
self.server_url = f"http://localhost:{_sock.getsockname()[1]}"

# After
_sock.bind(("127.0.0.1", 0))
self._http_sock = _sock
_port = _sock.getsockname()[1]
self.server_urls = [f"http://localhost:{_port}", f"http://127.0.0.1:{_port}"]
self.server_url = self.server_urls[0]  # primary, unchanged string for existing Chat-facing fields
```

`self.server_url` stays exactly `http://localhost:{port}` (same value as today) so nothing that
already depends on that exact string changes. `self.server_urls` is purely additive.

### 2. Widen CSP and embed the list in gallery HTML

**File:** `ouestcharlie-woof/src/woof/server.py` (`_register_gallery_resource`, lines 370-384)

```python
# Before
def _register_gallery_resource(self) -> None:
    origin = self.server_url

    @self.mcp.resource(
        _GALLERY_URI,
        mime_type="text/html;profile=mcp-app",
        app=AppConfig(
            csp=ResourceCSP(
                resource_domains=[origin],
                connect_domains=[origin],
            )
        ),
    )
    async def gallery_resource() -> str:
        return get_gallery_html(self.server_url)

# After
def _register_gallery_resource(self) -> None:
    @self.mcp.resource(
        _GALLERY_URI,
        mime_type="text/html;profile=mcp-app",
        app=AppConfig(
            csp=ResourceCSP(
                resource_domains=self.server_urls,
                connect_domains=self.server_urls,
            )
        ),
    )
    async def gallery_resource() -> str:
        return get_gallery_html(self.server_url, self.server_urls)
```

### 3. Add `serverUrls` to tool results

**File:** `ouestcharlie-woof/src/woof/server.py` (`search_photos` ~line 235, `browse_gallery`
~lines 361-362)

Both currently return `"serverUrl": self.server_url` — add `"serverUrls": self.server_urls`
alongside it, so the MCP Apps `ontoolresult` path has the same candidate list as the
direct-HTML/`?token=` path.

### 4. New API client module for the gallery frontend

**File:** `ouestcharlie-woof/gallery/src/lib/api.svelte.js` (new)

There are 5 raw `fetch()` call sites (`App.svelte:56,88,122`; `IndexingProgress.svelte:21,54`)
plus 2 `<img>` URL builders (`App.svelte:160,183`) that all interpolate `${serverUrl}/...`
ad-hoc today, with no shared helper. Centralize them here as a small API client — components
call named functions per endpoint, never build URL strings themselves.

- Uses a Svelte 5 module-scope rune (`let resolvedOrigin = $state(null)`) — the idiomatic Svelte 5
  pattern for reactive state shared across components without prop-drilling or the old
  writable-store boilerplate. The `.svelte.js` extension is required for runes to work outside a
  component.
- `initServerOrigins(candidates)`: called once from `App.svelte` as soon as `serverUrls` is known
  (from the HTML-embedded initial data or the `ontoolresult` payload).
- Internal `request(path, options)`: tries `resolvedOrigin` first if already set; otherwise
  iterates the candidate list in order until one succeeds, then sets `resolvedOrigin` (module
  state, so every importer sees it update reactively). This is what removes the need to
  prop-drill `serverUrl` into `IndexingProgress.svelte`.
- Exported endpoint functions replacing the 5 raw `fetch(...)` calls: `fetchResultsPage(token,
  page)`, `fetchResults(token)`, `fetchIndexingStatus(sessionId)`, `cancelIndexing(sessionId)`.
- Exported URL builders replacing the 2 `<img>` src interpolations: `thumbnailUrl(library,
  partition, avifHash)`, `previewUrl(library, partition, contentHash)` — read `resolvedOrigin`
  directly (reactive, so images update automatically once fallback resolves).
- No hostname string manipulation anywhere — only ever iterates the list it was handed.

### 5. Update `App.svelte` / `IndexingProgress.svelte`

- Call `initServerOrigins(serverUrls)` once `serverUrls` is known.
- Replace the 5 raw `fetch(...)` calls with the corresponding `api.svelte.js` function.
- Replace the 2 `<img>` URL template literals with `thumbnailUrl(...)`/`previewUrl(...)`.
- Drop the `serverUrl` prop passed into `IndexingProgress.svelte` — it now imports
  `api.svelte.js` directly and reads `resolvedOrigin` reactively.

### 6. Tests

**Python** — `ouestcharlie-woof/tests/`: update any test asserting a single-origin CSP to expect
the two-element list; add/adjust a test asserting `server_urls` and `server_url` are both present
and consistent, and that `search_photos`/`browse_gallery` results include `serverUrls`.

**JavaScript** — `ouestcharlie-woof/gallery/src/`:
- Update existing tests that mock `fetch` with `vi.fn()` (see `IndexingProgress.test.js` for the
  established pattern) to call `initServerOrigins([...])` before exercising components, since
  `IndexingProgress.svelte` no longer receives `serverUrl` as a prop.
- Add `api.svelte.test.js` exercising the fallback path directly: first candidate's `fetch`
  rejects, second succeeds — assert `resolvedOrigin` updates and a subsequent call reuses it
  without re-trying the first candidate.

---

## Verification

- Run `.venv/bin/pytest tests/ -v` in `ouestcharlie-woof/` — all pass including new/updated tests.
- Run `npm test` in `ouestcharlie-woof/gallery/` — all pass including the new fallback test.
- Manual: exercise `search_photos` → `browse_gallery` in both Claude Desktop Chat and Claude
  CoWork; confirm the gallery loads and thumbnails/previews render in both, with no CSP violations
  in either host's dev tools console.
