# OEC-27: Migrate Woof's host-facing MCP interface from stdio to local Streamable HTTP

#status:done

## Context

This covers the MCP boundary between the AI assistant host (Claude Desktop, Goose, etc.) and Woof itself — distinct from OEC-26 which covers the Woof-to-agent (Wally/Whitebeard) transport. Woof currently starts via `mcp.run()` (stdio), spawned per-session by the host via a `command`/`args` entry in `claude_desktop_config.json`. Stdio-launched local MCP servers are increasingly poorly supported, so Woof should serve Streamable HTTP instead, strictly on loopback.

**Confirmed real-world motivation (2026-07-21, debugging OEC-32):** Claude CoWork opens more than one logical MCP connection to Woof within a single session (e.g. one for the gallery app iframe, another for tool invocation). Since Woof is stdio-only, each connection spawns an independent subprocess with its own ephemeral port. The gallery iframe loads with one instance's port baked into its CSP; when a tool call is answered by a *different* instance (different port), the iframe's `fetch()` is correctly CSP-blocked — the port it needs was never declared, because that instance didn't exist yet when the iframe's CSP was fixed. No CSP configuration can fix this: it requires exactly one Woof process system-wide, which is what this migration's discovery-file + bridge design already provides. (OEC-32's `server_urls` dual-hostname CSP fix — `localhost` vs `127.0.0.1`, needed because Chat and CoWork each reject the other — remains necessary independently of this migration and should be preserved once Woof is single-instance.)

Decisions:
- **Bridge required**: Claude Desktop still spawns a stdio process per session; that process is now a thin bridge forwarding to Woof's local HTTP endpoint.
- **Lazy start, stays running**: the bridge starts Woof on first connection if not already running (via a discovery file), and Woof persists until explicitly stopped. No OS service installation required.
- **Dual-mode with flag**: keep stdio available (`WOOF_TRANSPORT=stdio|http`, default `http`) — unlike OEC-26's hard cutover, the host-client compatibility risk justifies a fallback during transition.
- **Idle self-shutdown, no cross-process reference counting**: since multiple bridges can share one Woof instance and none of them individually knows if it's the "last" one, Woof tracks its own active-connection state and shuts itself down after an idle timeout rather than relying on bridges to coordinate a shutdown decision (see §2).

---

## Changes

### 1. Merge gallery + MCP into one ASGI app, one uvicorn server; dual-mode entrypoint

**Files:** `src/woof/server.py`, `src/woof/http_server.py`, `src/woof/__main__.py`

Mount `self.mcp.streamable_http_app()` at `/mcp` alongside existing gallery routes. Refactor `http_server._build_app` to return a mountable route list/sub-app instead of its own top-level `Starlette` + `CORSMiddleware`. Wrap once at the top with bearer guard + Host/Origin validation (see Security, §4). FastMCP's ASGI lifespan propagates through `Mount`, so `_lifespan` startup/shutdown logic (agent client, tasks) attaches to the outer app's lifespan instead of being implicit in `mcp.run()`.

Remove the second `asyncio.create_task(serve_in_loop(...))` wiring from `server.py:61-79` — in HTTP mode, `__main__.py` drives one unified uvicorn server directly.

`__main__.py` gains a `WOOF_TRANSPORT=stdio|http` flag (env var or CLI, default `http`):
- **`http` mode**: build the combined app, bind socket to `127.0.0.1:0`, write the discovery file (§2), run `uvicorn.Server(...).serve(sockets=[sock])`.
- **`stdio` mode**: keep the existing `mcp.run()` path unchanged — preserves the `mcp dev src/woof/__main__.py` inspector workflow.

### 2. Process lifecycle: discovery, locking, and shutdown

**File:** new `src/woof/discovery.py`

This section owns the full lifecycle of the discovery file — creation, concurrent-startup safety, and eventual cleanup — since those are one coherent responsibility rather than separate concerns.

**Discovery file.** Since no parent process actively reads Woof's stdout once it runs persistently in the background, replace the `<NAME>_READY port=<n>` convention (used for child-process agents) with a discovery file written atomically on startup to a well-known OS-appropriate path (e.g. `~/.local/share/ouestcharlie/woof.json` / `~/Library/Application Support/ouestcharlie/woof.json`), mode `0600`, containing `{"pid": <n>, "port": <n>, "token": "<bearer-token>"}`. The token is persisted across restarts so the bridge doesn't need to re-handshake mid-session; the pid is used for staleness detection below.

