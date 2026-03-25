# Mobile Vision — Android Integration

## Context

This document explores what an Android client for OuEstCharlie would look like —
specifically, what replaces Claude Desktop on a mobile device.

On macOS, Claude Desktop provides three things:
1. **MCP client** — connects to Woof via stdio, calls tools
2. **LLM reasoning** — natural language → structured queries → tool calls
3. **UI shell** — renders the gallery as an MCP App (sandboxed iframe)

Android cannot replicate this directly because:
- Woof uses Python + Rust agents → can't run natively on Android
- Claude Android app does not support MCP servers
- No stdio process spawning in the Android sandbox

---

## The Core Architectural Split

On Android, the roles that Claude Desktop plays on macOS split across two components:

| Role on macOS (Claude Desktop) | Role on Android |
|---|---|
| MCP client (transport: stdio) | MCP client over Streamable HTTP |
| LLM reasoning (Claude model) | Claude API calls from the Android app |
| Gallery rendering (MCP App iframe) | WebView in the Android app |

**Critical insight**: Woof stays on the server/desktop. The Android device is a thin client.
The gallery already supports an HTTP fallback path (`/gallery/{token}` in a browser).

---

## Recommended Architecture

### Where Woof Runs

Woof V2 as a persistent daemon (launchd on macOS, systemd on Linux) on the user's machine or NAS,
accessible over local network or VPN (Tailscale being the natural fit for home use).

Woof's HTTP server must be extended to bind on a configurable network interface (not just loopback)
when daemon mode is enabled, with authentication (bearer token minimum).

**One transport unifies both clients**: In V2, Woof exposes MCP via Streamable HTTP.
Claude Desktop reconnects via `http://localhost:{port}/mcp` (Desktop Extension manifest drops the stdio command).
The Android app connects via `http://{woof-host}:{port}/mcp` over LAN/VPN.
Stdio is a V1-only artifact (child process model); it disappears in V2 daemon mode.

### Android App Design

A native Android app (Kotlin + Jetpack Compose) that:

1. **Discovery**: Connects to Woof at a configured address (LAN IP or Tailscale hostname)
2. **NLU**: Calls Claude API directly (Haiku-class model for cost) to parse free-text queries into `search_photos` filter structures — same translation Claude Desktop does conversationally
3. **Operations**: Calls Woof via MCP Streamable HTTP (already in MCP spec v2025-11-25) — same protocol as Claude Desktop, just over the network instead of localhost
4. **Gallery**: Opens Woof's gallery URL in an in-app WebView — the Svelte app already works this way (HTTP fallback path exists)

### Protocol Stack

```
Claude Desktop (macOS)
    └── MCP Streamable HTTP → http://localhost:{port}/mcp

Android App
    ├── Claude API (HTTPS)          ← NLU: text → filter structs
    └── MCP Streamable HTTP → http://{woof-host}:{port}/mcp   (LAN/VPN)
            └── HTTP (gallery)   ← gallery HTML + thumbnails/previews
```

---

## What Needs to Change in Woof

| Change | Scope | Notes |
|---|---|---|
| Woof as V2 daemon (launchd/systemd) | Prerequisite | Already planned in OpenPoints #11 |
| Bind HTTP server on configurable network interface | Small | Currently loopback-only |
| Add authentication to HTTP endpoints | Medium | Bearer token minimum |
| Expose MCP via Streamable HTTP transport | Medium | FastMCP likely supports this; replaces stdio |

The gallery Svelte app requires **no changes** — HTTP fallback path already works.

---

## What the Android App Is NOT

- Not a replacement for Woof (no indexing logic on-device)
- Not a standalone app (requires network access to Woof daemon)
- Not dependent on Claude Desktop being open (V2 daemon prerequisite)
- Not responsible for photo ingestion from the phone (separate concern — see below)

---

## Related: Photo Ingestion from Android

The HLR mentions "mobile backup" as a planned use case (photos flowing from phone to backend),
but this is a distinct problem from browsing. It would require a separate ingestion agent
that can be triggered from or run on the phone, and is out of scope for this document.

---

## Open Questions

1. **Offline browsing**: Can the Android app browse previously-loaded sessions without Woof? Manifests are on the server; caching strategy undefined.
2. **Authentication model**: Single user assumed. Multi-user (family sharing) not addressed.
3. **Woof daemon discovery**: How does the Android app find Woof on the network? Manual config vs. mDNS/Bonjour.
