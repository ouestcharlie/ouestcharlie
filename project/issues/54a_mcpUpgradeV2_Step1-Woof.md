# OEC-54a: Upgrade Python MCP SDK to 2.0 — Step 1: Woof ↔ external clients

#status:done

Status flow: draft (write spec) -> open (review spec) -> todo (spec validated) -> ongoing (implementation started) -> done (merged)

Parent issue: [54_mcpPythonSdk2Upgrade.md](54_mcpPythonSdk2Upgrade.md), Step 1.

## Blocked — dependency resolution cannot be split this way

Attempted implementation hit a hard blocker before any code changes: `uv lock` refuses to
resolve `mcp>=2.0,<3.0.0` for `ouestcharlie-woof` while `ouestcharlie-wally` and
`ouestcharlie-whitebeard` remain pinned to `mcp>=1.27,<2.0.0`:

```
ouestcharlie-wally==0.14.1 depends on mcp>=1.27,<2.0.0
your project depends on mcp>=2.0,<3.0.0 and ouestcharlie-wally
→ unsatisfiable
```

Woof declares `ouestcharlie-whitebeard` and `ouestcharlie-wally` as **editable path
dependencies** (`[tool.uv.sources]`), so `uv` resolves all three into **one shared
lockfile/venv** — it cannot install two different `mcp` majors into that single
environment. `ouestcharlie-py-toolkit` is pinned the same way (`mcp>=1.27,<2.0.0`) and
would hit the same wall if it were in the resolution graph.

This means the Step 1/Step 2 split as scoped — bump Woof's server-facing `mcp` usage
first, defer the agent-client migration — is valid at the *protocol/handshake* level but
**not achievable as two separate dependency states**: there is no way to lock `mcp` 2.x for
Woof alone without also touching (at minimum, loosening the pin of) `wally`, `whitebeard`,
and `py-toolkit` in the same change. The parent issue (54) and this issue need to be
rescoped before implementation resumes — options to weigh: bump all four repos together in
one coordinated change (closer to the original single-PR approach), or loosen the three
agents' `mcp` pins to `>=1.27,<3.0.0` (no code changes there yet) just to unblock Woof's
lock, deferring their actual 2.0 code adaptation to Step 2. No code was changed in
`ouestcharlie-woof` as a result of this attempt (the `pyproject.toml` edit was reverted;
`uv.lock` was never rewritten since resolution failed before a lock could be written).

## Context

Woof's external-client-facing MCP server (`ouestcharlie-woof`) is pinned to
`mcp>=1.27,<2.0.0` (installed `1.29.0`). The MCP spec revision 2026-07-28 replaced the
`initialize`/session-based stateful handshake with a stateless model driven by
per-request `_meta` and an optional `server/discover` RPC. We confirmed via woof-bridge
logs that Goose 1.50.0 already sends `server/discover` as its only handshake attempt and
currently gets a 400 from Woof's `mcp` 1.29.0 SDK — a live regression, not a hypothetical
one.

`mcp` 2.x is a real, installable release (PyPI serves up through `2.2.0`), so this step is
concrete and unblocked. This issue scopes the work to Woof's own MCP-server-facing surface
only — the tool/resource server built via `fastmcp.FastMCP` in `src/woof/mcp_server.py`,
its mount into the ASGI app (`src/woof/asgi_server.py`/`__main__.py`), and the stdio↔HTTP
bridge (`src/woof/bridge.py`), which presents Woof to legacy stdio-only external clients.
Step 2 (agent-side bump in `py-toolkit`/`whitebeard`/`wally`) is out of scope here.

**Adjacent-but-out-of-scope risk to flag**: `src/woof/agent_client.py` uses raw v1 client
primitives (`mcp.ClientSession`, `mcp.client.stdio.stdio_client`,
`mcp.client.streamable_http.streamable_http_client`, `mcp.StdioServerParameters`) to talk
to Whitebeard/Wally — that's Step 2's `Client(target, mode='auto')` migration. Since Woof
has a single `mcp` dependency, bumping it here may break these v1 imports at compile time
even though their functional migration is deferred. This step must keep `agent_client.py`
importable and passing its existing tests (fixing only the minimal compiling breakage,
e.g. an updated import path), without doing the full `Client(mode='auto')` rewrite —
record any such forced fix explicitly in the PR description so Step 2 doesn't duplicate or
undo it.

---

## Changes

### 1. Dependency bump — order of operations

**File:** `ouestcharlie-woof/pyproject.toml`

1. Bump `"mcp>=1.27,<2.0.0"` → `"mcp>=2.0,<3.0.0"` and the `mcp[cli]` dev-group pin (same
   range) — do this first, alone, before touching `fastmcp`.
