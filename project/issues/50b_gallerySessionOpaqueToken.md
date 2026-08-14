# OEC-50b: Per-session opaque gallery tokens (lightweight alternative to OEC-50)

#status:done

Status flow: draft (write spec) -> open (review spec) -> todo (spec validated) -> ongoing (implementation started) -> done (merged)

## Context

This is an **alternative to [OEC-50](50_leastPrivilegeGalleryToken.md)**, not an
addition. OEC-50 proposes scoped JWT capability tokens (a per-process signing secret,
`admin`/`mcp:*`/`gallery:read` scopes, an `/admin/token` exchange, and short-lived
refresh). That machinery buys privilege *separation across every hop* — but the only
credential that actually escapes the trusted bridge↔woof loopback channel is the one
handed to the **gallery frontend**. Everything else (the `/mcp` control plane,
lifecycle, destructive tools) is transmitted only between the bridge and woof, both
same-uid loopback processes — a boundary OEC-50 itself declares out of scope.

**50b closes the one real exposure with almost no new machinery:** keep today's
single opaque master token for the bridge↔woof control plane exactly as-is, and stop
handing it to the gallery. The gallery instead authenticates with the **per-session
opaque token woof already mints** — `GallerySessionManager` returns a
`secrets.token_urlsafe(16)` handle per `browse_gallery`, and it already appears in
the route paths (`/gallery/{token}`, `/api/results/{token}`). We simply teach
`BearerGuard` to accept that session token on gallery read routes and nowhere else.

No PyJWT, no signing secret, no scope claims, no `/admin/*` segregation, no token
exchange, no refresh loop, no bridge changes.

## Decisions

### 1. Two token classes, both opaque

- **Master token** — unchanged: `secrets.token_urlsafe(32)`, minted at startup,
  written to the 0600 discovery file, used by the bridge for `/mcp`, `/keepalive`,
  `/shutdown`. Grants **everything** (including gallery routes, for simplicity).
  Lifetime = the woof process, as today.
- **Session token** — the existing per-session `secrets.token_urlsafe(16)` handle
  from `GallerySessionManager` (and the indexing `session_id` from the indexing
  session manager). A **gallery** session token grants only that session's
  `/gallery`, `/api/results`, and `/media` routes; an **indexing** session token
  grants only that session's `/api/indexing` routes. No new token type is introduced
  — the session *handle* becomes the session *credential*, carried in the URL path.

### 2. `BearerGuard` accepts either, with route + session binding

Every session-scoped route carries its session token **in the path**, so that token
is both the credential and the scope key — no `?token=` query param and no
`Authorization` header are needed for gallery/media/indexing traffic. `BearerGuard`
holds references to the **two** session managers (gallery and indexing) and resolves
each request:

- `Authorization: Bearer <master>` (or `?token=<master>`) → allow any route (as today).
- otherwise, for a session-scoped route the **in-path** token must be a live session
  in the manager that owns that route family; anything else → `401`.

| Route | master | session token |
|-------|--------|---------------|
| `/mcp`, `/keepalive`, `/shutdown` | ✓ | ✗ (control plane — no session token accepted) |
| `/gallery/{token}`, `/api/results/{token}`, `/api/results/{token}/page/{page}` | ✓ | ✓ **iff** `{token}` is a live **gallery** session |
| `/media/{token}/{kind}/{library}/{rest}` | ✓ | ✓ **iff** `{token}` is a live gallery session **and** the file is in that session (checked in `proxy_media` → `403`) |
| `/api/indexing/{session_id}`, `/api/indexing/{session_id}/cancel` | ✓ | ✓ **iff** `{session_id}` is a live **indexing** session |
| `/healthz` | public | public |
| `/gallery-static/` | exempt | exempt |

Two things change from today's server:

1. **Media moves under a session prefix.** The proxy route becomes
   `/media/{session_token}/{kind}/{library}/{rest}` instead of the session-agnostic
   `/{kind}/{library}/{rest}`. The path token replaces the `?token=` query param
   (which is removed) and gives `proxy_media` the session context it needs to enforce
   scope.
2. **`proxy_media` enforces scope, not just liveness.** Being a live gallery token is
   **necessary but not sufficient** — `proxy_media` `403`s unless the requested
   `{library}/{rest}` corresponds to a match in that session's result set. Every
   `kind` (thumbnail / preview / video) of an **in-session** file is allowed; any
   file **not** in the session is refused even with a valid token. For a merged /
   chained session the check spans the union of all chained matches.

Gallery (`/api/results`, `/media`) and indexing (`/api/indexing`) are bound to their
**own** manager: an indexing `session_id` cannot read gallery results or media, and a
gallery token cannot read indexing progress. A session-A token cannot read session-B.

**Merged sessions.** `browse_gallery` returns the `merged_token`; the frontend builds
every `/media/{merged_token}/…` and `/api/results/{merged_token}` URL from it, and
`proxy_media` checks membership against the **merged** session's matches (which for a
chained merge span all source sessions). The original per-query source tokens remain
live in the manager, but the frontend uses only the merged token — so media is scoped
to exactly the set the user was shown in that merged view.

### 3. Revocation is free

A session token is only valid while its session lives in the manager, which already
evicts by capacity (`_MAX_SESSIONS`). Ending or evicting a session revokes its token
instantly — no `exp`, no registry, no signing-secret rotation. Stopping woof still
invalidates the master token globally.

### 4. What 50b deliberately does *not* do

- **No admin/mcp/destructive scope split.** The bridge↔woof channel keeps a single
  full-privilege token. Justification: that channel is same-uid loopback, which
  OEC-50 also treats as out of scope; segregating it buys defense-in-depth against a
  threat neither issue defends against.
