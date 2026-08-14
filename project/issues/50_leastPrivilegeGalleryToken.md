# OEC-50: Scoped JWT capability tokens for host ↔ bridge ↔ woof

#status:discarded

Decision to implement the simpler OEC-50bß

## Context

Woof's loopback HTTP server is guarded by a **single per-process opaque bearer
token** (`secrets.token_urlsafe(32)`, minted in `discovery.py` `generate_token()`),
validated by a plain string compare in `BearerGuard` (`security.py`). The same
token authorizes **every hop and every endpoint**: the bridge↔woof control plane
(`/mcp`), lifecycle endpoints (`/shutdown`, `/keepalive`), destructive tools, and
the gallery's read-only media/metadata routes alike.

That token is then handed to the gallery frontend. `browse_gallery` and
`index_photos` return it as `serverToken`, and it is embedded in the gallery HTML
via `get_gallery_html` (`data-server-token`). Consequently **anything that can
read a `browse_gallery`/`index_photos` tool result — or the gallery HTML —
obtains full API access**, including the control plane and destructive tools.

This issue records the decision on least-privilege token management (whether to
adopt OAuth, and how to scope credentials) and specifies the intended design.
**No implementation is delivered here** — this is a reviewable spec.

The gallery is already scoped to a specific set of session tokens: `browse_gallery`
merges its `session_tokens` argument into one `merged_token` held by
`GallerySessionManager`. The design below leverages that existing scoping.

---

## Decisions

### 1. No OAuth

Full OAuth2 is **rejected**. OAuth solves *delegated* authorization across trust
domains, with a resource owner consenting to a third-party client via a separate
authorization server. None of that exists here: host, bridge, woof, and wally are
local loopback processes spawned by the same OS user — single user, no third
party, no cross-origin delegation, no consent step. Its machinery (authorization
server, redirect/PKCE, refresh exchange, discovery metadata) would add complexity
and attack surface for no threat-model benefit. The MCP specification's OAuth flow
targets *remote* MCP servers; woof-bridge is stdio-local, so it does not apply.

What is adopted is the *concept*, not the protocol: **scoped, audience-restricted,
short-lived capability tokens**.

### 2. JWT (HS256) everywhere

Every credential is a **JWT signed HS256**, giving one uniform format and one
verification path in `BearerGuard`. A single per-process **HMAC signing secret is
minted at woof startup and never leaves woof's process** — this is the critical
invariant of the whole scheme. The algorithm is pinned (HS256 only; `alg=none`
and algorithm-confusion rejected). PyJWT is pure-Python, so the new dependency
(woof only) does not affect cross-platform support.

Claims carry the authorization state — `{scope, exp, ...}` (plus `sid` for
gallery tokens) — so `BearerGuard` verifies statelessly, with no server-side
token registry.

#### Alternative considered: opaque tokens + in-process scope table

The closest alternative to today's scheme is to **keep opaque random tokens**
(`secrets.token_urlsafe`, as now) and store `{scope, exp, sid}` for each in an
**in-memory dict inside woof**, looked up on every request. It was weighed seriously
because woof is a **single process** — the one setting where JWT's headline benefit,
*stateless verification across processes/instances*, buys the least.

| Dimension | JWT (HS256) | Opaque + in-process table |
|-----------|-------------|---------------------------|
| Verification state | none — self-contained claims | dict lookup against live table |
| **Revocation** | **none — only global (rotate secret = restart woof)** | **surgical — delete the row; instant** |
| Expiry | self-enforced via `exp` claim | table stores `exp`; guard checks it |
| Attack surface | `alg`-confusion / `alg=none` class (mitigated by pinning) | none of that class |
| Dependency | PyJWT (pure-Python, woof-only) | none |
| Token size on the wire | larger (signed, base64 claims) | small random string |
| Format uniformity | one format, one verify path | opaque strings + a schema for the table |

**The table's one real advantage is surgical revocation** — and JWT has *no*
revocation at all short of restarting woof (which rotates the per-process secret and
invalidates every token globally). Everything else is a wash or mildly favors JWT.