**Race safety.** If two bridges start at nearly the same instant with no Woof yet running (e.g. CoWork opening two connections back-to-back), both could see a missing/stale discovery file and each try to lazy-start their own instance, defeating the whole point of this migration. Serialize the check-then-spawn sequence with an OS-level advisory lock:
- Acquire an exclusive lock on a sibling file (e.g. `woof.lock`, via `fcntl.flock` on POSIX / `msvcrt.locking` on Windows, or the `filelock` package for a cross-platform wrapper) before checking the discovery file.
- Under the lock: check the discovery file → validate it (see staleness detection below) → if missing/stale, spawn Woof and wait for the fresh discovery file → release the lock.
- A second bridge blocked on the lock will, after acquiring it, see the discovery file the first bridge just wrote and skip spawning entirely.
- Bound the wait with a timeout (e.g. 10s) in case the lock holder's spawn attempt hangs or crashes, so a wedged bridge doesn't wedge every subsequent connection.

**Crash / stale-file detection.** Verify both that the pid is alive *and* that the port responds to an authenticated health check — pid-only isn't enough (the pid could be reused by an unrelated process after a crash) and port-only isn't enough (a different process could rebind that ephemeral port after Woof dies). If either check fails, treat the file as stale, delete it, and proceed to lazy-start.

**Idle self-shutdown.** Since multiple bridges can share one Woof instance and none of them individually knows if it's the "last" connection, shutdown can't be a bridge-initiated reference count — that's inherently racy across separate processes. Instead, Woof decides for itself:
- Each proxied `/mcp` request, and a lightweight periodic authenticated `/keepalive` ping sent by each bridge while its stdio session is alive, updates a `last_active` timestamp inside Woof's own process.
- A background task checks this timestamp and calls `uvicorn.Server.should_exit = True` (clean ASGI shutdown) after an idle threshold (e.g. 10–15 minutes) with zero active connections.
- A bridge that crashes without cleanly disconnecting is naturally forgotten once its keepalives stop, rather than leaking an active-connection count forever (see §3 for the bridge side of this).

**Explicit stop and clean-exit cleanup.**
- Add a `woof --stop` CLI path (and/or `woof-bridge --stop`) that reads the discovery file, sends an authenticated `POST /shutdown`, waits briefly for the process to exit, and removes the discovery file. Useful for manual cleanup, uninstall, and tests.
- On any graceful shutdown (idle timeout, `/shutdown`, or `SIGTERM`), Woof removes its own discovery file as part of ASGI lifespan teardown, so a subsequent bridge doesn't need to rely solely on the pid/port checks above.

### 3. Thin stdio bridge

**File:** new `src/woof/bridge.py` + `woof-bridge` console-script entry point in `pyproject.toml`

Small first-party Python bridge (no Node.js/`mcp-remote` dependency):
1. Acquire the discovery lock (§2).
2. Check the discovery file for a live Woof instance (pid + port health check, §2).
3. If not running, launch Woof as a detached background process (lazy start) and wait for the fresh discovery file.
4. Release the lock; read `{port, token}`.
5. Proxy stdio MCP framing ↔ `http://127.0.0.1:<port>/mcp`, injecting `Authorization: Bearer <token>` on every forwarded request.
6. For as long as its stdio connection to the host stays open, send `/keepalive` on an interval shorter than Woof's idle threshold (§2); stop on disconnect.
7. Support a `--stop` flag that delegates to Woof's `/shutdown` path (§2).

`manifest.json` and `README.md` install instructions point at `woof-bridge` instead of `woof` directly.

### 4. Security

**File:** new `src/woof/security.py`