- **No read-only Woof provision** and **no uniform token format** — the two
  forward-looking benefits unique to OEC-50's JWT model. If either becomes a real
  requirement, revisit OEC-50.

## Changes (proposed design — not implemented in this issue)

### 1. `BearerGuard` — accept master or live-session token, bound by manager

**File:** `ouestcharlie-woof/src/woof/security.py`

Give `BearerGuard` references to **both** the gallery and indexing session managers
(already shared with the HTTP server). Extend `dispatch`: master token (header or
query) → allow all; otherwise resolve the route family and require the **in-path**
session token to be live in that family's manager — gallery token for
`/gallery`/`/api/results`/`/media`, indexing token for `/api/indexing` — rejecting
`/mcp` and lifecycle routes for any session token. The per-file media scope check
lives in `proxy_media` (change 3), not here.

### 2. Stop leaking the master token to the gallery

**Files:** `ouestcharlie-woof/src/woof/mcp_server.py`, `http_server.py`

Return/embed the **session token** (not `self._token`) as `serverToken`, in
`galleryUrl`, in the gallery MCP resource, and in the gallery HTML via
`get_gallery_html` (mcp_server.py:393, :512-513, :533; http_server.py:78). Each
frontend-facing surface uses the token of the session it belongs to.

### 3. Session-prefixed media route + scope check

**Files:** `ouestcharlie-woof/src/woof/http_server.py`, gallery frontend

Move the media proxy to `/media/{session_token}/{kind}/{library}/{rest}` and drop the
`?token=` query param. The gallery frontend builds media URLs with the
`/media/{token}/` prefix from the session token it was handed (today the three
builders in `gallery/src/lib/api.svelte.js` — `thumbnailUrl`, `previewUrl`,
`videoUrl` — append `?token=`; they instead prepend `/media/{token}`).

**The exact membership check.** A match record carries `library`, `partition`,
`avifHash` (thumbnail grid), `contentHash` (preview/video), and `tileIndex`. The
three media URL shapes map to a match as:

| `kind` | URL `rest` | match field to compare |
|--------|-----------|------------------------|
| `thumbnail` | `{partition}/{avifHash}` | `(library, partition, avifHash)` |
| `previews`  | `{partition}/{contentHash}.jpg` | `(library, partition, contentHash)` |
| `video`     | `{partition}/{contentHash}.{ext}` | `(library, partition, contentHash)` |

`proxy_media` parses `{library}` and `{rest}` into `(library, partition, hash)` —
`partition` may contain slashes, so `hash` is the **last** path segment with any
extension stripped, and `partition` is everything before it — then `403`s unless the
session (union of chained matches for a merged session) contains a match whose
`library` + `partition` + (`avifHash` for `thumbnail`, else `contentHash`) equal that
tuple. Build the allowed-tuple set once per request from the session's loaded matches.

**Thumbnail scoping is at grid granularity — accepted.** AVIF thumbnails are packed
into an 8-wide grid file shared by many photos and addressed by `avifHash` +
`tileIndex`; the URL carries only `avifHash`. So a thumbnail request is authorized
whenever *any* in-session match references that `avifHash`, and the whole grid is
served. This is **accepted, not a gap to close**: a grid packs photos that are
colocated in the same library and same partition, so the neighboring tiles are
low-res thumbnails of adjacent photos the user has no a-priori reason to be shielded
from. Preview and video (per-`contentHash`) remain scoped per file.

Because the token now rides in the path segment for `<img>`/`<video>` — not a query
param — and is scoped per session, this also closes the query-param exposure that
OEC-50 deferred to future work.

### 4. Tests

**Files:** `ouestcharlie-woof/tests/test_security.py`, `test_mcp_server.py`,
`test_http_server.py`

- A gallery session token is **accepted** on its own `/gallery/{t}` /
  `/api/results/{t}`, **rejected** on `/mcp`, `/keepalive`, `/shutdown`, and
  **rejected on a different session's `/api/results`**.
- **Media scope:** `/media/{t}/{kind}/{library}/{rest}` is **accepted** for a file in
  session `t`, **403** for a file **not** in session `t` (even with a valid `t`), and
  **rejected** when `t` is not a live gallery session. A **merged** token reaches
  every file across its chained source sessions and nothing outside them.
- **Manager isolation:** an indexing `session_id` is accepted on its own
  `/api/indexing/{sid}` but **rejected** on `/api/results`/`/media`; a gallery token
  is **rejected** on `/api/indexing`.
- An unknown/evicted token is rejected everywhere (revocation-by-eviction).
- The master token still reaches every route.
- `browse_gallery`/`index_photos` results and gallery HTML contain the session
  token, **not** the master token; media URLs use the `/media/{token}/` prefix with
  no `?token=` query param.

### 5. Documentation

Update the woof LLD security section to describe the two token classes, the
session-in-path binding, and the per-file media scope check. Do not enumerate
individual files.

## Verification

- `.venv/bin/pytest tests/ -v` in `ouestcharlie-woof` — new `test_security.py` cases
  pass (session-token route binding, cross-session rejection, per-file media scope /
  `403`, manager isolation, control-plane rejection, eviction = revocation).
- `cd gallery && npm test` — frontend media/metadata calls still succeed with the
  session token via `/media/{token}/` URLs (no `?token=`).
- Manual: launch woof, run `search_photos` → `browse_gallery` in the MCP inspector;
  confirm the gallery renders in the host iframe (thumbnails + video load) while the
  returned token cannot invoke a tool, reach `/mcp`, hit `/shutdown`, or fetch a
  library file outside the session (expect `403`).

Out of scope: everything OEC-50 lists, plus the admin/mcp/destructive scope split and
the JWT format itself (that is the point of this alternative).
