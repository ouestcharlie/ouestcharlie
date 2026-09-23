# OEC-54: Upgrade Python MCP SDK to 2.0

#status:done

## Outcome

Implemented across all four repos in dependency order (py-toolkit → whitebeard & wally →
woof), per [54b](54b_mcpUpgradeV2_Step2-Agents.md)'s lockfile-chain finding. All existing
test suites pass with real, verified `mcp` 2.2.0 / `fastmcp` 4.0.3 installs (not lockfile
bumps alone — an earlier pass wrongly reported success against a stale, unsynced venv;
`uv sync`, not just `uv lock`, is required to actually verify a bump). Concrete fixes
applied, all minimal/forced by the 2.0 API:

- **py-toolkit**: `AgentBase` (`src/ouestcharlie_toolkit/server.py`) — `mcp.server.fastmcp`
  → `mcp.server.mcpserver` (`FastMCP`→`MCPServer`, per the SDK's own migration message).
- **whitebeard/wally**: `Context`/`ToolError` import paths updated to `mcp.server.mcpserver`.
- **wally**: added an explicit `httpx` dev dependency — it was only ever available
  transitively via `mcp` 1.x, which switched to `httpx2` internally in 2.x, breaking
  `tests/test_http_server.py`'s direct `import httpx`.
- **woof**: `agent_client.py` and `bridge.py` — `streamable_http_client`'s context manager
  now yields a 2-tuple `(read, write)`, not the old 3-tuple with a `get_session_id`
  callback; plus a `.isError` → `.is_error` deprecation fix.

**The regression that motivated this issue (Goose's `server/discover` 400) is NOT fixed by
this bump**, and this was verified directly, not assumed: `mcp` 2.2.0 (latest on PyPI) has
no server-side dispatch handler for `server/discover` at all — it returns `-32601 Method
not found` even with `stateless_http=True` enabled (which does get past the transport's
session-ID gate). The SDK's client-side code references `server/discover` for outbound
use, but `FastMCP`/`MCPServer`'s own request dispatcher never implements answering it. This
is an upstream gap, not something fixable in Woof's code. See
[54c](54c_mcpUpgradeV2_ServerDiscoverGap.md) for the follow-up tracking that gap
separately — it's blocked on upstream `mcp`/`fastmcp` support, not on anything in this
codebase. [54a](54a_mcpUpgradeV2_Step1-Woof.md)'s two coexistence tests were not written
as a result — there is currently no combination of Woof-side code that makes both
protocols work, so a test proving coexistence would necessarily be testing something that
doesn't exist yet.

Status flow: draft (write spec) -> open (review spec) -> todo (spec validated) -> ongoing (implementation started) -> done (merged)

## Context

The Python MCP SDK is currently pinned below the 2.0 major version across every Python
component:

- `ouestcharlie-woof/pyproject.toml` — `mcp>=1.27,<2.0.0` (+ `mcp[cli]` dev group)
- `ouestcharlie-py-toolkit/pyproject.toml` — `mcp>=1.27,<2.0.0`
- `ouestcharlie-whitebeard/pyproject.toml` — `mcp>=1.27,<2.0.0`
- `ouestcharlie-wally/pyproject.toml` — `mcp>=1.27,<2.0.0`

The `<2.0.0` ceiling was set deliberately because the 2.0 release carries substantial
breaking API changes. Staying on 1.x means we miss upstream bug fixes, protocol updates,
and new capabilities, and the gap widens the longer we wait. This issue tracks moving the
whole codebase to `mcp` 2.x, in two sequential steps (see Scope note below) so the agents
and Woof end up on a single compatible SDK version without an all-or-nothing cutover.

**Scope note:** split into two sequential steps rather than one atomic four-repo PR, so each
side of the handshake can be validated independently before the next step starts:

1. **Woof ↔ external clients** — bump `mcp` in `ouestcharlie-woof` only, and confirm Woof's
   MCP server still serves both current MCP-capable assistants (legacy `initialize`
   handshake) and clients that have already moved to the 2026-07-28 stateless revision
   (`server/discover`). Woof must remain assistant-agnostic per project conventions — this
   step is where that guarantee is actually at risk, since a large share of MCP clients had
   not adopted 2026-07-28 as of the last compatibility check, and the two protocol paths must
   coexist.
2. **Woof ↔ agents** — once step 1 is verified, bump `mcp` in `ouestcharlie-py-toolkit`,
   `ouestcharlie-whitebeard`, and `ouestcharlie-wally`, and migrate Woof's MCP client
   coordinator to the unified `Client(target, mode='auto')`. This side is fully within our
   control (we ship both ends), so it carries less compatibility risk than step 1, but still
   needs `AgentBase`'s `fastmcp` dependency confirmed compatible with `mcp` 2.x first — treat
   that confirmation as a precondition of starting step 2, not a detail to discover mid-step.

A mixed 1.x/2.x fleet cannot complete an MCP handshake, so within each step every component
on that side of the handshake still bumps together — the split is between the two steps, not
within them.

### What MCP 2.0 changes (from the SDK release notes)

The 2.0 release replaces the session-centric v1 internals with a stateless, dispatcher-based
architecture targeting the 2026-07-28 MCP spec. The changes most likely to touch this
codebase:

- **`FastMCP` → `MCPServer`** in the *bundled* SDK server. The decorator API is unchanged,
  but the low-level `Server` interface is restructured (handlers as constructor params,
  snake_case fields). **Caveat:** we depend on the *standalone* `fastmcp` package
  (`fastmcp>=3.2`), which is a separate project — confirm which `fastmcp` release targets
  `mcp` 2.x before bumping, since `AgentBase` wraps it.
- **Unified client**: `Client(target, mode='auto')` replaces v1's transport +
  `ClientSession` layering, with automatic protocol-version negotiation.
- **Import relocations**: protocol types split into a separate `mcp-types` distribution
  (imported as `mcp_types`); `mcp.types` remains available as an alias. `mcp.shared.version`
  → `mcp_types.version`.
- **Removed**: WebSocket transport, the experimental tasks API, `BaseSession`,
  `MCP_*` environment-variable configuration, and the `pydantic-settings` dependency.
- **Signature/param changes** to watch for: `ServerMiddleware.__call__` becomes
  `(ctx, call_next)`; `Context.client_id` now read via `ctx.request_context.meta` or
  `get_access_token().client_id`; OAuth `scopes=` → `scope=`; `Client(cache=False)` →
  `Client(cache=None)`; `FileResource(is_binary=...)` → `encoding: str | None`.

Treat this list as a starting checklist, not exhaustive — re-check the official migration
guide during implementation, since the SDK is evolving fast around the 2.0 line.

---

## Step 1 — Woof ↔ external clients

### 1.1 Bump the SDK pin

**File:** `ouestcharlie-woof/pyproject.toml`

Raise the constraint from `mcp>=1.27,<2.0.0` to `mcp>=2.0,<3.0.0` (and the same for the
`mcp[cli]` dev dependency). Regenerate the lockfile.

```toml
# Before
"mcp>=1.27,<2.0.0",

# After
"mcp>=2.0,<3.0.0",
```

### 1.2 Adapt Woof's MCP server to the breaking API changes

Work through the checklist in the Context section against `ouestcharlie-woof`. Concrete
touch points:

- **`FastMCP` → `MCPServer`** in the bundled SDK server, plus the restructured low-level
  `Server` interface (handlers as constructor params, snake_case fields).
- **Type/model imports** — audit for `mcp.types` / `mcp.shared.version` usage and switch to
  the `mcp_types` package where needed.
- **Removed features** — grep for WebSocket transport, `BaseSession`, `MCP_*` env vars, and
  the experimental tasks API; none should remain in use.
- **Dual-protocol serving** — confirm the upgraded server answers both the legacy
  `initialize` handshake and the 2026-07-28 `server/discover` RPC. This is the crux of the
  step: Woof must keep serving MCP-capable assistants that haven't moved to 2026-07-28 yet,
  per the assistant-agnostic requirement in project conventions.

Keep the change storage-agnostic — no behavioral scope creep beyond the SDK upgrade.

### 1.3 Tests

Run `ouestcharlie-woof`'s suite with `.venv/bin/pytest tests/ -v`, paying particular
attention to `tests_integration/test_startup.py`. Add two new integration tests
(`tests_integration/`) alongside it:

- **Legacy-client handshake**: an MCP client pinned to the pre-2026-07-28 protocol (using
  the old `initialize`/`initialized` exchange and `Mcp-Session-Id` header) connects to Woof
  and completes a representative tool call end-to-end.
- **2026-07-28-client handshake**: an MCP client speaking the stateless revision
  (`server/discover` with per-request `_meta`) connects to Woof and completes the same
  representative tool call end-to-end.

Both must pass on the same running Woof instance — the point is proving the two protocol
paths coexist, not that either one works in isolation.

### 1.4 Documentation

- Update HLD/LLD references to the MCP SDK version if any pin a specific major.
- Note the minimum supported SDK version if it's recorded anywhere developer-facing
  (README, setup docs).

### 1.5 Verification

- `.venv/bin/pytest tests/ -v` passes green in `ouestcharlie-woof`, including the two new
  handshake tests.
- The gallery still renders inline in an MCP-capable client (CSP / resource domains
  unaffected by the upgrade).
- Manual smoke check against at least one real assistant still on the legacy protocol and
  one on 2026-07-28, if available, in addition to the automated tests above.

---

## Step 2 — Woof ↔ agents

Start only once Step 1 is verified. Precondition: confirm which `fastmcp` release targets
`mcp` 2.x — `AgentBase` wraps the *standalone* `fastmcp` package (`fastmcp>=3.2`), a
separate project from the SDK's bundled server, and this must be settled before any of the
work below starts, not discovered mid-step.

### 2.1 Bump the SDK pins

**Files:**
- `ouestcharlie-py-toolkit/pyproject.toml`
- `ouestcharlie-whitebeard/pyproject.toml`
- `ouestcharlie-wally/pyproject.toml`

Raise the constraint from `mcp>=1.27,<2.0.0` to `mcp>=2.0,<3.0.0`. Bump `fastmcp` to the
version confirmed compatible with `mcp` 2.x in the precondition above. Regenerate
lockfiles.

### 2.2 Adapt to breaking API changes

- **`AgentBase`** (`ouestcharlie-py-toolkit`) — server construction, lifecycle, and
  tool/resource registration against the confirmed `fastmcp` release.
- **Woof's MCP client coordinator** — migrate to the unified `Client(target, mode='auto')`.
- **Signature/param changes**: `ServerMiddleware.__call__` becomes `(ctx, call_next)`;
  `Context.client_id` now read via `ctx.request_context.meta` or
  `get_access_token().client_id`; OAuth `scopes=` → `scope=`; `Client(cache=False)` →
  `Client(cache=None)`; `FileResource(is_binary=...)` → `encoding: str | None`.

Keep agents stateless — no behavioral scope creep beyond the SDK upgrade.

### 2.3 Tests

Run the full suites in `py-toolkit`, `whitebeard`, and `wally` with `.venv/bin/pytest`.
Pay particular attention to MCP tool round-trip / communication tests between Woof and each
agent. Add/adjust tests only where the 2.0 API forces a signature or import change.

### 2.4 Verification

- `.venv/bin/pytest tests/ -v` passes green in py-toolkit, whitebeard, and wally.
- Woof starts and successfully connects to each agent (MCP handshake succeeds) using the
  unified `Client`.
- A representative MCP tool call (e.g. an ingestion or enrichment tool) round-trips
  end-to-end through Woof to each agent.

---

Treat the API-change checklist in the Context section as a starting point, not exhaustive —
re-check the official migration guide during implementation, since the SDK is evolving fast
around the 2.0 line.
