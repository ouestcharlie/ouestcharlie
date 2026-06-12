# OEC#21b — Merge Woof MCP and HTTP event loops

#status:done

## Context

Woof currently runs two asyncio event loops in separate threads:
- **MCP loop** (main thread) — FastMCP stdio server, agent coordination, Wally calls
- **HTTP loop** (daemon thread) — Starlette/uvicorn, gallery serving, media proxy

Communication between them goes via `asyncio.run_coroutine_threadsafe` + `Future.result(timeout=60)` in `_sync_fetch`, plus `run_in_executor` on the HTTP side to avoid blocking its loop. This produces unnecessary complexity: `_main_loop` field, `_FetchPageProxy`, `make_sync_fetch_page_fn`, and the sync/async bridge.

Since FastMCP's `_lifespan` runs as an `asynccontextmanager` on the MCP loop, uvicorn can be started as an `asyncio.create_task` there — eliminating the second loop and all cross-thread coordination.

## Approach

Start uvicorn as an asyncio task inside `_lifespan` instead of a daemon thread. With both servers on the same loop, `fetch_page_fn` becomes a plain async coroutine and `api_page` awaits it directly — no thread bridging required.

Uvicorn is asyncio-native: each HTTP connection becomes an asyncio task on the shared loop, so concurrent request handling is unchanged. The risk is that synchronous blocking work on the shared loop would now stall both HTTP responses and MCP message processing. Mitigations already in place: `_async_fetch` awaits `self._agent.call_tool(...)` and the media proxy uses `httpx.AsyncClient`. **Rule for new code:** any synchronous work longer than ~1 ms must use `await loop.run_in_executor(None, fn, ...)`.

## Implementation

### `src/woof/server.py`

**`WoofServer.__init__`**
- Bind the HTTP socket here (sync, before MCP starts): `sock.bind(("127.0.0.1", 0))`
- Store `self._http_sock` and `self.server_url = f"http://localhost:{port}"`
- Remove `server_url` constructor parameter
- Add `self.fetch_page_fn: Any = None` (set by caller after init)
- Remove `self._main_loop`

**`_lifespan`**
- Replace `self._main_loop = asyncio.get_running_loop()` with:
  ```python
  http_task = asyncio.create_task(
      _serve_http_coro(self._http_sock, self._sessions, self._agent, self.fetch_page_fn, self.server_url)
  )
  ```
- On shutdown (`finally`): `http_task.cancel(); await asyncio.gather(http_task, return_exceptions=True)`
- Keep `await agent.shutdown()`
- Document in docstring: synchronous blocking work must go through `run_in_executor`

**`make_fetch_page_fn`** (rename from `make_sync_fetch_page_fn`)
- Return `_async_fetch` directly (already exists as inner async function)
- Remove `_sync_fetch`, `asyncio.run_coroutine_threadsafe`, `Future.result`

### `src/woof/http_server.py`

**New `async def _serve_http_coro(sock, session_manager, agent, fetch_page_fn, server_url)`**
- Equivalent to current `_serve(app, sock, ready)` but without the `threading.Event`
- Called as a task from `_lifespan`

**`_build_app` / `api_page`**
- Change `fetch_page_fn` type annotation to `Callable[[SessionData, int], Awaitable[bool]]`
- Replace:
  ```python
  loop = asyncio.get_event_loop()
  ok = await loop.run_in_executor(None, fetch_page_fn, session, page)
  ```
  with:
  ```python
  ok = await fetch_page_fn(session, page)
  ```

**Keep `start_http_server()`** unchanged — used by tests (threaded, synchronous start).

### `src/woof/__main__.py`

```python
_session_manager = GallerySessionManager()
_agent = AgentClient()
_server = WoofServer(_config, agent_client=_agent, session_manager=_session_manager)
_server.fetch_page_fn = _server.make_fetch_page_fn()
mcp = _server.mcp

def main() -> None:
    mcp.run()
```

Remove: `_FetchPageProxy`, `start_http_server` call/import, `_wally_connection_fn` (move into WoofServer as a method using `self._agent`).

### `tests/test_http_server.py`

Change sync `def fetch_fn(session, page)` callbacks to `async def fetch_fn(session, page)` in all tests that supply a `fetch_page_fn`. The threaded `start_http_server()` event loop can `await` async callables natively — no other changes needed.

## What is removed

| Removed | Why |
|---|---|
| `_main_loop: AbstractEventLoop` field | No cross-loop submission needed |
| `_sync_fetch` inner function | Replaced by direct `await` of `_async_fetch` |
| `asyncio.run_coroutine_threadsafe` | Same loop, plain `await` suffices |
| `run_in_executor` in `api_page` | `fetch_page_fn` is now a native coroutine |
| `_FetchPageProxy` class | `WoofServer.fetch_page_fn` attr set post-init |
| `server_url` constructor parameter | Computed from self-bound socket |
| Daemon `threading.Thread` for HTTP | uvicorn runs as a task on MCP loop |

## Verification

1. `mcp dev src/woof/__main__.py` — server starts, gallery opens, pagination works
2. `.venv/bin/python -m pytest tests/test_http_server.py -v` — all tests pass
3. `.venv/bin/python -m pytest tests/ -v` — full suite passes
