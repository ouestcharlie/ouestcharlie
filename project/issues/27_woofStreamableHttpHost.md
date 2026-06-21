# OEC-27: Migrate Woof's host-facing MCP interface from stdio to local Streamable HTTP

## Context

This covers the MCP boundary between the AI assistant host (Claude Desktop, Goose, etc.) and Woof itself — distinct from OEC-26 which covers the Woof-to-agent (Wally/Whitebeard) transport. Woof currently starts via `mcp.run()` (stdio), spawned per-session by the host via a `command`/`args` entry in `claude_desktop_config.json`. Stdio-launched local MCP servers are increasingly poorly supported, so Woof should serve Streamable HTTP instead, strictly on loopback.

Decisions:
- **Bridge required**: Claude Desktop still spawns a stdio process per session; that process is now a thin bridge forwarding to Woof's local HTTP endpoint.
- **Lazy start, stays running**: the bridge starts Woof on first connection if not already running (via a discovery file), and Woof persists until explicitly stopped. No OS service installation required.
- **Dual-mode with flag**: keep stdio available (`WOOF_TRANSPORT=stdio|http`, default `http`) — unlike OEC-26's hard cutover, the host-client compatibility risk justifies a fallback during transition.

---

## Changes

### 1. Merge gallery + MCP into one ASGI app, one uvicorn server

**Files:** `src/woof/server.py`, `src/woof/http_server.py`

Mount `self.mcp.streamable_http_app()` at `/mcp` alongside existing gallery routes. Refactor `http_server._build_app` to return a mountable route list/sub-app instead of its own top-level `Starlette` + `CORSMiddleware`. Wrap once at the top with bearer guard + Host/Origin validation (see Security below). FastMCP's ASGI lifespan propagates through `Mount`, so `_lifespan` startup/shutdown logic (agent client, tasks) attaches to the outer app's lifespan instead of being implicit in `mcp.run()`.

Remove the second `asyncio.create_task(serve_in_loop(...))` wiring from `server.py:61-79` — in HTTP mode, `__main__.py` drives one unified uvicorn server directly.

### 2. Discovery file for port/token (replaces stdout readiness signal)

**File:** new `src/woof/security.py` (or `src/woof/discovery.py`)

Since no parent process actively reads Woof's stdout once it runs persistently in the background, replace the `<NAME>_READY port=<n>` convention (used for child-process agents) with a **discovery file** written atomically on startup to a well-known OS-appropriate path (e.g. `~/.local/share/ouestcharlie/woof.json` / `~/Library/Application Support/ouestcharlie/woof.json`), mode `0600`, containing `{"port": <n>, "token": "<bearer-token>"}`. Token is persisted across restarts so the bridge doesn't need to re-handshake mid-session.

### 3. Dual-mode entrypoint

**File:** `src/woof/__main__.py`

Add `WOOF_TRANSPORT=stdio|http` flag (env var or CLI, default `http`):
- **`http` mode**: build combined app, bind socket to `127.0.0.1:0`, write discovery file, run `uvicorn.Server(...).serve(sockets=[sock])`.
- **`stdio` mode**: keep existing `mcp.run()` path unchanged — preserves `mcp dev src/woof/__main__.py` inspector workflow.

### 4. Thin stdio bridge

**File:** new `src/woof/bridge.py` + `woof-bridge` console-script entry point in `pyproject.toml`

Small first-party Python bridge (no Node.js/`mcp-remote` dependency):
1. Check discovery file for a live Woof instance (verify the port actually responds).
2. If not running, launch Woof as a detached background process (lazy start).
3. Wait for discovery file, read `{port, token}`.
4. Proxy stdio MCP framing ↔ `http://127.0.0.1:<port>/mcp`, injecting `Authorization: Bearer <token>` on every forwarded request.

`manifest.json` and `README.md` install instructions point at `woof-bridge` instead of `woof` directly.

### 5. Security

**File:** new `src/woof/security.py`

- Keep binding to `127.0.0.1` strictly (already true at `server.py:54`; never widen to `0.0.0.0`).
- Add bearer guard (ported from Wally's `_BearerGuard`, `wally/__main__.py:37-52`) on all routes including `/mcp` and gallery/media routes.
- Replace `CORSMiddleware(allow_origins=["*"])` (`http_server.py:268`) with Host/Origin validation middleware accepting only `127.0.0.1:<port>` / `localhost:<port>` — standard DNS-rebinding mitigation per MCP's Streamable HTTP security guidance.

**Open item**: the gallery iframe's `fetch()` calls (Svelte app under `gallery/src/`, not yet inspected) hit the now-protected routes from inside Claude Desktop's webview and will need the bearer token threaded into their JS context. Needs a read of `gallery/src` before implementing — likely embedded in the resource HTML Woof serves at `_GALLERY_URI`, or injected as a query param scoped to the existing `/gallery/<token>` path.

### 6. Install/config updates

- `manifest.json` — update `.mcpb` bundle's `server.mcp_config` command to `woof-bridge`.
- `README.md` — rewrite `claude_desktop_config.json` snippet (`command`/`args` now point to the bridge); update Goose stdio block likewise; document `WOOF_TRANSPORT=stdio` for dev/debugging.
- `doc/design/woof_LLD.md` / `woof_LLD_rationale.md` — add a host-facing transport section: Woof is now an HTTP server to its host AND an HTTP/stdio client to its agents; document discovery-file convention and bridge rationale.

---

## Verification

- **Unit tests**: spin up the combined app in-process; assert `/mcp` answers `initialize`; gallery routes still serve; missing/wrong bearer token → 401; forged `Host` header → 403 (DNS-rebinding regression).
- **Bridge tests**: "no running Woof" → bridge lazy-starts it, discovery file appears, proxy works; "Woof already running" → bridge reuses it without spawning a second instance.
- **End-to-end manual**: point Claude Desktop config at `woof-bridge`, confirm tool list loads, run search/gallery tool, confirm gallery iframe renders with no CSP console errors.
- **Stdio regression**: `WOOF_TRANSPORT=stdio` + `mcp dev` inspector workflow still works.
- `venv/bin/pytest tests/ -v` in ouestcharlie-woof.

### Critical files
- `src/woof/__main__.py`
- `src/woof/server.py`
- `src/woof/http_server.py`
- `src/woof/security.py` (new)
- `src/woof/bridge.py` (new)
- `pyproject.toml` (add `woof-bridge` console-script)
- `manifest.json`
- `README.md`
- `ouestcharlie-wally/src/wally/__main__.py` (reference pattern, not modified)
- `gallery/src/` (needs inspection before implementing token injection)
