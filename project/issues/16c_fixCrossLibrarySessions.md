# OEC#16c — Fix cross-library sessions: move `library` into each match

#status:done

## Context

Sessions currently store `"library"` (a string) and `"httpPort"` (an int) at the top level. This is wrong for merged sessions: when two libraries are merged, `library` becomes the lossy string `"lib1, lib2"`, which cannot be used as a URL path segment for Wally routing. The fix is to embed `"library"` into each individual match at creation time, so the HTTP proxy always routes to the correct Wally sidecar regardless of how sessions were merged.

`"httpPort"` is removed too because `App.svelte` can reliably derive it from `window.location.port` — the gallery is always served by Woof's HTTP server at that port.

---

## Critical Files

| File | What changes |
|------|-------------|
| `src/woof/gallery_session_manager.py` | Embed `library` in each match; remove `library`/`httpPort` from session; drop `http_port` param |
| `src/woof/server.py` | Drop `self.http_port` arg from `create`/`merge`; remove `library`/`httpPort` from `browse_gallery` return |
| `gallery/src/App.svelte` | Replace `libraryName` state + `httpPort` state with `window.location.port` constant; read `match.library` per match |
| `tests/test_gallery_session_manager.py` | Remove `http_port` from all `create`/`merge` calls; update session assertions; repurpose library-name tests |
| `tests/test_http_server.py` | Remove `library`/`httpPort` from session dicts; add `library` to matches; update assertions |
| `tests/test_server.py` | Remove `library`/`httpPort` from session dicts and `browse_gallery` result assertions |

---

## Changes

### 1. `src/woof/gallery_session_manager.py`

**`create` signature:** `create(self, library_name: str, matches: list[Any], http_port: int)` → `create(self, library_name: str, matches: list[Any])`

**`create` body:** Before sorting, stamp `library` onto every match:
```python
stamped = [{**m, "library": library_name} for m in matches]
```
Session dict becomes:
```python
{"matches": _sort_by_date(stamped), "querySummary": ""}
```
(remove `"library"` and `"httpPort"` keys)

**`merge` signature:** `merge(self, tokens, query_summary, http_port)` → `merge(self, tokens, query_summary)`

**`merge` body:** Remove `library_names` accumulation (matches already carry `"library"`). Session dict becomes:
```python
{"matches": _sort_by_date(merged_matches), "querySummary": query_summary}
```
(remove `"library"` and `"httpPort"` keys)

**Class docstring:** Update the session shape example — remove `"library"` and `"httpPort"` lines; add `"library": str` to the match record note.

### 2. `src/woof/server.py`

Line ~235: `self._sessions.create(library_name, matches, self.http_port)` → `self._sessions.create(library_name, matches)`

Line ~274: `self._sessions.merge(session_tokens, query_summary, self.http_port)` → `self._sessions.merge(session_tokens, query_summary)`

`browse_gallery` return dict (lines ~276-280): remove `"library": data["library"]` and `"httpPort": self.http_port`. Keep `"matches"`, `"querySummary"`, `"galleryUrl"`.

### 3. `gallery/src/App.svelte`

- Remove `let httpPort = $state(null)` and `let libraryName = $state(null)`.
- Add a non-reactive constant before `onMount`:
  ```javascript
  const httpPort = window.location.port ? parseInt(window.location.port) : 80;
  ```
- `applySession`: remove `httpPort = session.httpPort ?? httpPort` and `libraryName = session.library`.
- `onMount` Path 1: remove `httpPort = port` (constant is already set).
- `thumbnailTile`:
  - Guard: `if (!match.library || !avifHash || match.tileIndex == null)`
  - URL: `encodeURIComponent(match.library)` instead of `encodeURIComponent(libraryName)`
- `previewUrl`:
  - Guard: `if (!match.library || !match.contentHash)`
  - URL: `encodeURIComponent(match.library)` instead of `encodeURIComponent(libraryName)`

### 4. `tests/test_gallery_session_manager.py`

- `_manager_with_sessions`: drop `http_port=s.get("http_port", 9999)` from `mgr.create()` call.
- All direct `mgr.create("lib", [], 9999)` calls → `mgr.create("lib", [])`.
- All `mgr.merge([...], ..., 9999)` calls → `mgr.merge([...], ...)`.
- `test_create_stores_session`:
  - Remove `assert session["library"] == "mylib"` and `assert session["httpPort"] == 8080`.
  - Add `assert session["matches"][0]["library"] == "mylib"`.
  - Keep `assert session["querySummary"] == ""`.
- `test_merge_joins_library_names` → rename to `test_merge_preserves_match_library_field`: verify that after merging two sessions, each match still carries its original `library` value.
- `test_merge_deduplicates_library_names` → remove or repurpose (the concept no longer exists at session level).
- Any remaining `data["library"]` or `session["library"]` assertions → check `session["matches"][i]["library"]`.

### 5. `tests/test_http_server.py`

- `test_gallery_token_route_serves_html`, `test_cors_header_present_on_responses`, `test_results_endpoint_returns_session_data`:
  - Session dicts: remove `"library"` and `"httpPort"` top-level fields; add `"library"` inside each match.
  - `assert data["library"] == "testlib"` → `assert data["matches"][0]["library"] == "testlib"`.

### 6. `tests/test_server.py`

- Session setup dicts passed to `_sessions.sessions[token]`: remove `"library"` and `"httpPort"`.
- `browse_gallery` result assertions: remove `assert result["library"] == ...` and `assert result["httpPort"] == ...`.

---

## Verification

1. Run unit tests: `.venv/bin/python -m pytest tests/ -v` — all tests pass.
2. Rebuild gallery: `cd gallery && npm run build` — no Svelte/TypeScript errors.
3. Manual smoke test: start Woof, call `search_photos` then `browse_gallery`; open the gallery URL; confirm thumbnails and previews load for photos from each library.
