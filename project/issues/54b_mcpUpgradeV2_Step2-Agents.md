# OEC-54b: Upgrade Python MCP SDK to 2.0 — Step 2: Woof ↔ agents

#status:done

Status flow: draft (write spec) -> open (review spec) -> todo (spec validated) -> ongoing (implementation started) -> done (merged)

Parent issue: [54_mcpPythonSdk2Upgrade.md](54_mcpPythonSdk2Upgrade.md), Step 2.
Sibling issue: [54a_mcpUpgradeV2_Step1-Woof.md](54a_mcpUpgradeV2_Step1-Woof.md) — currently blocked; see below for how the two interact.

## Context

Step 2 covers the agent-facing side of the `mcp` 1.x → 2.x migration: the three agent
repos (`ouestcharlie-py-toolkit`, `ouestcharlie-whitebeard`, `ouestcharlie-wally`), all
pinned `mcp>=1.27,<2.0.0`, plus Woof's own MCP **client** coordinator
(`ouestcharlie-woof/src/woof/agent_client.py`), which still uses v1 client primitives to
talk to those agents.

**This issue supersedes the assumption in issue 54a that Step 1 and Step 2 are
independently sequenced.** Attempting Step 1 alone (bumping only `ouestcharlie-woof`) hit
a hard `uv lock` failure, because Woof depends on `ouestcharlie-whitebeard` and
`ouestcharlie-wally` as **editable path dependencies**, which in turn depend on
`ouestcharlie-py-toolkit` the same way. Each repo has its own `uv.lock`, but the lockfiles
are chained through these path sources: py-toolkit has no upstream path dependency (it's
the root of the chain), while whitebeard's and wally's locks must satisfy py-toolkit's
`mcp` constraint, and Woof's lock must simultaneously satisfy whitebeard's, wally's, and
(transitively) py-toolkit's `mcp` constraints. Concretely, this means:

- **py-toolkit can be bumped and locked first, in isolation** — nothing upstream of it.
- **whitebeard and wally can only be bumped once py-toolkit is bumped**, and must be
  re-locked against the new py-toolkit.
- **Woof's Step 1 lock (issue 54a) cannot succeed until whitebeard and wally are already
  on `mcp>=2.0,<3.0.0`.** The two issues are not parallel tracks — Step 2 (this issue) is
  a precondition for Step 1's dependency bump to even resolve, though the *code and test*
  work in 54a (dual-protocol serving, coexistence tests) remains logically separate and
  can be written against the bumped dependency once it lands.

So the practical sequencing is: **py-toolkit → whitebeard & wally (independently, both now
unblocked) → woof (both this issue's client-coordinator migration and issue 54a's
server-side work, which can now finally lock)**.

---

## Changes

### 1. `ouestcharlie-py-toolkit` — bump and adapt first (no upstream blockers)

**File:** `ouestcharlie-py-toolkit/pyproject.toml:22` — `mcp>=1.27,<2.0.0` → `mcp>=2.0,<3.0.0`.

`AgentBase` (`src/ouestcharlie_toolkit/server.py:24-182`) wraps `mcp.server.fastmcp.FastMCP`
(the **bundled** fastmcp inside the `mcp` package — py-toolkit has no dependency on the
standalone `fastmcp` PyPI package, unlike Woof) and `mcp.server.session.ServerSession`.
Concrete touch points:

- `self.mcp = FastMCP(name=name)` (line 45) and `run()` → `self.mcp.run()` (stdio,
  lines 180-182) — verify against the issue's noted `FastMCP` → `MCPServer` bundled-SDK
  restructuring; this is the one place in the whole codebase where that restructuring
  actually applies directly, since py-toolkit uses the bundled server, not the standalone
  package.
- Cooperative cancellation (`check_cancelled`, line 83) and the `per_photo` context
  manager (line 96) — check these don't rely on removed/renamed `ServerSession` internals.
- No tool/resource decorators live in `AgentBase` itself (subclasses call `self.mcp.tool()`
  directly) — confirm the decorator API is unchanged, per the issue's own note, but verify
  empirically via the test run below rather than assuming.

Run `.venv/bin/pytest tests/ -v` after the bump; fix only what the 2.0 API forces.

### 2. `ouestcharlie-whitebeard` and `ouestcharlie-wally` — bump once py-toolkit lands

**Files:**
- `ouestcharlie-whitebeard/pyproject.toml:21` — `mcp>=1.27.0,<2.0.0` → `mcp>=2.0,<3.0.0`
  (plus the `mcp[cli]` dev pin, line 59).
- `ouestcharlie-wally/pyproject.toml:21` — `mcp>=1.27,<2.0.0` → `mcp>=2.0,<3.0.0` (plus
  `mcp[cli]`, line 62).

Both depend on py-toolkit as an editable path dependency (`whitebeard/pyproject.toml:22,
32-33`; `wally/pyproject.toml:24,35-36`) and also import `mcp` symbols directly, not solely
through `AgentBase`:

- `ouestcharlie-whitebeard/src/whitebeard/agent.py:7` — `from mcp.server.fastmcp import
  Context`.
- `ouestcharlie-wally/src/wally/agent.py:10-11` — `from mcp.server.fastmcp import Context`
  and `from mcp.server.fastmcp.exceptions import ToolError`.

