# OEC#19 — browse_gallery: stop routing photo data through Claude

#status:done

## Context

`browse_gallery` currently returns `"matches": [...]` (up to 500 photo records) in its MCP
tool result. The MCP host (Claude) relays this JSON blob to the gallery iframe via
`app.ontoolresult`. The Woof HTTP server already stores the session server-side and exposes
`GET /api/results/{token}`; there is no reason for the payload to transit Claude.

A previous attempt (return only the token, fetch via HTTP) stalled on a CSP violation.
That blocker no longer exists: `_register_gallery_resource` sets
`connect_domains=[origin]` with the runtime-assigned port.

The URL `?token=` fallback path (direct browser access) already fetches the session from the
HTTP server correctly; this issue aligns the MCP Apps postMessage path with that approach.

## Approach

Three coordinated changes:

1. **`gallery_session_manager.py`** — store Wally's `totalCount` in each session, so
   `browse_gallery` can report it without recomputing from `len(matches)`.
2. **`server.py`** — strip `"matches"` from `browse_gallery`'s return dict; expose the merged
   session token instead.
3. **`gallery/src/App.svelte`** — update `ontoolresult` to fetch session data from the HTTP
   server, mirroring the URL fallback path.

## Implementation

### `gallery_session_manager.py`

`create()` — accept and store the Wally-provided total count:

```python
def create(self, library_name: str, matches: list[Any], total_count: int | None = None) -> str:
    token = secrets.token_urlsafe(16)
    stamped = [{**m, "library": library_name} for m in matches]
    self._add_session(token, {
        "matches": stamped,
        "querySummary": "",
        "totalCount": total_count if total_count is not None else len(stamped),
    })
    return token
```

`merge()` — store the deduplicated count:

```python
session_data: dict[str, Any] = {
    "matches": merged_matches,
    "querySummary": query_summary,
    "totalCount": len(merged_matches),
}
```

### `server.py` — `search_photos` (line ~243)

Pass `totalCount` from Wally when creating the session:

```python
token = self._sessions.create(
    library_name, matches,
    total_count=result.get("totalCount"),
)
```

### `server.py` — `browse_gallery` (lines 286-292)

Remove `"matches"`. Return `"token"` and `"totalCount"` from the session:

```python
merged_token, data = self._sessions.merge(session_tokens, query_summary)
return {
    "token": merged_token,
    "querySummary": query_summary,
    "serverUrl": self.server_url,
    "galleryUrl": f"{self.server_url}/gallery?token={merged_token}",
    "totalCount": data["totalCount"],
}
```

### `gallery/src/App.svelte` — `ontoolresult` handler (lines 49-52)

Replace the direct `applySession(JSON.parse(text))` call with an HTTP fetch:

```js
app.ontoolresult = async ({ content }) => {
  const text = (content ?? []).find(b => b.type === 'text')?.text;
  if (!text) return;
  const result = JSON.parse(text);
  // Set serverUrl from tool result before fetching — in the MCP iframe context
  // location.origin is ui://… not the HTTP server.
  serverUrl = result.serverUrl;
  try {
    const data = await fetch(`${serverUrl}/api/results/${result.token}`)
      .then(r => r.ok ? r.json() : Promise.reject(new Error(r.statusText)));
    applySession(data);
  } catch (err) {
    status = `Error loading gallery: ${err.message}`;
    loading = false;
  }
};
```

`serverUrl` must be set from the tool result before `applySession` runs because:
- In the MCP iframe context `location.origin` is `ui://…`, not the HTTP server URL.
- `applySession` uses `session.serverUrl ?? serverUrl` — the fetched session dict does
  not carry `serverUrl`, so the outer variable must be set first.

The URL `?token=` fallback path (lines 35-41) is unchanged.

## Verification

1. Start Woof + Wally; trigger `search_photos` then `browse_gallery` in Claude Desktop.
2. Confirm the tool result text contains `"token"` and `"totalCount"` but no `"matches"` key.
3. Confirm the gallery loads correctly — photos visible, thumbnails and previews working.
4. In Woof HTTP logs: `GET /api/results/{token}` returns 200 with the full matches array.
5. Test direct browser access (`http://127.0.0.1:<port>/gallery?token=…`) still works.
