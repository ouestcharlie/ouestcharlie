# OEC-49: Simplify search_photos MCP tool — drop client-facing pagination

#status:done

Status flow: draft (write spec) -> open (review spec) -> todo (spec validated) -> ongoing (implementation started) -> done (merged)

## Context

Woof's `search_photos` MCP tool exposed pagination concepts (`page`, `pageSize`, `hasMore`)
to the MCP client (Claude), but the client never paginates:

- The tool hardcoded `page = 0` — it was never a parameter.
- Actual page navigation happens later, entirely inside the gallery's HTTP backend via
  `GallerySession.fetch_page`, which re-issues the Wally query with the target page.
- The client's only actionable output is the `session_token`, which it hands to `browse_gallery`.

So `page`, `pageSize`, and `hasMore` in the return payload were noise: they described Wally's
first server page, not "all matches," and the client could do nothing with them. `totalCount`
is the one paging-adjacent value with legitimate client use (framing a `query_summary`).

**Intended outcome:** `search_photos` returns only what the MCP client can act on — an opaque
`session_token`, a `totalCount`, and error reporting — and pagination lives entirely where it is
implemented (the gallery HTTP backend).

---

## Changes

### 1. Trim the return payload and move `page` out of stored query args

**File:** `ouestcharlie-woof/src/woof/mcp_server.py` (`_search_photos_tool`)

- Drop `page`, `pageSize`, `hasMore` from the returned dict; keep `session_token`, `totalCount`,
  `errors`, `errorDetails`.
- Stop baking `page` into `args`. `GallerySession.fetch_page` already overrides it via
  `{**self.queryArgs, "page": page}`, so the stored `queryArgs` need no `page` key. The initial
  Wally call passes `page=0` explicitly (`{**args, "page": 0}`).
- Update the tool docstring: state that matches are held server-side, pagination is a gallery
  concern, and only `session_token`/`totalCount`/`errors`/`errorDetails` are returned.

### 2. Tests

**File:** `ouestcharlie-woof/tests/test_mcp_server.py`

- `test_search_photos_calls_wally` — assert the Wally call still requests `page == 0`.
- `test_search_photos_returns_total_count_and_token` — assert `page`/`pageSize`/`hasMore` are
  absent from the result, and that the stored session's `queryArgs` carry no `page` key.

### 3. Documentation

- `ouestcharlie-woof/doc/design/woof_LLD.md` — update the `search_photos` return-payload example
  and the session-schema `queryContext.args` example to drop `page`/`pageSize`/`hasMore` (and the
  stale `pageStats`); note that the MCP client never paginates and that `fetch_page` supplies the
  page per request.

---

## Verification

- `cd ouestcharlie-woof && .venv/bin/pytest tests/test_mcp_server.py -v`
- `search_photos` returns `{session_token, totalCount, errors, errorDetails}` only.
- Gallery server-page navigation (`GET /api/results/{token}/page/{N}`) still works — `fetch_page`
  supplies the page onto the stored `queryArgs`.
