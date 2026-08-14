# OEC-54: Upgrade Python MCP SDK to 2.0

#status:draft

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
whole codebase to `mcp` 2.x in **one coordinated PR spanning all four repos** so the agents
and Woof stay on a single compatible SDK version.

**Scope note:** all repo changes land in a single PR. The four `pyproject.toml` bumps and
every downstream code adaptation must ship together — a mixed 1.x/2.x fleet cannot complete
an MCP handshake.

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

## Changes

### 1. Bump the SDK pins

**Files:**
- `ouestcharlie-woof/pyproject.toml`
- `ouestcharlie-py-toolkit/pyproject.toml`
- `ouestcharlie-whitebeard/pyproject.toml`
- `ouestcharlie-wally/pyproject.toml`

Raise the constraint from `mcp>=1.27,<2.0.0` to `mcp>=2.0,<3.0.0` (and the same for the
`mcp[cli]` dev dependency). Verify `fastmcp` is at a version compatible with `mcp` 2.x and
bump it if required. Regenerate lockfiles.

```toml
# Before
"mcp>=1.27,<2.0.0",

# After
"mcp>=2.0,<3.0.0",
```

### 2. Adapt to breaking API changes

Work through the checklist in the Context section against each repo. Concrete touch points:

- **`AgentBase`** (`ouestcharlie-py-toolkit`) — the FastMCP wrapper: server construction,
  lifecycle, and tool/resource registration. Verify against the `fastmcp` release that
  targets `mcp` 2.x.
- **Woof's MCP client coordinator** — migrate to the unified `Client(target, mode='auto')`
  and confirm server startup / resource-domain (CSP) handling still works.
- **Type/model imports** — audit for `mcp.types` / `mcp.shared.version` usage and switch to
  the `mcp_types` package where needed.
- **Removed features** — grep for WebSocket transport, `BaseSession`, `MCP_*` env vars, and
  the experimental tasks API; none should remain in use.

Keep the change storage-agnostic and agents stateless — no behavioral scope creep beyond
the SDK upgrade.

### 3. Tests

Run the full suites per project with `.venv/bin/pytest`. Pay particular attention to:

- `ouestcharlie-woof/tests_integration/test_startup.py` (server startup path).
- MCP tool round-trip / communication tests between Woof and each agent.
- Any tests that import SDK types directly.

Add/adjust tests only where the 2.0 API forces a signature or import change.

### 4. Documentation

- Update HLD/LLD references to the MCP SDK version if any pin a specific major.
- Note the minimum supported SDK version if it's recorded anywhere developer-facing
  (README, setup docs).

---

## Verification

- `.venv/bin/pytest tests/ -v` passes green in woof, py-toolkit, whitebeard, and wally.
- Woof starts and successfully connects to each agent (MCP handshake succeeds).
- A representative MCP tool call (e.g. an ingestion or enrichment tool) round-trips
  end-to-end.
- The gallery still renders inline in an MCP-capable client (CSP / resource domains
  unaffected by the upgrade).