2. Run `uv lock` and then `.venv/bin/pytest tests/ -v` immediately, with `fastmcp` still
   pinned at `>=3.2`. This answers the fastmcp-compatibility precondition empirically
   instead of guessing:
   - If `fastmcp` 3.2.x resolves against `mcp` 2.x and the suite passes (or fails only on
     expected things — removed `MCP_*` env vars, `mcp.types` relocation) — `fastmcp` stays
     unbumped.
   - If resolution fails (fastmcp 3.2 requires `mcp<2.0`), bump `fastmcp` to the lowest
     release whose deps declare `mcp` 2.x support (check PyPI release notes around fastmcp
     4.0 — 4.0.3 is latest at time of writing). Re-run `uv lock` + full test suite + a
     smoke test of `mcp_server.py`'s tool registration (the decorator API is stated to be
     unchanged, but verify empirically).
3. Only after resolution stabilizes and imports resolve, move to the code-adaptation pass
   (section 2) to fix remaining test failures.
4. Do not attempt the two new integration tests (section 3) until `tests/` is green again
   — they depend on a working server, not the other way around.

### 2. Code changes in Woof's own MCP server construction

Grep-driven, scoped to Woof's actual (narrow) `mcp` usage — not a blind rewrite:

- `src/woof/mcp_server.py:13` — `from mcp.types import ToolAnnotations`. `mcp.types`
  remains available as a compatibility alias in 2.x, so this only *must* change if the
  alias is dropped or a deprecation warning gets turned into a failure (check
  `[tool.pytest.ini_options].filterwarnings` in `pyproject.toml` — currently specific
  ignores only, no blanket "error" filter). Migrate proactively to
  `from mcp_types import ToolAnnotations` for future-proofing.
- `src/woof/bridge.py` — three imports to verify against the 2.0 restructuring:
  - `from mcp.client.streamable_http import streamable_http_client` — the bridge's
    client-side transport to Woof's own `/mcp` HTTP endpoint. This *is* in scope since the
    bridge is external-client-facing. Verify the function survives 2.0 or is now reached
    via `Client(target, mode='auto')`'s low-level transport helpers.
  - `from mcp.server.stdio import stdio_server` — presents Woof to the stdio-spawning
    host; check the restructured low-level `Server` interface doesn't relocate this.
  - `from mcp.shared.message import SessionMessage` — check `mcp.shared` survives the
    `mcp_types` split; this is protocol/session plumbing and a plausible relocation
    candidate.
- `src/woof/mcp_server.py` never touches the bundled SDK's `mcp.server.Server`/`FastMCP`
  directly — Woof's app is built on the standalone `fastmcp` package
  (`from fastmcp import Context, FastMCP`). The issue's `FastMCP` → `MCPServer`
  bundled-SDK restructuring therefore does **not** apply to this class directly; it only
  matters transitively if `fastmcp` internally still expects the pre-2.0 bundled shape
  (covered by the resolution/smoke-test in section 1).
- `src/woof/asgi_server.py` — no `mcp.*` imports (confirmed by grep). The
  `build_http_asgi_app()` mount/middleware stack (`Mount("/mcp", app=mcp_app)`,
  `ActivityMiddleware` → `BearerGuard` → `HostOriginGuard` → CORS) is protocol-agnostic
  and needs no change. `mcp_app` comes from `_mcp_server.mcp.http_app(path="/")` in
  `__main__.py:100`, a `fastmcp` API — confirm its call signature is unaffected once the
  compatible `fastmcp` version is settled.
- Removed-features grep (`WebSocket`, `BaseSession`, `MCP_*` env vars, experimental tasks
  API, `pydantic-settings`): none currently found in `src/woof/**`; re-grep after the bump
  to confirm no transitive reliance (Woof uses its own `WoofConfig`/`config.py`, not
  `MCP_*` env vars).
- `src/woof/agent_client.py`: touch only if the bump breaks import/compile. Prefer the
  smallest compiling fix (updated import path) over a signature rewrite — the full
  `Client(mode='auto')` migration is Step 2.

### 3. Two new integration tests (`tests_integration/`)

Design goal: one running Woof instance, two client-protocol variants, same tool call —
proving coexistence, not just that each protocol works in isolation.

**Fixture** — reuse existing startup machinery rather than inventing new server bootstrap:
- New test module, e.g. `tests_integration/test_mcp_protocol_coexistence.py`, following
  the construction pattern already used in `tests_integration/test_startup.py` (`McpServer`,
  `AgentClient`, `WoofConfig`) combined with how `tests/test_asgi_app.py` binds a real ASGI
  app to a loopback socket via `LoopbackEndpoint`/`bind_loopback_endpoint()` in
  `asgi_server.py`.
