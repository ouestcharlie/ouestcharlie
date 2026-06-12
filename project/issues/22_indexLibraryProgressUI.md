# OEC#22 — Index library progress UI

#status:inprogress

## Context

`index_library` blocks until Whitebeard completes, which causes two problems:

1. **Timeout**: MCP tool calls time out after roughly 60–120 s; indexing a large
   library takes minutes. Claude Desktop terminates the call before it finishes.
2. **No UI**: Claude's built-in progress bar (`ctx.report_progress`) is minimal —
   no detail text, no per-partition breakdown, and it disappears when the call
   returns.

The fix: make `index_library` launch Whitebeard as a background asyncio task,
return immediately, and open the existing gallery MCP App in a new "indexing
mode" that polls for real-time progress.  When indexing completes, the app
pushes the summary back to the model context so Claude has it in the next turn.

## Approach

```
Claude calls index_library(library_name, ...)
  → Woof starts Whitebeard as asyncio.Task
  → returns {type:"indexing", session_id, serverUrl, ...}
  → host opens gallery MCP App in indexing mode

Gallery MCP App (indexing mode)
  polls GET /api/indexing/{session_id} every second
  renders progress bar + status message
  when status = "completed":
    calls app.callServerTool("get_index_result", {session_id})
    displays summary inline
    calls app.updateModelContext({content: [summary markdown]})
  when status = "failed":
    displays error message
    calls app.updateModelContext({content: ["Indexing failed: ..."]})
```

The gallery MCP App resource (`ui://gallery/ouestcharlie`) is reused — the
mode is determined by the `type` field in the tool result pushed by
`ontoolresult`. This avoids a second Vite build pipeline.

## Implementation

### 1 — `woof/indexing_session_manager.py` (new file)

Session shape:

```json
{
  "session_id":   "...",
  "library_name": "kDrive Photos",
  "partition":    "",
  "status":       "running | completed | failed",
  "progress":     42.0,
  "total":        1234.0,
  "message":      "Indexing 2024/07... (42/1234)",
  "summary":      null,
  "error":        null,
  "started_at":   "2026-05-28T10:31:00Z"
}
```

Methods:

- `start(library_name, partition) → session_id` — generates `secrets.token_urlsafe(16)`, stores initial session, returns id.
- `update(session_id, progress, total, message)` — overwrites `progress`, `total`, `message` in place.  No-op if session not found.
- `complete(session_id, summary)` — sets `status = "completed"`, stores `summary` dict.
- `fail(session_id, error)` — sets `status = "failed"`, stores `error` string.
- `get(session_id) → dict | None`

Thread-safety: no locking needed.  `serve_in_loop` runs the HTTP server as an
`asyncio.Task` on the **same event loop as FastMCP** — all mutations and reads
happen on that loop.  Simple `dict` operations are therefore single-threaded.

Capacity: cap at 20 sessions (indexing runs are infrequent); evict the oldest
when at capacity.

### 2 — `agent_client.py` — `AgentClient.call_tool_background()`

New method that wraps `_call_ephemeral` in an `asyncio.Task` and returns
immediately:

```python
def call_tool_background(
    self,
    module: str,
    tool_name: str,
    args: dict[str, Any],
    library: LibraryConfig,
    *,
    on_progress: Callable[[float, float | None, str | None], Awaitable[None]] | None = None,
    on_complete: Callable[[Any], None] | None = None,
    on_error: Callable[[Exception], None] | None = None,
) -> asyncio.Task:
```

The internal coroutine:

```python
async def _run():
    try:
        result = await self._call_ephemeral(
            module, tool_name, args, library,
            progress_cb=_make_progress_forwarder_fn(on_progress),
        )
        if on_complete:
            on_complete(result)
    except AgentError as exc:
        _log.error("%s.%s background task failed: %s", module, tool_name, exc)
        if on_error:
            on_error(exc)
    except Exception as exc:
        _log.error("%s.%s background task unexpected error: %s", module, tool_name, exc, exc_info=True)
        if on_error:
            on_error(exc)

return asyncio.create_task(_run(), name=f"{module}-bg")
```

`_make_progress_forwarder_fn` is a variant of `_make_progress_forwarder` that
wraps an arbitrary async callable instead of a `Context`.

`on_progress`, `on_complete`, and `on_error` are called from inside the asyncio
task, i.e. on the MCP event loop.  Since `IndexingSessionManager` requires no
locking (same loop), the callbacks can be plain synchronous callable functions.

