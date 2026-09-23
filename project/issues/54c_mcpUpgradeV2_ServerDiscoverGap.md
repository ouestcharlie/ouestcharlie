# OEC-54c: Woof doesn't answer `server/discover` — blocked on upstream `mcp`/`fastmcp`

#status:done

Status flow: draft (write spec) -> open (review spec) -> todo (spec validated) -> ongoing (implementation started) -> done (merged)

Parent issue: [54_mcpPythonSdk2Upgrade.md](54_mcpPythonSdk2Upgrade.md).

## Context

The original motivation for [54](54_mcpPythonSdk2Upgrade.md) was a live regression: Goose
1.50.0 sends `server/discover` (the MCP 2026-07-28 spec's stateless handshake RPC) as its
only connection attempt, and Woof's `mcp` 1.29.0 SDK rejects it with a 400. The expectation
was that bumping to `mcp` 2.x would let Woof answer both the legacy `initialize` handshake
and `server/discover`, keeping Woof assistant-agnostic across old and new clients.

**That expectation doesn't hold, and this is now verified directly rather than assumed.**
After the full dependency bump landed (`mcp` 2.2.0, `fastmcp` 4.0.3 — the latest releases
on PyPI at time of writing), a `server/discover` request against Woof's real `/mcp`
endpoint still fails, but with a different, more informative error:

- With the default (stateful) transport: `400 Bad Request: Missing session ID` — the
  transport's session gate still only exempts `initialize`, exactly as before.
- With `stateless_http=True` passed to `FastMCP.http_app()` (which does get past the
  session-ID gate — confirmed empirically): `200 OK` at the HTTP level, but the JSON-RPC
  body is `{"error": {"code": -32601, "message": "Method not found", "data":
  "server/discover"}}`.

That second result is the real finding: **`mcp` 2.2.0's server-side request dispatcher
(`FastMCP`/`MCPServer`) has no handler for the `server/discover` method at all.** The SDK
does know about the method — `mcp.client.client`, `mcp.client.session`, and
`mcp.client._probe` all reference `server/discover` for *outbound* use (calling other
servers), and `mcp.types`/`mcp_types` carry `2026-07-28` as `LATEST_PROTOCOL_VERSION` — but
nothing in `mcp.server.lowlevel.server`, `mcp.server.mcpserver`, or the standalone
`fastmcp` package implements *answering* it as a server. This is an upstream SDK gap, not
something fixable by any configuration or code change inside Woof.

## What this means

- Enabling `stateless_http=True` on Woof's `mcp_app` would not fix the regression by
  itself — it only gets the request past the transport gate; the method still isn't
  implemented, so the response is a different (still unusable) error.
- There is currently no way to make Woof answer `server/discover` without either:
  1. Waiting for a `mcp`/`fastmcp` release that implements server-side dispatch for
     `server/discover`, then re-verifying against that release, or
  2. Writing and maintaining a custom handler inside Woof that intercepts the
     `server/discover` method before it reaches `FastMCP`'s dispatcher and answers it
     manually per the 2026-07-28 spec (own protocol-version negotiation, capabilities
     response, TTL/cache-scope fields) — a real, non-trivial implementation with ongoing
     risk of drifting from whatever the SDK eventually ships, since the spec is still
     described upstream as evolving fast around this line.
- [54a](54a_mcpUpgradeV2_Step1-Woof.md)'s two coexistence tests (legacy `initialize` +
  `server/discover`, both against one running Woof instance) cannot be written yet — there
  is no passing behavior to test on the `server/discover` side.

## Next steps (undecided — needs a decision before scoping further)

1. **Track upstream**: watch `mcp`/`fastmcp` release notes for server-side `server/discover`
   support; re-run the manual probe in this issue's Context section against each new
   release until it returns a real capabilities response instead of `-32601`.
2. **Decide whether to build the custom handler** in the meantime, given Goose is a real,
   currently-used client hitting this today — weigh the interim fix's maintenance cost
   against how soon upstream support might land.
3. Once either path succeeds, write 54a's two coexistence tests for real, and close this
   issue.

### Verification (for whichever path is chosen)

Re-run this manual probe against Woof's real `/mcp/` endpoint (adapt as needed once a fix
is attempted):

```python
discover_payload = {
    "jsonrpc": "2.0", "id": 0, "method": "server/discover",
    "params": {"_meta": {
        "io.modelcontextprotocol/protocolVersion": "2026-07-28",
        "io.modelcontextprotocol/clientInfo": {"name": "goose-app", "version": "1.50.0"},
        "io.modelcontextprotocol/clientCapabilities": {"roots": {}, "sampling": {}, "elicitation": {}},
    }},
}
# POST to /mcp/ with Authorization: Bearer <token>, Accept: application/json, text/event-stream
# Success = a real capabilities response, not -32601 "Method not found".
```

Then re-check the woof-bridge logs against a real Goose 1.50.0 connection attempt to
confirm the original regression is actually resolved end-to-end.
