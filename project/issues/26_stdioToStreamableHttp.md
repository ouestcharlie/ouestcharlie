# OEC-26: Migrate local MCP agents from stdio to Streamable HTTP

#status:open

## Context

Local MCP servers using stdio transport are increasingly poorly supported by the MCP ecosystem. Woof already runs a dual-transport setup: Wally (the persistent preview/search agent) uses Streamable HTTP, while Whitebeard (the ephemeral indexing agent) still uses stdio via `StdioServerParameters`/`stdio_client`. The HTTP-serving logic (Starlette app, bearer-auth middleware, ephemeral port binding, uvicorn serving, `<NAME>_READY port=<n>` stdout signal) currently lives duplicated inside Wally's own `__main__.py` rather than in the shared `AgentBase` toolkit class, so it isn't reusable by other agents.

Decision: full migration — convert Whitebeard to Streamable HTTP using the same pattern Wally already proved out, and move the generic HTTP-serving machinery into `AgentBase` itself so any future agent gets it for free. No dual-mode/pluggable-stdio fallback; stdio code paths should be removed, not kept as an option.

---

## Changes

### 1. `AgentBase` gains native HTTP serving

**File:** `ouestcharlie-py-toolkit/src/ouestcharlie_toolkit/server.py`

Move the generic parts of Wally's `__main__.py` into `AgentBase`:
- `_bind_free_port()` helper (ephemeral loopback port binding).
- `_BearerGuard` Starlette middleware (currently in `wally/__main__.py:37-52`) — move into `server.py` or a new `ouestcharlie_toolkit/http_transport.py`.
- An async serve routine (modeled on Wally's `_serve()`) that binds the port, wraps the ASGI app with the bearer guard, serves via uvicorn, and prints `<NAME>_READY port=<n>` (derived from `self.name`) once started.
- Replace `AgentBase.run()` (currently a thin `self.mcp.run()` stdio call) with:
  ```python
  def run_http(
      self,
      *,
      asgi_wrapper: Callable[[ASGIApp], ASGIApp] | None = None,
      on_shutdown: Callable[[], Awaitable[None]] | None = None,
  ) -> None: ...
  ```
  `asgi_wrapper` is the extension point Wally needs for its `MediaMiddleware`; `on_shutdown` covers Wally's `media.close()` cleanup.
- Remove `run()` entirely (no dual-mode requirement) and update call sites.
- Add `starlette` and `uvicorn` as direct dependencies in `ouestcharlie-py-toolkit/pyproject.toml` (currently only declared by Wally).

Wally's `__main__.py` shrinks to constructing `MediaMiddleware` and calling `agent.run_http(asgi_wrapper=..., on_shutdown=media.close)`.

Whitebeard's `__main__.py` shrinks to `agent.run_http()` — no custom middleware, no port binding, no bearer guard duplication. Add `starlette`/`uvicorn` deps to `ouestcharlie-whitebeard/pyproject.toml` (currently absent).

### 2. Unify Woof's sidecar handling

**File:** `ouestcharlie-woof/src/woof/agent_client.py`

Generalize `_WallySidecar` → `_AgentSidecar`, parameterized by `module` and `ready_prefix` (e.g. `WALLY_READY` / `WHITEBEARD_READY`) instead of hardcoding `"wally"`. This single class covers both lifetime policies:

- **Wally**: persistent — kept warm in `_wally_sidecars` dict across calls (unchanged behavior, just renamed class).
- **Whitebeard**: ephemeral — spawn → single `call_tool()` → `stop()` inline, no dict entry. Keep Whitebeard spawn-per-call, not kept warm, since indexing calls are infrequent/one-at-a-time with no concurrent-serving need (unlike Wally's preview JPEG serving between calls). This avoids idle-timeout/teardown complexity for no benefit.

```python
# Before (stdio, ~lines 354-386)
async def _call_ephemeral(self, ...):
    async with stdio_client(StdioServerParameters(...)) as (read, write):
        ...

# After
async def _call_ephemeral(self, module, tool_name, args, library, progress_cb) -> Any:
    sidecar = _AgentSidecar(module=module, ready_prefix=f"{module.upper()}_READY")
    env = self._build_env(library)
    try:
        await sidecar.start([sys.executable, "-m", module], env)
        result = await sidecar.call_tool(tool_name, args, progress_cb)
    finally:
        await sidecar.stop()
    # same isError / json.loads handling as before
```

- Remove `StdioServerParameters`/`stdio_client` imports and the stdio branch entirely.
- `AgentClient.call_tool()` no longer needs a `module == "wally"` branch for transport; the only remaining difference is persistent (dict-cached) vs. ephemeral (inline) sidecar reuse.
- Update the class docstring to describe ephemeral-vs-persistent lifecycle rather than stdio-vs-HTTP transport.

Note (not a blocker, flag in PR description): no mutex prevents two concurrent ephemeral Whitebeard calls for the same library — pre-existing behavior, unchanged by this migration.

### 3. Other agents

Confirmed via `grep -rl "AgentBase"`: only Whitebeard and Wally consume `AgentBase` today. No further ripple.

### 4. Documentation

- `ouestcharlie/HLD.md` (~line 465): replace the stdio-default/HTTP-for-separate-processes language with a single-transport statement — all agents use Streamable HTTP regardless of process model; port discovery via `<NAME>_READY port=<n>` stdout line.
- `ouestcharlie-woof/doc/design/woof_LLD.md` (~lines 214-236): remove the stdio transport bullet; update the Whitebeard lifecycle table row to "ephemeral — spawned per call over HTTP, torn down immediately after"; rename "Agent launch (stdio transport)" section to "Agent launch (Streamable HTTP)"; generalize "Wally port discovery" to "Agent port discovery" since both agents now share the convention.
- `ouestcharlie-py-toolkit/py_toolkit_LLD.md` (~lines 27-35): update `AgentBase` responsibilities to describe the HTTP-serving duties explicitly (port binding, bearer auth, `<NAME>_READY` signal, uvicorn serving, `asgi_wrapper`/`on_shutdown` hooks).
- `ouestcharlie/HLD_rationale.md` (~line 278): replace the multi-transport rationale with a single-transport one — uniform Streamable HTTP simplifies `AgentBase`/`AgentClient` to one code path; negligible loopback overhead is offset by eliminating dual transports and easing future containerization. Soften any nearby table row implying this project uses both transports.

---

## Verification

- **Unit tests (`ouestcharlie-py-toolkit/tests/`)**: `AgentBase.run_http()` prints the `<NAME>_READY` line, enforces bearer auth (401 without token / 200 with), applies `asgi_wrapper` and fires `on_shutdown` on termination.
- **Unit tests (`ouestcharlie-woof/tests/`)**: generalize existing Wally sidecar tests to `_AgentSidecar`; add a Whitebeard-specific test for spawn → single call → stop, mocking the subprocess and a fake `WHITEBEARD_READY port=<n>` line; assert `stdio_client` is no longer imported/used.
- **Integration test**: spawn a real Whitebeard subprocess over HTTP end-to-end against a fixture photo library; compare manifest/XMP output against the current stdio-based expectations.
- **Manual checks**:
  1. Run Whitebeard standalone with `WOOF_BACKEND_CONFIG` set, confirm `WHITEBEARD_READY port=<n>` prints and it serves HTTP.
  2. Run Woof against a real library, trigger indexing, confirm logs show the `_AgentSidecar` start/stop path for Whitebeard.
  3. Regression-check Wally end-to-end (preview serving, bearer auth, search) since its `__main__.py` shrinks significantly.
  4. Run `.venv/bin/pytest tests/ -v` in woof, whitebeard, wally, and py-toolkit repos.

### Critical files
- `ouestcharlie-py-toolkit/src/ouestcharlie_toolkit/server.py`
- `ouestcharlie-py-toolkit/pyproject.toml`
- `ouestcharlie-wally/src/wally/__main__.py`
- `ouestcharlie-whitebeard/src/whitebeard/__main__.py`
- `ouestcharlie-whitebeard/pyproject.toml`
- `ouestcharlie-woof/src/woof/agent_client.py`
- `ouestcharlie-woof/doc/design/woof_LLD.md`, `ouestcharlie/HLD.md`, `ouestcharlie/HLD_rationale.md`, `ouestcharlie-py-toolkit/py_toolkit_LLD.md`