### 3 — `server.py`

#### `index_library` (modified)

Remove `result = await ...`, launch background task, return immediately:

```python
@mcp.tool(
    annotations=ToolAnnotations(destructiveHint=True),
    app=AppConfig(resource_uri=_GALLERY_URI),
)
async def index_library(
    library_name: str,
    partition: str = "",
    force_extract_exif: bool = False,
    generate_thumbnails: bool = True,
    force_full_index: bool = False,
) -> dict[str, Any]:
    """…docstring unchanged…"""
    library = self._require_library(library_name)
    tool = "index_partition" if partition else "index_library"
    args: dict[str, Any] = {
        "force_extract_exif": force_extract_exif,
        "generate_thumbnails": generate_thumbnails,
        "force_full_index": force_full_index,
    }
    if partition:
        args["partition"] = partition

    session_id = self._indexing_sessions.start(library_name, partition)

    def _on_progress(progress: float, total: float | None, message: str | None) -> None:
        self._indexing_sessions.update(
            session_id, progress, total or 1.0, message or ""
        )

    def _on_complete(result: Any) -> None:
        self._indexing_sessions.complete(session_id, result)

    def _on_error(exc: Exception) -> None:
        self._indexing_sessions.fail(session_id, str(exc))

    self._agent.call_tool_background(
        "whitebeard", tool, args, library,
        on_progress=_on_progress,
        on_complete=_on_complete,
        on_error=_on_error,
    )

    return {
        "type": "indexing",
        "session_id": session_id,
        "library_name": library_name,
        "partition": partition,
        "serverUrl": self.server_url,
    }
```

Note: `ctx: Context` parameter is removed — no `ctx.report_progress()` since
the tool returns before Whitebeard finishes.

#### New tool `get_index_result`

```python
@mcp.tool(annotations=ToolAnnotations(readOnlyHint=True))
async def get_index_result(session_id: str) -> dict[str, Any]:
    """Return the current state or final result of a background indexing run.

    Args:
        session_id: The session_id returned by index_library.
    """
    session = self._indexing_sessions.get(session_id)
    if session is None:
        return {"error": f"Unknown session_id {session_id!r}"}
    return session
```

#### `WoofServer.__init__` additions

```python
from .indexing_session_manager import IndexingSessionManager

self._indexing_sessions = IndexingSessionManager()
```

Pass `self._indexing_sessions` to `serve_in_loop` (and `start_http_server` in tests — see §4).

### 4 — `http_server.py`

#### Signature updates

`serve_in_loop` is the production path (HTTP and MCP share one asyncio loop).
Add `indexing_session_manager` to it and to `_build_app`:

```python
async def serve_in_loop(
    sock: socket.socket,
    session_manager: GallerySessionManager,
    wally_connection_fn: Any | None,
    server_url: str,
    indexing_session_manager: Any | None = None,   # ← new
) -> None:
    app = _build_app(
        session_manager, wally_connection_fn,
        server_url=server_url,
        indexing_session_manager=indexing_session_manager,
    )
    await _serve_bare(app, sock)
```

`start_http_server` (test-only path) gets the same new parameter:

```python
def start_http_server(
    session_manager: GallerySessionManager | None = None,
    wally_connection_fn: Any | None = None,
    indexing_session_manager: Any | None = None,   # ← new
) -> str:
```

`_build_app` gains the parameter and passes it into the `api_indexing` closure.

#### New route `GET /api/indexing/{session_id}`

```python
async def api_indexing(request: Request) -> Response:
    if indexing_session_manager is None:
        return JSONResponse({"error": "not configured"}, status_code=503)
    sid = request.path_params["session_id"]
    session = indexing_session_manager.get(sid)
    if session is None:
        return JSONResponse({"error": f"Session {sid!r} not found"}, status_code=404)
    return JSONResponse(session)
```

Add to `routes`:

```python
Route("/api/indexing/{session_id}", api_indexing),
```

No cross-loop or locking concerns: `serve_in_loop` puts HTTP and MCP on the
same asyncio event loop, so `IndexingSessionManager.get()` is a plain dict read
on the loop that also runs the MCP callbacks.

#### URL scheme comment

Add to the module docstring:

```
  GET /api/indexing/{session_id}               — JSON indexing session state
```

### 5 — Gallery Svelte app (`gallery/src/`)

#### `App.svelte` — indexing mode detection

In `ontoolresult`, branch on `result.type`:

