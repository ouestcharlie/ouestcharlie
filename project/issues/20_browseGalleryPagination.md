# OEC#20 — browse_gallery: auto-fetch all server-side search pages

#status:discarded

Superseded by OEC#21

## Context

`search_photos` fetches one page (≤ 500 photos) from Wally. If Wally returns `hasMore: true`
the remaining photos are inaccessible to the gallery — the AI assistant would have to issue
repeated `search_photos` calls and pass all tokens to `browse_gallery`, which it does not do
automatically.

Depends on OEC#19 (`gallery_session_manager.create()` must accept `total_count`).

## Approach

Modify `search_photos` to auto-fetch all remaining Wally pages within the same MCP tool call
(same event loop, no cross-thread complexity), up to a safety cap of `_MAX_SEARCH_PAGES = 20`
pages (10 000 photos). All matches are stored in a single session.

## Implementation

### `server.py` — `search_photos` (around lines 233-253)

```python
_MAX_SEARCH_PAGES = 20

# First call (already in place)
result = await self._agent.call_tool("wally", "search_photos", args, library, progress_ctx=ctx)
matches: list[Any] = result.get("matches", [])
total_count: int = result.get("totalCount", len(matches))
pages_loaded = 1

# Auto-fetch remaining pages
while result.get("hasMore") and pages_loaded < _MAX_SEARCH_PAGES:
    pages_loaded += 1
    args_next = {**args, "page": pages_loaded}
    try:
        result = await self._agent.call_tool(
            "wally", "search_photos", args_next, library, progress_ctx=ctx
        )
    except AgentError as exc:
        _log.error("search_photos page %d fetch failed: %s", pages_loaded, exc)
        break
    matches.extend(result.get("matches", []))

truncated = result.get("hasMore", False)

token = self._sessions.create(library_name, matches, total_count=total_count)
return {
    "session_token": token,
    "totalCount": total_count,      # Wally's reported total (may exceed loaded count if truncated)
    "pagesLoaded": pages_loaded,
    "hasMore": False,               # all available pages are now in the session
    "truncated": truncated,         # True if safety cap was hit (>10 000 results)
    "errors": result.get("errors", 0),
    "errorDetails": result.get("errorDetails", []),
    "pageStats": self._search_stats(matches, fields),
}
```

Key behaviors:
- `hasMore: false` in the return — all available pages are in the session.
- Wally's `totalCount` from the first call is preserved even when matches are truncated, so
  the user and Claude can see the real library count vs. how many were loaded.
- A failed mid-loop page breaks the loop; partial results are still stored and served.

### `doc/design/woof_LLD.md`

Document auto-pagination in the `search_photos` section:
- Cap at `_MAX_SEARCH_PAGES` pages / 10 000 photos.
- `truncated` and `pagesLoaded` field semantics.

## Trade-off

First-response latency increases proportionally to additional Wally page calls. With LanceDB's
async columnar queries this is typically fast (< 1 s/page). The 20-page cap bounds worst-case
delay and prevents runaway fetches on very large libraries.

## Verification

1. Index a library with > 500 photos.
2. Call `search_photos` with no filters; confirm `pagesLoaded > 1` and `hasMore: false`.
3. Call `browse_gallery` with the returned token; confirm the gallery shows all photos.
4. Verify client-side pagination (3-row pages, Prev/Next) works correctly over the full set.
5. Confirm `truncated: true` appears when total results exceed 10 000.