**Decision: JWT.** The revocation gap is acceptable here because the pieces that
would otherwise need revocation are already covered:

- **`gallery:read`** is bound to a `sid` session that lives in
  `GallerySessionManager` and is already evicted by capacity (decision #6) — so its
  effective revocation lever exists independently of the token format.
- The **tool-plane JWT** is short-lived (15 min) and refreshed, so a leaked one
  self-expires quickly.
- **`admin`** dies with the process, and a **detected leak of any token** is handled
  by restarting woof — a clean global kill-switch (recorded in the security posture).

Given that, the table's revocation edge is largely redundant, while JWT keeps
verification **stateless and uniform** (no per-request lookup, no table to grow
alongside gallery sessions, `sid`/`exp`/`scope` carried in the credential
itself, no lookup). The `alg`-confusion risk is closed by pinning HS256 and rejecting
`alg=none`. If surgical, per-token revocation ever becomes a requirement (e.g. a
long-lived `gallery:write`), revisit this — a small `jti` denylist or a move to the
table would restore it without disturbing the scope model.

### 3. All admin API segregated under `/admin/*`

Lifecycle and token-minting endpoints move under a single prefix — `/admin/shutdown`,
`/admin/keepalive`, `/admin/token` — so the scope→endpoint map is a clean 1:1
with path prefixes:

| Path prefix        | Required scope  |
|--------------------|-----------------|
| `/admin/*`         | `admin`         |
| `/mcp`             | `mcp:discovery` / `mcp:readOnly` / `mcp:destructive` (per method+tool — see below) |
| `/gallery`, `/api/results/*`, media proxy | `gallery:read` |
| `/healthz`         | (public liveness probe, unauthenticated) |
| `/gallery-static/` | (exempt — compiled bundle, no user data) |

`/mcp` is the one endpoint whose required scope is **not** purely path-derived.
MCP is a single JSON-RPC endpoint: every tool call POSTs to `/mcp`, and the tool
identity lives in the request **body** (`{"method": "tools/call",
"params": {"name": ...}}`), not the URL. Rather than split destructive tools onto a
separate path — which would mean two FastMCP mounts and a fragmented `tools/list`
— `BearerGuard` inspects the JSON-RPC method and picks the required scope:

- **Protocol methods** (`initialize`, `tools/list`, `ping`, notifications) →
  `mcp:discovery`.
- **`tools/call`** → the scope derived from the named tool's **annotation**, via an
  explicit tool→scope map owned by `McpServer` (built at registration from the
  `ToolAnnotations`): `readOnlyHint` → `mcp:readOnly`, `destructiveHint` →
  `mcp:destructive`.

The mapping is **fail-closed**: a tool carrying **neither** annotation maps to **no
scope** and is, by design, **not invocable** — the guard rejects it. Registering a
new tool therefore forces a deliberate annotation choice; forgetting one makes the
tool unreachable (a visible failure) rather than silently under-protected. An
unknown method or an unknown tool name is likewise rejected — never defaulted to a
weaker scope. This is the authorization boundary; `destructiveHint` continues to
drive client-side UX independently.

**Batched requests.** JSON-RPC 2.0 allows a **batch** — a JSON array of calls in one
POST. `BearerGuard` derives the required scope for **every** element and requires the
token to satisfy **all** of them (the union); the whole batch is rejected if any
single call fails its scope check, so a read-only token cannot smuggle a destructive
call behind a permitted one. Any element that is itself malformed, names an unknown
method/tool, or resolves to no scope fails closed and rejects the batch.

### 4. Scopes with token exchange

- **`admin`** — everything under `/admin/*` (minting + lifecycle). Held **only by
  the bridge**, minted by woof at startup and written to the 0600 discovery file
  (replaces today's opaque token). Read once, used sparingly.
- **`mcp:discovery`** — the `/mcp` protocol methods every client needs to bootstrap:
  `initialize`, `tools/list`, `ping`, notifications. No tool executes under this scope.
- **`mcp:readOnly`** — `tools/call` for tools flagged `readOnlyHint`.
- **`mcp:destructive`** — `tools/call` for tools flagged `destructiveHint`
  (e.g. `register_library`, `unregister_library`, cleanup tools).

  Scope matching is a **plain 1:1 equality check** between the annotation-derived
  required scope (decision #3) and the token's scope list: the request is allowed
  iff that exact scope string is present. No scope subsumes, implies, or "englobes"
  another — `mcp:destructive` grants no read access, `mcp:readOnly` grants no
  discovery, and none grants `admin`. A client that needs to both discover and
  invoke read tools must therefore carry **both** `mcp:discovery` and `mcp:readOnly`
  explicitly. These three are **carried together in a single JWT**
  (`scope: "mcp:discovery mcp:readOnly mcp:destructive"`), minted for the bridge at
  `/admin/token`. The bridge is a full-control client, so splitting the token per
  call buys nothing there — the token is the same trust anchor either way.
  **Short-lived**, obtained by the bridge from `/admin/token` using its `admin` JWT
  and refreshed near expiry (see lifetimes below). It still cannot mint, cannot shut
  down, and cannot reach gallery media; a leaked tool-plane JWT expires and cannot
  escalate.

  Keeping the three as **separate scopes** is a forward-looking provision: a future
  **read-only Woof instance** can be given a token minted with
  `mcp:discovery mcp:readOnly` only (no `mcp:destructive`), and `BearerGuard`'s
  per-tool check (decision #3) will then reject every destructive `tools/call` for
  that instance — no code change, just a narrower token.
- **`gallery:read`** — `/gallery`, `/api/results/*`, media proxy. Bound to the
  `merged_token` from `browse_gallery` via a `sid` claim, so the frontend reads
  only the photos it was shown — not the whole library. Signed server-side inside
  `browse_gallery`. Lifetime = the gallery session; no refresh.
- **`gallery:write`** *(future, out of scope)* — for eventual gallery-driven
  metadata mutation (ratings/tags), so a compromised read token cannot write.

### 5. Mint-endpoint invariants (no self-escalation)

`/admin/token` requires `admin` scope and **refuses to mint `admin`** — it issues
only tool-plane tokens (`mcp:discovery` / `mcp:readOnly` / `mcp:destructive`) and,
if ever needed, `gallery:read`. By default it mints
`mcp:discovery mcp:readOnly mcp:destructive` for the bridge; a read-only Woof
instance mints `mcp:discovery mcp:readOnly` only. Only `/admin/token` and
`browse_gallery` ever issue tokens, and the signing secret is never returned by
any endpoint.

### 6. Session-token binding

For `gallery:read`, `BearerGuard` checks the path's session token equals the JWT
`sid` claim on `/api/results/*` and media routes. Revocation is a non-issue: a
gallery token is only useful while its `sid` session lives in
`GallerySessionManager`, and serving results already requires that session to
exist — an evicted session fails regardless of `exp`.

### 7. Token lifetimes & refresh

Concrete TTLs and refresh behavior for each scope. All lifetimes are enforced by
the `exp` claim and verified by `BearerGuard`; there is no server-side token
registry, so "refresh" always means *mint a new JWT*, never *extend an existing one*.

| Token         | `exp` TTL         | Refreshed by                          | On expiry |
|---------------|-------------------|---------------------------------------|-----------|
| `admin`       | none (process-lifetime) | not refreshed                   | dies with woof; re-minted next launch |
| `mcp:discovery` + `mcp:readOnly` + `mcp:destructive` (one JWT) | 15 minutes | bridge, from `/admin/token` | bridge re-exchanges |
| `gallery:read`| 24 hours          | not refreshed                         | irrelevant — `sid` session is evicted first |

- **`admin` — no `exp` (process-lifetime).** Matches today's opaque token: minted
  once at startup, written to the 0600 discovery file, valid as long as woof runs.
  Adding an `exp` buys nothing — the bridge reads it from the file only at startup,
  and rotating it would mean rewriting the discovery file mid-session. It dies when
  woof shuts down (idle timeout / `/admin/shutdown` / crash) and the next launch
  mints a fresh secret **and** a fresh `admin` JWT. Because the signing secret is
  also per-process, a stale `admin` JWT from a previous woof fails verification
  anyway — no cross-process replay.

- **Tool-plane JWT (`mcp:readOnly` + `mcp:destructive`) — 15-minute `exp`,
  bridge-refreshed.** This is the high-frequency, most-transmitted credential, so it
  is deliberately short-lived. The bridge exchanges its `admin` JWT at `/admin/token`
  for a tool-plane JWT at startup, then **refreshes proactively**: the existing
  `_keepalive_loop` (bridge.py:132, pinging every interval) also checks the JWT's
  remaining lifetime and re-exchanges when under a **5-minute skew margin** (i.e. at
  ~10 min of a 15-min TTL). A **reactive fallback** covers clock skew and missed
  refreshes: on any `401` from `/mcp`, the bridge re-exchanges once and retries the
  request before surfacing the error. 15 min is long enough that refresh traffic is
  negligible (one exchange per ~10 min) and short enough that a leaked tool-plane JWT
  is useless within a coffee break.

- **`gallery:read` — 24-hour `exp`, no refresh.** Deliberately generous because,
  per decision #6, `exp` is not the real gate: the token is only useful while its
  `sid` session lives in `GallerySessionManager`, which evicts by capacity
  (`_MAX_SESSIONS`), not time. A gallery tab left open past 24h fails at the `exp`
  check, which is acceptable — the user re-runs `browse_gallery` to get a fresh
  token and session. No refresh path is added; keeping `gallery:read` non-renewable
  means a leaked gallery token cannot be kept alive indefinitely.

### 8. Woof restart = global revocation; bridge re-discovery

The signing secret is per-process (decision #2), so **stopping woof invalidates
every token ever minted** — the file-held `admin` JWT, any in-flight tool-plane JWT,
and every `gallery:read` JWT sitting in a browser. This is the design's **revocation
lever**: there is no per-token revoke (decision #2's trade-off), but "restart woof"
is a clean, total kill-switch, and the incident response for *any* suspected leak is
simply to stop woof. A fresh launch mints a fresh secret + fresh `admin` JWT, and no
credential from the previous process verifies against the new secret.

This makes the bridge's handling of a **restarted woof** an explicit requirement,
because a restart both rotates the secret *and* rebinds the port:

- **Normal operation** does not hit this. The bridge is spawned per host connection,
  reads discovery once, and its `_keepalive_loop` keeps woof alive for the
  connection's lifetime — so woof does **not** idle-shut-down under an active bridge,
  and each *new* host connection spawns a *new* bridge that re-reads discovery and
  picks up the current port + `admin` JWT. Tool-plane expiry within a live session is
  the ordinary refresh (decision #7), using the still-valid `admin` JWT.
- **Woof crashed or was explicitly stopped mid-session** is the edge case. The
  cached `admin` JWT no longer verifies (new secret) and the old port is likely dead.
  Symptoms are a **connection failure** or, if the port was reused, a `401` even from
  `/admin/token`. On either, the bridge must **re-run discovery**
  (`ensure_woof_running` — which re-reads the file and lazily restarts woof if
  needed), rebuild its HTTP client against the new port, and re-exchange the *new*
  `admin` JWT for a tool-plane JWT. It must **not** silently retry the old endpoint or
  treat the stale `admin` JWT as usable.
- The restart also destroys woof's server-side MCP session, so the bridge cannot
  transparently paper over it: after re-discovery it surfaces the broken session to
  the host, which re-initializes. The bridge's job is to recover *its own*
  connection + credentials, not to hide a lost protocol session.

### Security posture (recorded for reviewers)

- The win is real but **bounded**: the credential transmitted most often (the
  tool-plane JWT, every tool call) is short-lived and cannot mint or shut down;
  `admin` is rarely used and file-guarded; `gallery:read` is confined to the photos
  already shown.
- JWT does **not** remove the trust anchor. `admin` is root-equivalent, so a
  same-uid local attacker who can read the 0600 discovery file (or exec the woof
  binary) is still out of scope — as it is today. The gain over a single token is
  privilege **separation** and **bounded blast radius on leak**, plus uniform
  verification — not a new boundary against a same-uid attacker.
- All minting happens *inside* woof — startup for `admin`, `/admin/token` for
  `mcp`, `browse_gallery` for `gallery:read`. The signing secret never leaves
  woof's process (decision 2), so no external process ever mints tokens.
- **Revocation = restart.** There is no per-token revoke, but stopping woof rotates
  the per-process secret and invalidates *every* outstanding token at once (decision
  #8). That is the incident-response lever for any suspected leak — total, immediate,
  and requiring no token registry.

---

## Changes (proposed design — not implemented in this issue)

### 1. `BearerGuard` — JWT verification + scope enforcement

**File:** `ouestcharlie-woof/src/woof/security.py`

Verify a JWT (HS256, algorithm pinned) against the per-process signing secret
instead of the current opaque string compare. Add a path-prefix → required-scope
map (mirroring the existing `exempt_path_prefixes` mechanism). `dispatch` checks
the endpoint's required scope is in the token (exact membership). For `/mcp`, the
required scope is **not** path-derived: parse the JSON-RPC body and map protocol
methods → `mcp:discovery`, and `tools/call` → the named tool's scope via an explicit
tool→scope map owned by `McpServer` (`readOnlyHint` → `mcp:readOnly`,
`destructiveHint` → `mcp:destructive`). The map is **fail-closed**: a tool with
neither annotation, an unknown tool, or an unknown method has no required scope and
is rejected. For a JSON-RPC **batch** (array body), derive each element's scope and
require the token to satisfy all of them, rejecting the whole batch on any failure.
For `gallery:read` on `/api/results/*` and media routes, check the path
session token equals the `sid` claim. Keep the `?token=` query-param path (for
`<img>`/`<video>`), now carrying the JWT. Add helpers to mint
`admin` / `mcp:discovery`(+`mcp:readOnly`)(+`mcp:destructive`) / `gallery:read` JWTs.

### 2. Segregate admin API + mint endpoint

**Files:** `ouestcharlie-woof/src/woof/http_server.py`, `asgi_server.py`

Move lifecycle routes under `/admin/*` (`/admin/shutdown`, `/admin/keepalive`)
and add `POST /admin/token` — `admin`-scoped, returns a short-lived tool-plane JWT
(`mcp:discovery mcp:readOnly mcp:destructive` by default; `mcp:discovery mcp:readOnly`
for a read-only instance), refuses to mint `admin`. `/healthz` stays outside `/admin`.

### 3. Bridge — token exchange

**File:** `ouestcharlie-woof/src/woof/bridge.py`

Read the `admin` JWT from discovery, exchange it at `/admin/token` for a tool-plane
JWT, use that JWT for all `/mcp` traffic and `admin` for `/admin/*` lifecycle;
refresh the tool-plane JWT near expiry. (Currently calls `/keepalive`/`/shutdown`
at bridge.py:136,181 — update to `/admin/*`.)

Handle a **restarted woof** (decision #8): on a connection failure, or a `401` even
from `/admin/token`, re-run `ensure_woof_running` to re-read discovery (new port +
new `admin` JWT), rebuild the HTTP client, and re-exchange — never reuse the stale
`admin` JWT or the old endpoint. The lost server-side MCP session is surfaced to the
host for re-initialization rather than papered over.

### 4. Stop leaking the master token

**Files:** `ouestcharlie-woof/src/woof/mcp_server.py`, `http_server.py`

Return/embed a `gallery:read` JWT (not `self._token`) as `serverToken`, in
`galleryUrl`'s `?token=`, in the gallery MCP resource, and in the gallery HTML
via `get_gallery_html` (mcp_server.py:393, :512-513, :533; http_server.py:78).

### 5. Wiring

**Files:** `ouestcharlie-woof/src/woof/__main__.py`, `asgi_server.py`

Mint the HMAC signing secret and a startup `admin` JWT; write the `admin` JWT to
the 0600 discovery file. Add PyJWT to woof's dependencies.

### 6. Tests

**Files:** `ouestcharlie-woof/tests/test_security.py`, `test_bridge.py`,
`test_mcp_server.py`, `test_http_server.py`

- Tool-plane JWT rejected on all `/admin/*` (shutdown, keepalive, token); `admin`
  JWT accepted there; `/admin/token` refuses to issue `admin`.
- A `mcp:discovery mcp:readOnly` JWT is **accepted on a read-only `tools/call`** and
  on protocol methods, but **rejected on a destructive `tools/call`**; a full
  `mcp:discovery mcp:readOnly mcp:destructive` JWT is accepted on all.
- **Fail-closed:** a `tools/call` for a tool with no annotation is **rejected** even
  under the full tool-plane JWT; an unknown method / unknown tool name is rejected.
- A discovery-less JWT is rejected on `initialize`/`tools/list`.
- **Batch:** a batch mixing a read-only and a destructive call is **rejected** under
  a `mcp:discovery mcp:readOnly` token (no destructive call slips through behind a
  permitted one); a batch of only read-only calls is accepted; a batch containing an
  unannotated/unknown-tool call is rejected.
- `gallery:read` JWT rejected on `/mcp`, accepted on its own session's
  `/api/results`, **rejected on a different session token**, expires with the
  session.
- Bridge exchanges `admin` → tool-plane JWT and refreshes on expiry.
- **Restart handling:** on a connection failure / `401` from `/admin/token`, the
  bridge re-runs discovery and re-exchanges the *new* `admin` JWT — it does not reuse
  the stale `admin` JWT or the dead endpoint.
- **Global revocation:** a JWT minted by one signing secret is rejected after the
  secret rotates (simulated woof restart) — no token survives a restart.
- `browse_gallery`/`index_photos` results and gallery HTML no longer contain the
  master token; they contain the scoped JWT.

### 7. Documentation

Update the woof LLD security section (and HLD if it describes the token model) to
document the JWT scopes, the `/admin/*` segregation, and the mint-exchange flow.
Do not enumerate individual files.

---

## Open points

### `aud` claim vs. "audience-restricted" wording

Decision #1 sells the tokens as "scoped, **audience-restricted**, short-lived," but
the claim set (decision #2) is `{scope, exp, sid}` — there is no `aud` claim. Today
one `BearerGuard` on one server verifies every token, so audience is effectively
carried by `scope`, and an explicit `aud` would be redundant. **Open question for
review:** either drop "audience-restricted" from the prose, or add an `aud` claim if
we foresee more than one verifier (e.g. a future wally-side guard) where a token
minted for woof must not be accepted elsewhere. Resolve before moving to `todo`.

---

## Verification

- `.venv/bin/pytest tests/ -v` in `ouestcharlie-woof` — new `test_security.py`
  and `test_bridge.py` cases pass (scope rejection, `/admin/token` exchange +
  refusal to mint admin, session-token binding, expiry).
- `cd gallery && npm test` — frontend media/metadata calls still succeed with the
  scoped JWT.
- Manual: launch woof, run `search_photos` → `browse_gallery` in the MCP
  inspector; confirm the gallery renders in the host iframe (media + metadata
  load) while the returned token cannot invoke a destructive tool, reach `/mcp`,
  or hit `/admin/*`.

Out of scope: `gallery:write`, a wally scope split, remote/cross-user threats.

---

## Future work

### Reduce `?token=` exposure in media URLs

`<img>`/`<video>` `src` loads can't set an `Authorization` header, so they carry the
`gallery:read` JWT as a `?token=` query param — which can land in access logs and
browser history. The exposure is already bounded (the token is sid-bound, least-
privileged, and dies with its session), so this is a hardening item, not a blocker.
When revisited, the cheap win is to fetch **images** with the header and render them
via object URLs (no token in the URL), leaving `?token=` only for **video** (which
needs range/streaming), plus a guarantee that logging never records the token.
Cookies were considered and rejected: the gallery renders in the host iframe, where
third-party cookie blocking would break media auth.