```js
app.ontoolresult = async ({ content }) => {
  const text = (content ?? []).find(b => b.type === 'text')?.text;
  if (!text) return;
  const result = JSON.parse(text);

  if (result.type === 'indexing') {
    serverUrl = result.serverUrl;
    indexingSessionId = result.session_id;
    indexingLibrary = result.library_name;
    indexingPartition = result.partition ?? '';
    mode = 'indexing';
    loading = false;
    return;
  }

  // existing gallery path: result.type === 'gallery' or legacy (no type field)
  serverUrl = result.serverUrl;
  // … fetch session, call applySession, etc.
};
```

New state variables: `mode = $state('gallery')`, `indexingSessionId = $state(null)`,
`indexingLibrary = $state('')`, `indexingPartition = $state('')`.

In the template, branch on `mode`:

```svelte
{#if mode === 'indexing'}
  <IndexingProgress
    {serverUrl}
    sessionId={indexingSessionId}
    library={indexingLibrary}
    partition={indexingPartition}
    {mcpApp}
  />
{:else}
  <!-- existing PhotoGrid / PreviewPanel markup -->
{/if}
```

#### New component `gallery/src/components/IndexingProgress.svelte`

Props: `serverUrl`, `sessionId`, `library`, `partition`, `mcpApp`.

State: `status`, `progress`, `total`, `message`, `summary`, `error`.

Behaviour:

- On mount: start polling `GET {serverUrl}/api/indexing/{sessionId}` every 1 s.
  Update local state from each response.
- Stop polling when `status !== 'running'`.
- When `status === 'completed'`:
  1. Call `mcpApp.callServerTool({name: 'get_index_result', arguments: {session_id: sessionId}})`.
  2. Extract summary text from result content.
  3. Display summary inline.
  4. Call `mcpApp.updateModelContext({content: [{type: 'text', text: summaryMarkdown}]})`.
- When `status === 'failed'`:
  1. Display error.
  2. Call `mcpApp.updateModelContext({content: [{type: 'text', text: 'Indexing failed: ' + error}]})`.

UI elements:

- Library name + partition (header)
- Progress bar: `<progress value={progress} max={total}>`
- Status message text (current file / phase)
- On completion: summary card (photos indexed, sidecars updated, thumbnails,
  errors)
- On failure: error text in red

Theming: use the same design tokens (`--color-text-primary`,
`--color-background-surface`, etc.) as the rest of the gallery so light/dark
mode works automatically.

`callServerTool` and `updateModelContext` are only called when `mcpApp` is
non-null (i.e., we are inside the MCP host).  In the `?sessionId=` standalone
dev path, these calls are skipped and the summary is shown only inline.

#### Standalone dev path (`?sessionId=`)

Mirror the gallery's `?token=` path: if `location.search` contains `sessionId`,
set `serverUrl = location.origin`, populate state from
`GET {serverUrl}/api/indexing/{sessionId}`, and start polling.  Useful for
testing the UI outside Claude Desktop.

## Unit Tests

### `tests/test_indexing_session_manager.py` (new file)

```python
def test_start_returns_token_and_status_running():
    mgr = IndexingSessionManager()
    sid = mgr.start("lib", "")
    s = mgr.get(sid)
    assert s["status"] == "running"
    assert s["library_name"] == "lib"

def test_update_writes_progress():
    mgr = IndexingSessionManager()
    sid = mgr.start("lib", "2024")
    mgr.update(sid, 42.0, 100.0, "msg")
    s = mgr.get(sid)
    assert s["progress"] == 42.0
    assert s["total"] == 100.0
    assert s["message"] == "msg"

def test_complete_stores_summary():
    mgr = IndexingSessionManager()
    sid = mgr.start("lib", "")
    mgr.complete(sid, {"photosIndexed": 99})
    s = mgr.get(sid)
    assert s["status"] == "completed"
    assert s["summary"]["photosIndexed"] == 99

def test_fail_stores_error():
    mgr = IndexingSessionManager()
    sid = mgr.start("lib", "")
    mgr.fail(sid, "boom")
    s = mgr.get(sid)
    assert s["status"] == "failed"
    assert s["error"] == "boom"

def test_get_unknown_returns_none():
    mgr = IndexingSessionManager()
    assert mgr.get("no-such") is None

def test_eviction_at_capacity():
    mgr = IndexingSessionManager(max_sessions=2)
    sid1 = mgr.start("l", "")
    sid2 = mgr.start("l", "")
    sid3 = mgr.start("l", "")  # should evict sid1
    assert mgr.get(sid1) is None
    assert mgr.get(sid2) is not None
    assert mgr.get(sid3) is not None
```