Neither declares a standalone `fastmcp` dependency, so — like py-toolkit — the bundled
`FastMCP` → `MCPServer` restructuring is the relevant checklist item here, not the
standalone-package concerns that apply to Woof. Re-lock and run each repo's suite after
the bump:

- Whitebeard: `.venv/bin/pytest tests/ -v` (`test_indexer.py`, `test_purge_metadata.py`).
- Wally: `.venv/bin/pytest tests/ -v` (`test_searcher.py`, `test_http_server.py` —
  most relevant to the MCP transport layer itself — plus the other unit suites).

Bump and verify these two independently of each other (neither depends on the other), but
both must land before Woof's lock (this issue's section 3, and issue 54a) can resolve.

### 3. `ouestcharlie-woof`'s MCP client coordinator — `agent_client.py`

Once whitebeard and wally are bumped, Woof's own `mcp>=2.0,<3.0.0` bump (issue 54a) can
finally lock. This section covers the client-side migration that issue 54a explicitly
deferred.

**File:** `src/woof/agent_client.py`. Current v1 primitives (confirmed by reading the
file in full):

- `from mcp import ClientSession, StdioServerParameters` (line 18)
- `from mcp.client.stdio import stdio_client` (line 19)
- `from mcp.client.streamable_http import streamable_http_client` (line 20)
- `from fastmcp import Context` (line 17 — the *standalone* package, used only for
  progress-relay typing; unaffected by this migration)

Wiring is dual-transport and asymmetric — migrate each path to the unified
`Client(target, mode='auto')`:

- **Wally**: a persistent subprocess sidecar reached over Streamable HTTP
  (`_WallySidecar._session_loop`, lines 100-211). Spawns `python -m wally`, reads a
  `WALLY_READY port=<n>` line, then holds a `streamable_http_client` + `ClientSession`
  open in one dedicated asyncio task, serving calls off a queue. Migrate to
  `Client(f"http://127.0.0.1:{port}/...", mode='auto')`, preserving the long-lived
  session-per-sidecar shape (the queue-driven task loop itself doesn't need to change,
  only the session object it holds open).
- **Whitebeard (and any other non-wally module)**: spawned fresh per call over stdio via
  `_call_ephemeral` (lines 370-402), using `StdioServerParameters` + `stdio_client` +
  `ClientSession`, running `python -m <module>`. Migrate to `Client(StdioTransport(...),
  mode='auto')` or the 2.x equivalent for a fresh-process-per-call stdio client — resolve
  the exact 2.x constructor shape for ephemeral stdio clients at implementation time.

Both paths currently end in `session.call_tool(...)` — confirm the unified `Client`
exposes an equivalent method with a compatible signature, or adjust call sites.

**Tests**: no dedicated `test_agent_client.py` exists, but real end-to-end coverage for
both transports already lives in `tests_integration/test_startup.py`:

- `TestWallySidecar` (lines 92-150) spawns the actual persistent Wally subprocess via
  `agent_client._get_wally_sidecar()` and connects to its real HTTP port.
- `TestWhitebeard` (lines 158-189) calls `agent_client.call_tool("whitebeard",
  "index_library", ...)`, which spawns a real ephemeral Whitebeard subprocess over stdio
  and asserts on the real result dict.

Neither mocks `AgentClient` or its transports — both drive real subprocesses. This suite
is sufficient to catch a broken `Client(mode='auto')` migration on either path; no new
integration test is needed for this step. (The mocked usages in `tests/test_http_server.py:16`,
`tests/test_mcp_server.py:15,30`, and `tests/test_gallery_session_manager.py:9` are
unrelated unit tests for other components that merely construct/stub `AgentClient` as a
dependency — they were never meant to cover the client itself, and don't need to change
for this migration beyond whatever the `mcp` 2.0 API forces.)

---

## Verification

1. `.venv/bin/pytest tests/ -v` green in py-toolkit, whitebeard, and wally, in that
   dependency order (each re-locked before running).
2. `.venv/bin/pytest tests_integration/ -v` green in woof, including `test_startup.py`'s
   existing `TestWallySidecar` and `TestWhitebeard` classes — this is real end-to-end
   coverage for the `agent_client.py` migration and needs no new test.
3. Woof starts and successfully connects to each agent (MCP handshake succeeds) using the
   unified `Client`.
4. A representative MCP tool call (e.g. an ingestion or enrichment tool) round-trips
   end-to-end through Woof to each agent.
5. Once this issue's dependency bumps land, re-attempt issue 54a's `uv lock` for Woof —
   it should now resolve, unblocking that issue's server-side work (dual-protocol serving,
   coexistence tests).

### Critical files

- `ouestcharlie-py-toolkit/pyproject.toml`
- `ouestcharlie-py-toolkit/src/ouestcharlie_toolkit/server.py`
- `ouestcharlie-whitebeard/pyproject.toml`
- `ouestcharlie-whitebeard/src/whitebeard/agent.py`
- `ouestcharlie-wally/pyproject.toml`
- `ouestcharlie-wally/src/wally/agent.py`
- `ouestcharlie-woof/src/woof/agent_client.py`
- `ouestcharlie-woof/tests/test_http_server.py`, `test_mcp_server.py`,
  `test_gallery_session_manager.py`
