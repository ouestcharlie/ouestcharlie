# OEC#21 — Double pagination: gallery-driven server page navigation

#status:done

## Context

Two independent pagination layers exist and are unaware of each other:

1. **Wally pagination** — `search_photos` returns ≤ 500 photos per page. `totalCount`
   and `hasMore` are returned but only the first page is stored in `GallerySessionManager`.
2. **Gallery pagination** — `PhotoGrid.svelte` slices the in-memory `matches` array into
   3 × columns-wide display pages. `pageCount = ceil(matches.length / pageSize)` is
   bounded by loaded photos, not `totalCount`.

Users see at most 500 photos regardless of library size, and the gallery page counter
is wrong for large queries.

Supersedes OEC#20 (eager server-side pre-fetch of up to 20 pages).

Requires a minor breaking change: both Wally's and Woof's `search_photos` tools
switch from 1-indexed to **0-indexed** page numbers (Wally currently converts
internally via `page - 1`; removing that conversion makes the public interface
consistent with the 0-based offset model used by LanceDB).

## Approach

- **`GallerySessionManager`** stores the query context (library, Wally args, current
  server page number, `pageSize`, `totalCount`) alongside the matches for that one page.
- A new HTTP endpoint `GET /api/results/{token}/page/{page}` fetches the requested
  server page (replacing the session's current matches) and returns the updated session.
- **Gallery** derives `hasMore = (page + 1) * pageSize < totalCount` locally — no stored
  boolean needed. When the user navigates past the last display-page of the current
  server page it calls `/page/{page+1}`; when navigating before the first it calls
  `/page/{page-1}`. Photo indices are absolute across all server pages: the first photo
  of server page 1 (0-indexed) has display index 500.

The session always holds exactly one server page of matches — no memory accumulation.

## Implementation

### `gallery_session_manager.py`

Extend session schema with a `queryContext` field (absent on merged sessions from
`browse_gallery`):

```
{
    "matches":      list[dict],
    "querySummary": str,
    "totalCount":   int,        # Wally's authoritative total for the query
    "queryContext": {           # None for merge-created sessions (browse_gallery)
        "library_name": str,
        "args":         dict,   # wally search_photos args (root, sort_by, …)
        "page":         int,    # current 0-indexed server page stored in matches
        "pageSize":     int,    # 500 — needed for absolute index calculation
    } | None,
}
```

Add `replace_page(token, matches, page)` that swaps the current matches and updates
`page` inside `queryContext` in place.

### `http_server.py`

New endpoint `GET /api/results/{token}/page/{page}`:
- Calls `async fetch_page_fn(token: str, page: int) -> bool` passed to
  `start_http_server`.
- On success: replaces session matches and returns the full updated session JSON
  (same shape as `GET /api/results/{token}`).
- On error: `{"error": "not_found" | "no_context" | "out_of_range" | <message>}`.

Requesting the already-loaded page is idempotent — returns cached data without a
Wally round-trip.

**Cross-event-loop note**: `start_http_server` runs its own asyncio loop in a daemon
thread; `WoofServer._agent.call_tool` runs on FastMCP's main loop. `fetch_page_fn`
must bridge these loops (e.g. `asyncio.run_coroutine_threadsafe`). Open implementation
detail to resolve at coding time.

### `server.py`

Modify `search_photos` to use 0-indexed `page` (default `page: int = 0`) and persist
query context:

```python
token = self._sessions.create(
    library_name, matches,
    total_count=result.get("totalCount"),
    query_context={
        "library_name": library_name,
        "args": args,
        "page": 0,
        "pageSize": result.get("pageSize", 500),
    },
)
```

Implement `fetch_page_fn(token, page)` in `WoofServer`:
1. Read session → get `queryContext`.
2. Call Wally `search_photos` with `args | {"page": page}`.
3. Call `self._sessions.replace_page(token, new_matches, page)`.

Pass `fetch_page_fn` to `start_http_server`.

### `gallery/src/App.svelte`

- Read `totalCount` and `queryContext` from session data.
- Add `fetchServerPage(page)`: `GET /api/results/{token}/page/{page}`, then update
  local session state with the returned JSON.
- Pass `fetchServerPage`, `totalCount`, `serverPage = queryContext?.page`,
  `pageSize = queryContext?.pageSize` to `PhotoGrid`.

### `gallery/src/components/PhotoGrid.svelte`

New props: `totalCount: number`, `serverPage: number`, `pageSize: number`,
`onFetchServerPage: (page: number) => Promise<void>`.

`hasMore` is derived: `(serverPage + 1) * pageSize < totalCount`.

**Absolute page counting (all 0-indexed):**
```
serverPageOffset  = serverPage * pageSize         // absolute index of first loaded photo
totalDisplayPages = ceil(totalCount / displayPageSize)
localPage         = floor(selectedIndex / displayPageSize)
absolutePage      = floor(serverPageOffset / displayPageSize) + localPage
```

**Navigation:**
- `nextPage()`: if local next page overflows server page → call
  `onFetchServerPage(serverPage + 1)` then reset `selectedIndex = 0`.
- `prevPage()`: if `localPage === 0` and `serverPage > 0` → call
  `onFetchServerPage(serverPage - 1)` then set `selectedIndex` to last photo of new page.
- Nav bar: "Page {absolutePage + 1} / {totalDisplayPages}".
- Show loading skeleton while a server page fetch is in flight.

## Unit Tests

### Server — `tests/test_gallery_session_manager.py` (additions)

```python
def test_create_stores_query_context() -> None:
    mgr = GallerySessionManager()
    qc = {"library_name": "lib", "args": {}, "page": 0, "pageSize": 500}
    token = mgr.create("lib", [], query_context=qc)
    assert mgr.sessions[token]["queryContext"] == qc

def test_create_without_query_context_is_none() -> None:
    mgr = GallerySessionManager()
    token = mgr.create("lib", [])
    assert mgr.sessions[token]["queryContext"] is None

def test_replace_page_updates_matches_and_page() -> None:
    mgr = GallerySessionManager()
    qc = {"library_name": "lib", "args": {}, "page": 0, "pageSize": 500}
    token = mgr.create("lib", [_match("h1")], query_context=qc)
    mgr.replace_page(token, [_match("h500")], page=1)
    session = mgr.sessions[token]
    assert session["queryContext"]["page"] == 1
    assert session["matches"][0]["contentHash"] == "h500"

def test_replace_page_unknown_token_is_no_op() -> None:
    mgr = GallerySessionManager()
    mgr.replace_page("no-such-token", [], page=1)  # must not raise

def test_merge_result_has_no_query_context() -> None:
    mgr, [tok] = _manager_with_sessions({"matches": [_match("h1")]})
    merged_token, data = mgr.merge([tok], "q")
    assert data.get("queryContext") is None
```

### Server — `tests/test_http_server.py` (additions)

```python
def test_page_endpoint_idempotent_for_current_page() -> None:
    # Requesting the already-loaded page returns session data without calling fetch_page_fn.
    fetch = AsyncMock(return_value=True)
    mgr = GallerySessionManager()
    qc = {"library_name": "lib", "args": {}, "page": 0, "pageSize": 500}
    mgr.sessions["tok"] = {"matches": [], "querySummary": "", "totalCount": 1, "queryContext": qc}
    server_url = start_http_server(session_manager=mgr, fetch_page_fn=fetch)
    urllib.request.urlopen(f"{server_url}/api/results/tok/page/0")
    fetch.assert_not_called()

def test_page_endpoint_unknown_token_returns_404() -> None:
    server_url = start_http_server()
    with pytest.raises(urllib.error.HTTPError) as exc_info:
        urllib.request.urlopen(f"{server_url}/api/results/nope/page/1")
    assert exc_info.value.code == 404

def test_page_endpoint_no_context_returns_error() -> None:
    mgr = GallerySessionManager()
    mgr.sessions["tok"] = {"matches": [], "querySummary": "", "totalCount": 0, "queryContext": None}
    server_url = start_http_server(session_manager=mgr)
    with pytest.raises(urllib.error.HTTPError) as exc_info:
        urllib.request.urlopen(f"{server_url}/api/results/tok/page/1")
    assert exc_info.value.code == 400

def test_page_endpoint_calls_fetch_page_fn_and_returns_updated_session() -> None:
    fetched = {}
    async def fetch_fn(token, page):
        fetched["token"] = token
        fetched["page"] = page
        return True
    mgr = GallerySessionManager()
    qc = {"library_name": "lib", "args": {}, "page": 0, "pageSize": 500}
    mgr.sessions["tok"] = {"matches": [], "querySummary": "", "totalCount": 600, "queryContext": qc}
    server_url = start_http_server(session_manager=mgr, fetch_page_fn=fetch_fn)
    with urllib.request.urlopen(f"{server_url}/api/results/tok/page/1") as resp:
        assert resp.status == 200
    assert fetched == {"token": "tok", "page": 1}
```

### Client — `gallery/src/components/PhotoGrid.test.js` (additions)

```js
// jsdom: columns=1, displayPageSize=3
describe('PhotoGrid — server-page-aware total count', () => {
  it('uses totalCount for pageCount when provided', () => {
    // 3 local matches but totalCount=600 → ceil(600/3)=200 pages
    const { getAllByText } = render(PhotoGrid, makeProps({
      matches: makeMatches(3),
      totalCount: 600, serverPage: 0, pageSize: 500,
      onFetchServerPage: vi.fn(),
    }));
    expect(getAllByText(/200/)[0]).toBeTruthy();
  });

  it('Next at last local page triggers onFetchServerPage when more exist', async () => {
    const onFetchServerPage = vi.fn();
    // 3 local matches = 1 display page; totalCount=600 means more server pages
    const { getAllByText } = render(PhotoGrid, makeProps({
      matches: makeMatches(3),
      totalCount: 600, serverPage: 0, pageSize: 500,
      onFetchServerPage,
    }));
    await fireEvent.click(getAllByText(/Next/)[0].closest('button'));
    expect(onFetchServerPage).toHaveBeenCalledWith(1);
  });

  it('Previous at first local page triggers onFetchServerPage when serverPage > 0', async () => {
    const onFetchServerPage = vi.fn();
    const { getAllByText } = render(PhotoGrid, makeProps({
      matches: makeMatches(3),
      totalCount: 600, serverPage: 1, pageSize: 500,
      onFetchServerPage,
    }));
    await fireEvent.click(getAllByText(/Previous/)[0].closest('button'));
    expect(onFetchServerPage).toHaveBeenCalledWith(0);
  });

  it('absolute page reflects server page offset', () => {
    // serverPage=1, pageSize=500, displayPageSize=3 → absolutePage = floor(500/3) + 0 = 166
    const { getAllByText } = render(PhotoGrid, makeProps({
      matches: makeMatches(3),
      totalCount: 1000, serverPage: 1, pageSize: 500,
      onFetchServerPage: vi.fn(),
    }));
    expect(getAllByText(/167/)[0]).toBeTruthy(); // absolutePage+1 = 167
  });
});
```

## LLD Documentation Updates

### `woof_LLD.md`

1. **HTTP server URL scheme** (file header comment): add `GET /api/results/{token}/page/{page}` entry.
2. **`search_photos` return shape**: update `page` field to 0-indexed; remove `hasMore`
   (derived by the gallery from `totalCount`/`page`/`pageSize`); add `queryContext` shape.
3. **Session schema**: document `queryContext` field and its absence in merged sessions.
4. **Gallery pagination section**: replace "3 rows per page within 500 loaded photos"
   description with the double-pagination model — absolute page count from `totalCount`,
   cross-server-page navigation via `GET .../page/{page}`.

### `wally_LLD.md`

Add a note to the `search_photos` section that `page` is 0-indexed (previously 1-indexed;
the internal `page - 1` offset is removed).

## Verification

1. Index a library with > 500 photos.
2. `search_photos` (no filters) → gallery shows ≤ 500 photos; page counter reflects
   `totalCount` (e.g. "Page 1 / 84").
3. Navigate to the display-page crossing the 500-photo mark → `GET .../page/1` fires;
   gallery shows photos 500-999; nav shows correct absolute page.
4. Photo at absolute index 500 is the first result of server page 1 (0-indexed).
5. Navigate back → `GET .../page/0` re-fetches.
6. On last server page, Next is disabled after the final display-page.
7. Merged session (`browse_gallery`) has `queryContext: null`; page endpoint returns
   `{"error": "no_context"}` and gallery hides cross-server-page navigation.