### `tests/test_http_server.py` (additions)

```python
def test_indexing_endpoint_returns_session():
    from woof.indexing_session_manager import IndexingSessionManager
    imgr = IndexingSessionManager()
    sid = imgr.start("lib", "")
    server_url = start_http_server(indexing_session_manager=imgr)
    with urllib.request.urlopen(f"{server_url}/api/indexing/{sid}") as resp:
        data = json.load(resp)
    assert data["status"] == "running"

def test_indexing_endpoint_unknown_returns_404():
    server_url = start_http_server()
    with pytest.raises(urllib.error.HTTPError) as exc_info:
        urllib.request.urlopen(f"{server_url}/api/indexing/nope")
    assert exc_info.value.code == 404
```

### `gallery/src/components/IndexingProgress.test.js` (new file)

```js
describe('IndexingProgress', () => {
  it('shows progress bar while running', async () => {
    global.fetch = vi.fn().mockResolvedValue({
      ok: true,
      json: () => Promise.resolve({ status: 'running', progress: 50, total: 100, message: 'foo' }),
    });
    const { container } = render(IndexingProgress, { serverUrl: '', sessionId: 'x', library: 'L', partition: '', mcpApp: null });
    await vi.runAllTimersAsync();
    expect(container.querySelector('progress').value).toBe(50);
  });

  it('calls mcpApp.callServerTool and updateModelContext on completion', async () => {
    const callServerTool = vi.fn().mockResolvedValue({ isError: false, content: [{ type: 'text', text: '{"summary":{"photosIndexed":5}}' }] });
    const updateModelContext = vi.fn().mockResolvedValue({});
    const mcpApp = { callServerTool, updateModelContext };
    global.fetch = vi.fn().mockResolvedValue({
      ok: true,
      json: () => Promise.resolve({ status: 'completed', summary: { photosIndexed: 5 } }),
    });
    render(IndexingProgress, { serverUrl: '', sessionId: 'x', library: 'L', partition: '', mcpApp });
    await vi.runAllTimersAsync();
    expect(callServerTool).toHaveBeenCalledWith({ name: 'get_index_result', arguments: { session_id: 'x' } });
    expect(updateModelContext).toHaveBeenCalled();
  });

  it('shows error on failure', async () => {
    global.fetch = vi.fn().mockResolvedValue({
      ok: true,
      json: () => Promise.resolve({ status: 'failed', error: 'disk full' }),
    });
    const { getByText } = render(IndexingProgress, { serverUrl: '', sessionId: 'x', library: 'L', partition: '', mcpApp: null });
    await vi.runAllTimersAsync();
    expect(getByText(/disk full/)).toBeTruthy();
  });
});
```

## LLD Documentation Updates

### `woof_LLD.md`

1. **HTTP server URL scheme** — add:
   ```
   GET /api/indexing/{session_id}   — JSON indexing session state
   ```
2. **`index_library`** — update description: non-blocking, opens gallery app in
   indexing mode, returns `{type:"indexing", session_id, serverUrl, ...}`.
3. **Gallery MCP App** — add "Indexing mode" sub-section: triggered when tool
   result carries `type:"indexing"`, renders `IndexingProgress` component,
   polls `/api/indexing/{session_id}`, calls `callServerTool`/`updateModelContext`
   on completion.
4. **New section: Indexing session manager** — describe `IndexingSessionManager`,
   session shape, capacity/eviction, single-loop concurrency model (no locking).
5. **New section: Background agent tasks** — describe `call_tool_background`,
   callback contract, asyncio task lifecycle.

## Verification

1. Index a small library (< 500 photos). Progress UI opens immediately; bar
   advances; summary appears when done.
2. Index a large library (> 1 000 photos). Tool call returns in < 2 s; progress
   UI shows incremental updates; no MCP timeout.
3. After completion, the next message to Claude includes the indexing summary
   in model context (`updateModelContext` was called).
4. Force a failure (invalid library path). `status = "failed"` appears in the
   app; error text visible.
5. `get_index_result(session_id)` called directly by Claude returns the same
   data as the app's final state.
6. Standalone dev: `http://localhost:{port}/gallery?sessionId={sid}` shows
   progress without requiring Claude Desktop.