- Add a fixture `running_woof()` that: builds a real `McpServer` (minimal `WoofConfig`/
  library, per `test_startup.py`'s existing construction), gets its `fastmcp`
  `http_app(path="/")`, passes it into `build_http_asgi_app()` alongside a fresh
  `bind_loopback_endpoint()`, and starts it with the existing `make_uvicorn_server()`
  helper in a background thread (read and extend `tests_integration/conftest.py`'s
  existing `http_test_server`/uvicorn-in-thread helper used by `test_startup.py` rather
  than duplicating uvicorn bootstrap code). Yield the bound base URL + bearer token.
  Both protocol variants must run against **one** fixture instance within the same test
  function — two separate fixture instantiations would not prove coexistence.
- Register at least one real, cheap tool (e.g. `list_libraries` or `get_summary`) so
  "completes a representative tool call end-to-end" has something trivial-but-real to
  assert on.

**Legacy-protocol test**:
- Use the real `mcp` 2.x SDK's legacy transport client (`mcp.client.streamable_http` +
  `mcp.ClientSession`, or its 2.x equivalent), pointed at `http://<endpoint>/mcp/` with an
  `Authorization: Bearer <token>` header (matching `BearerGuard`'s requirement — see
  `tests/test_asgi_app.py`'s existing pattern). Perform the standard
  `initialize` → `initialized` → `call_tool` sequence and assert on the tool result. This
  exercises the real production `mcp_server.py`, not the lightweight test-only
  `FastMCP("test")` app `test_asgi_app.py` uses.
- If the 2.x SDK's legacy `ClientSession` transport no longer exists standalone (fully
  replaced by the unified `Client`), fall back to forcing the protocol version via
  `Client(url, protocol_version="2025-11-25")` or the equivalent negotiation-pinning kwarg
  — resolve the exact kwarg name empirically at implementation time.

**2026-07-28-protocol test**:
- First check whether the unified `Client(target, mode='auto')` can be pinned to speak
  `server/discover` specifically. If so, use the real client library exactly as for the
  legacy test, just with the newer mode/version — preferred, since it proves the actual
  client library real assistants will use.
- If the 2.x SDK has no way to force `server/discover` alone, fall back to the raw
  JSON-RPC approach already proven in `tests/test_asgi_app.py:120-150`: POST a
  `server/discover` request with `_meta`-carrying params directly via `httpx`/
  `starlette.testclient.TestClient` against the same running instance, then issue the tool
  call the same way (raw JSON-RPC `tools/call`). Document in the test's docstring which
  approach was used and why.
- Whichever approach is used, the assertion must be against the **same fixture instance**
  already used for the legacy test in the same test — not a second freshly-started Woof.

**Auth note**: both tests must pass Woof's existing `BearerGuard` auth (see
`tests/test_asgi_app.py`'s `Authorization: Bearer secret` pattern) — a protocol migration
must not accidentally bypass or break token auth.

### 4. Documentation

- Re-check `README.md`/`HLD.md`/`LLD.md` (repo root and `ouestcharlie-woof/docs/` if
  present) for any recorded minimum `mcp` SDK version and bump it to reflect `mcp>=2.0`.

---

## Verification

1. `.venv/bin/pytest tests/ -v` passes green in `ouestcharlie-woof`, including the two new
   handshake tests.
2. The gallery still renders inline in an MCP-capable client (CSP / resource domains
   unaffected). No code in `asgi_server.py` changes CSP, but `mcp_server.py`'s
   `fastmcp.apps.AppConfig`/`ResourceCSP` usage should be smoke-tested if `fastmcp` was
   bumped, since a major `fastmcp` bump could reshape exactly that surface.
3. Manual smoke test against one real legacy-protocol assistant and one 2026-07-28-capable
   client if available. Concretely: re-run the woof-bridge log check used to diagnose the
   original regression and confirm Goose 1.50.0's `server/discover` call now succeeds
   instead of 400ing.
4. Do not start Step 2 (agent-side bump in `py-toolkit`/`whitebeard`/`wally`, tracked in
   the parent issue) until this step's verification is complete and merged.

### Critical files

- `ouestcharlie-woof/pyproject.toml`
- `ouestcharlie-woof/src/woof/mcp_server.py`
- `ouestcharlie-woof/src/woof/bridge.py`
- `ouestcharlie-woof/src/woof/agent_client.py` (compile-safety only, no functional migration)
- `ouestcharlie-woof/src/woof/asgi_server.py`
- `ouestcharlie-woof/tests/test_asgi_app.py`
- `ouestcharlie-woof/tests_integration/test_startup.py`
