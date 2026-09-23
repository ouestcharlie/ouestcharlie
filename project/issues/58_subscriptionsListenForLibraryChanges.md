# OEC-58: Push library-list-changed notifications via `subscriptions/listen`

#status:draft

Status flow: draft (write spec) -> open (review spec) -> todo (spec validated) -> ongoing (implementation started) -> done (merged)

## Context

Following the `mcp` 1.x→2.x migration ([54](54_mcpPythonSdk2Upgrade.md)), we surveyed what
new 2026-07-28 protocol features `mcp` 2.2.0/`fastmcp` 4.0.3 actually expose server-side,
to see if Woof should take advantage of any of them. Two candidates were considered and
ruled out along the way:

- **`CacheHint`** (per-result freshness hints): only applies to listing methods
  (`tools/list`, `resources/list`, `resources/read`, `prompts/list`) — **not** to
  `tools/call` results. Woof's `get_summary`/`list_search_fields`/`list_libraries` are all
  tools, so their per-call outputs aren't a `CacheHint`-eligible surface at all. Dropped.
- **`subscriptions/listen`** (push notifications via `SubscriptionBus`): the event
  vocabulary is narrow — `ResourcesListChanged`, `ResourceUpdated`, `ToolsListChanged`,
  `PromptsListChanged` only. A codebase survey (`src/woof/mcp_server.py`,
  `indexing_session_manager.py`, `gallery_session_manager.py`) found this does **not** fit
  indexing progress or gallery paging — both are per-operation progress streams, not
  resource-identity or list-membership changes, and forcing them through `ResourceUpdated`
  would mean reifying a fake "resource" just to get a notification channel. Those stay
  exactly as they are: indexing progress via `IndexingSessionManager`'s existing
  HTTP-polling backend for the browser gallery UI (correct as-is — that's a browser-UI
  concern, not an MCP-client one), and gallery paging via `GallerySessionManager`'s
  existing HTTP backend (same reasoning — per the explicit comment at
  `mcp_server.py:444-446`, pagination is intentionally handled entirely outside MCP tool
  calls).

**The one real, correctly-shaped fit**: `register_library`/`unregister_library`
(`mcp_server.py:172-225`) mutate the set backing `list_libraries` (`mcp_server.py:228-230`)
at runtime. This is genuine list-membership state — exactly what `ToolsListChanged` is
designed to signal. An MCP client that called `list_libraries` earlier in a conversation
currently has no way to know a library was added or removed by another tool call or
another client without re-polling blindly; a push notification lets it react instead.

This is a small, narrowly-scoped addition — not a broad architecture change. Everything
else in Woof's polling model stays exactly as it is; this issue does not touch it.

## Changes

**File**: `src/woof/mcp_server.py`

1. Construct an `InMemorySubscriptionBus` (from `mcp.server.subscriptions`) alongside
   `McpServer`'s other state, and pass it to `FastMCP`/`MCPServer` construction via the
   `subscriptions=` constructor kwarg (confirmed present on `MCPServer.__init__`,
   `mcp/server/mcpserver/server.py:157-186`) — `fastmcp`'s `FastMCP` wraps this the same
   way; verify the kwarg is exposed identically before implementing.
2. In `register_library` and `unregister_library` (`mcp_server.py:172-225`), after the
   library set actually changes, publish a `ToolsListChanged` event (or
   `ResourcesListChanged`, if the SDK models `list_libraries` under resources — confirm
   which event type the SDK expects for a tool-backed listing) to the bus:
   `await self._subscriptions.publish(...)`.
3. No changes needed to `list_libraries` itself, to `asgi_server.py`, or to any other tool
   — `subscriptions/listen` is served automatically by `MCPServer`'s built-in
   `ListenHandler` once a bus is wired in; Woof doesn't need to implement the listen
   endpoint itself.
4. Do not touch `IndexingSessionManager`, `GallerySessionManager`, or `index_library`, per
   the Context section's finding — those aren't a fit for this feature.

## Verification

- Unit test in `tests/test_mcp_server.py`: call `register_library`, assert a
  `ToolsListChanged` event was published to the bus (inject a test double bus, or subscribe
  a listener and assert it fired) — mirroring the existing test style for
  `register_library`/`unregister_library` in that file.
- Manual smoke test: connect a real MCP client (or `mcp.client` test harness) that sends
  `subscriptions/listen`, then call `register_library` from a second connection, and
  confirm the first client's stream receives the event.
- `.venv/bin/pytest tests/ -v` stays green.
