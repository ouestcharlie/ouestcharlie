# Plan: Rename "backend" → "library" in HTTP server and Svelte gallery

#status:done

## Context

The MCP tool layer was already renamed in issue 16 (`add_library`, `list_libraries`, etc.). This plan completes the rename for the remaining layers: the session data JSON key `"backend"`, the HTTP proxy route parameter `{backend}`, the Svelte state variable `backendName`, and the bridge.js JSDoc.

The integration test (`tests_integration/test_startup.py`) has already been updated and currently fails because `gallery_session_manager.py` still writes `"backend"`. This plan makes the production code match.

---

## Implementation

### 1. `src/woof/gallery_session_manager.py`

- Class doc comment schema: `"backend": str` → `"library": str`; update "Backend names are joined" → "Library names are joined"
- `create(self, backend_name: str, ...)` → `create(self, library_name: str, ...)`
- `"backend": backend_name` → `"library": library_name`
- `merge()`: `backend = session.get("backend", "")` → `library = session.get("library", "")`;
  `backend_names` → `library_names`; `merged_backend` → `merged_library`; `"backend": merged_backend` → `"library": merged_library`

### 2. `src/woof/server.py`

In `browse_gallery` return dict (line ~276):
- `"backend": data["backend"]` → `"library": data["library"]`

### 3. `src/woof/http_server.py`

- Module doc comment: `{backend_name}` → `{library_name}` (lines 10–11); "All backend media" → "All library media" (line 14)
- `start_http_server` doc comment: `(backend_name: str)` → `(library_name: str)` (line 68)
- `proxy_media`: `backend = request.path_params["backend"]` → `library = request.path_params["library"]`
- `wally_connection_fn(backend)` → `wally_connection_fn(library)`
- Error message: `"... for backend '{backend}'"` → `"... for library '{library}'"`
- URL: `f'{kind}/{backend}/{rest}'` → `f'{kind}/{library}/{rest}'`
- Log: `kind, backend, rest, exc` → `kind, library, rest, exc`
- Route: `Route("/{kind}/{backend}/{rest:path}", ...)` → `Route("/{kind}/{library}/{rest:path}", ...)`

### 4. `gallery/src/App.svelte`

- `let backendName = $state(null)` → `let libraryName = $state(null)`
- `backendName = session.backend` → `libraryName = session.library`
- Thumbnail URL: `encodeURIComponent(backendName)` → `encodeURIComponent(libraryName)` (line 85)
- Preview URL: `encodeURIComponent(backendName)` → `encodeURIComponent(libraryName)` (line 108)

### 5. `gallery/src/lib/bridge.js` (docs only)

- Protocol comment: `{ type: 'ui/initialize', httpPort, backend }` → `{ ..., library }`
- JSDoc line 41: "carries the httpPort and backend" → "carries the httpPort and library"
- JSDoc line 42: `{ httpPort: number, backend: string }` → `{ httpPort: number, library: string }`

### 6. `tests/test_gallery_session_manager.py`

- Helper `_manager_with_sessions`: `backend_name=s.get("backend", "lib")` → `library_name=s.get("library", "lib")`
- `test_create_stores_session`: `session["backend"]` → `session["library"]`
- All test session dicts: `{"backend": ...}` → `{"library": ...}`
- All `data["backend"]` assertions → `data["library"]`
- Rename `test_merge_joins_backend_names` → `test_merge_joins_library_names`
- Rename `test_merge_deduplicates_backend_names` → `test_merge_deduplicates_library_names`

### 7. `tests/test_http_server.py`

- All session dicts: `"backend": "testlib"` → `"library": "testlib"`
- Assertion: `data["backend"]` → `data["library"]`

### 8. `tests/test_server.py`

In the `browse_gallery` tests (session setup and result assertions):
- Session dicts `"backend": "testlib"` / `"backend": "lib1"` etc. → `"library": ...`
- `result["backend"]` → `result["library"]`

**Already done:** `tests_integration/test_startup.py` — fully updated, no changes needed.

---

## Verification

1. Run test suite: `.venv/bin/python -m pytest tests/ -v`
2. Run integration tests: `.venv/bin/python -m pytest tests_integration/ -v` — `test_known_session_returns_200_with_data` (asserts `data["library"]`) now passes
3. Rebuild gallery: `cd gallery && npm run build`