- Keep binding to `127.0.0.1` strictly (already true at `server.py:54`; never widen to `0.0.0.0`).
- Add bearer guard (ported from Wally's `_BearerGuard`, `wally/__main__.py:37-52`) on all routes including `/mcp`, `/keepalive`, `/shutdown`, and gallery/media routes.
- Replace `CORSMiddleware(allow_origins=["*"])` (`http_server.py:268`) with Host/Origin validation middleware accepting only `127.0.0.1:<port>` / `localhost:<port>` — standard DNS-rebinding mitigation per MCP's Streamable HTTP security guidance.

### 5. Frontend bearer-token threading

The gallery iframe's `fetch()` calls now all funnel through one module, `gallery/src/lib/api.svelte.js` (added in OEC-32) — every request (`fetchResults`, `fetchResultsPage`, `fetchIndexingStatus`, `cancelIndexing`) goes through its single internal `request()` helper, and `thumbnailUrl`/`previewUrl` are the only other places that build a Woof URL. This makes bearer-token threading a small, localized change:

- Extend `get_gallery_html()` (`http_server.py`) to also embed the token in the existing `data-server-urls`-style page data (e.g. a sibling `data-server-token` attribute on `<html>`, or fold it into the JSON already carried by `data-server-urls`) — same CSP-safe pattern (no inline `<script>`) OEC-32 established.
- Extend tool results that already carry `serverUrls` (`search_photos`/indexing/`browse_gallery` in `server.py`) with a `serverToken` field, mirroring how `serverUrls` is refreshed per tool call in case of a restart.
- In `api.svelte.js`, extend `initServerOrigins` (or add a sibling `initServerToken`) to store the token in module state, and have `request()` attach `Authorization: Bearer <token>` to every call.
- `thumbnailUrl`/`previewUrl` return plain URLs consumed by `<img src>`, which cannot carry an `Authorization` header — these will need the token as a query param instead (the Starlette route reads it from either the header or the query string), since browsers don't support custom headers on image loads.

### 6. Install/config updates

- `manifest.json` — update `.mcpb` bundle's `server.mcp_config` command to `woof-bridge`.
- `README.md` — rewrite `claude_desktop_config.json` snippet (`command`/`args` now point to the bridge); update Goose stdio block likewise; document `WOOF_TRANSPORT=stdio` for dev/debugging; document `woof --stop` for manual cleanup.
- `doc/design/woof_LLD.md` / `woof_LLD_rationale.md` — add a host-facing transport section: Woof is now an HTTP server to its host AND an HTTP/stdio client to its agents; document the discovery-file convention, bridge rationale, and idle-shutdown/keepalive lifecycle.

---

## Verification

- **Unit tests**: spin up the combined app in-process; assert `/mcp` answers `initialize`; gallery routes still serve; missing/wrong bearer token → 401; forged `Host` header → 403 (DNS-rebinding regression).
- **Lifecycle tests**: idle timeout actually triggers shutdown when no keepalives arrive; a live bridge's keepalives prevent shutdown; `woof --stop` terminates a running instance and removes the discovery file; a stale discovery file (dead pid, or port rebound to an unrelated process) is detected and cleaned up rather than the bridge mistakenly reusing it.
- **Bridge tests**: "no running Woof" → bridge lazy-starts it, discovery file appears, proxy works; "Woof already running" → bridge reuses it without spawning a second instance. Include a test simulating two concurrent bridge connections (the CoWork scenario that motivated this issue) and assert both resolve to the same port/instance, and assert only one Woof process is ever spawned (i.e. the discovery lock actually serializes the race rather than both bridges spawning before either writes the file).
- **End-to-end manual**: point Claude Desktop config at `woof-bridge`, confirm tool list loads, run search/gallery tool, confirm gallery iframe renders with no CSP console errors — specifically retest the CoWork multi-connection scenario from OEC-32 (gallery iframe open, then a tool call fired from a separate connection) and confirm the iframe's `fetch()` now succeeds since both connections resolve to the one running instance's port.
- **Stdio regression**: `WOOF_TRANSPORT=stdio` + `mcp dev` inspector workflow still works.
- `venv/bin/pytest tests/ -v` in ouestcharlie-woof.

### Critical files
- `src/woof/__main__.py`
- `src/woof/server.py`
- `src/woof/http_server.py`
- `src/woof/discovery.py` (new) — discovery file, advisory lock, staleness checks, idle-shutdown timer (§2)
- `src/woof/bridge.py` (new) — includes keepalive loop and `--stop` path (§3)
- `src/woof/security.py` (new) — bearer guard, Host/Origin validation (§4)
- `pyproject.toml` (add `woof-bridge` console-script; add `filelock` dependency if used for the cross-platform lock)
- `manifest.json`
- `README.md`
- `ouestcharlie-wally/src/wally/__main__.py` (reference pattern, not modified)
- `gallery/src/lib/api.svelte.js` (OEC-32) — single chokepoint for bearer-token injection on all `fetch()` calls (§5)
- `gallery/src/App.svelte` — reads the embedded `data-server-urls`-style page data; token threading extends the same mechanism (§5)
