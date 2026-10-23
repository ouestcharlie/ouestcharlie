# OEC-44: Reveal original file in system file manager from the gallery

#status:open

Status flow: draft (write spec) -> open (review spec) -> todo (spec validated) -> ongoing (implementation started) -> done (merged)

## Context

When a user views a photo or video in the gallery, there is no way to get to the
*original* file on disk, only to the derived thumbnail or preview. Users often want
to jump from the gallery to the actual file to edit it in another app, move it, or
look at the other files in its folder, **without downloading a copy**.

### How the gallery talks to Woof today

The gallery reaches the MCP host through the MCP Apps SDK
(`@modelcontextprotocol/ext-apps` 2.x, `gallery/src/lib/mcpSession.svelte.js`). It
uses the host channel for host context, tool results, `updateModelContext` and
`sendMessage`, but calls no server tool. All gallery data comes from Woof's HTTP
server, through routes scoped by the gallery session id
(`ouestcharlie-woof/src/woof/http_server.py`):

- `/gallery/{session_id}/results` and `/gallery/{session_id}/results/page/{page}`
- `/gallery/{session_id}/media/{kind}/{library}/{rest}`: served only if the file is
  one of that session's matches (`_media_in_session`). A valid session id alone is
  not enough.

The gallery also runs on its own in a browser, through `/gallery/{session_id}/html`,
with no MCP host at all.

The host bridge has no primitive that reveals a local path. `openLink` opens a URL,
and `downloadFile` exports a copy, which is what we want to avoid. An app-only MCP
tool (`AppConfig(visibility=["app"])` in fastmcp, `App.callServerTool` in ext-apps,
gated on `getHostCapabilities()?.serverTools`) would work in a host that supports
it, but not in the standalone browser mode.

So the reveal is a **new route on Woof's HTTP server**, scoped like the media proxy.
It works in both modes, depends on no host capability, adds nothing to the model's
tool list, and needs no model turn.

### Which libraries can be revealed

Woof runs on the user's machine, and both existing library types are folders on the
local filesystem: `filesystem`, and `cloud_mount`, a locally mounted cloud folder
(`CloudMountedBackend` is a `LocalBackend` over the mount). Finder and Explorer show
files on a cloud mount like any other file, and revealing a file does not download
it. So every library can be revealed today.

A future backend type with no local path (e.g. a remote API) could not. A
per-library `revealable` property keeps that decision in one place, and the UI hides
the action for libraries where it is False.

### Identical copies

Since OEC-60, identical copies of a file within a partition share one index row,
whose `filename` names one representative copy. The reveal shows that copy.

Intended outcome: from the preview panel, one click opens the system file manager on
the original file (selected, where the platform allows it), for any library whose
files are on the local filesystem. No copy is made.

---

## Changes

> ⚠️ §1–§3 and §6 have Woof resolve OS paths, which it must not do. See the blocking
> open point at the end: they will be reworked to move that work to Wally.

### 1. `revealable` library property

**File:** `ouestcharlie-woof/src/woof/config.py` (`LibraryConfig`)

```python
_REVEALABLE_TYPES = frozenset({"filesystem", "cloud_mount"})

@property
def revealable(self) -> bool:
    """Whether the library's files are on the local filesystem, so the OS file
    manager can show them."""
    return self.type in _REVEALABLE_TYPES
```

It is derived from the library type, not stored in `config.json`.

### 2. Reveal route

**File:** `ouestcharlie-woof/src/woof/http_server.py`

`POST /gallery/{session_id}/reveal`, JSON body `{"library", "partition",
"contentHash"}`.

1. Unknown session → 404, as the other gallery routes.
2. Find the match in the session with that `library`, `partition` and
   `contentHash`. No match → 403 (`"File not in gallery session"`), as
   `proxy_media`. Share the lookup with `_media_in_session` instead of duplicating it.
3. Take `filename` from that **server-side match**. The request never names the
   file.
4. Look up the library config. Not revealable →
   `{"revealed": false, "reason": "not-revealable"}`.
5. `path = (Path(library.path) / partition / filename).resolve()`. If it is not
   `is_relative_to(Path(library.path).resolve())` →
   `{"revealed": false, "reason": "out-of-root"}`. This is a second line of defense,
   since the filename comes from the index.
6. File missing (moved or deleted since indexing) →
   `{"revealed": false, "reason": "missing"}`.
7. Reveal it (step 3), then `{"revealed": true}`.

The `revealed: false` outcomes are normal results (HTTP 200), not errors.

`build_gallery_app` has no library configs today. Pass a lookup callable, in the same
style as `wally_connection_fn`:

```python
library_lookup: Callable[[str], LibraryConfig | None] | None = None
```

Woof passes `self.config.get_library`. The route uses the match's `library` field,
because a merged session (`ChainedSessionHandler`) can span several libraries.

### 3. Cross-platform reveal helper

**File:** `ouestcharlie-woof/src/woof/reveal.py` (new)

`reveal_in_file_manager(path: Path) -> None`, with a platform switch. Always launch
with an argument list, never `shell=True`.

- **macOS:** `["open", "-R", str(path)]`, which selects the file in Finder.
- **Windows:** `["explorer", f"/select,{path}"]`, the switch and path as **one**
  argument. Explorer returns exit code 1 even when it worked, so ignore the return
  code.
- **Linux:** first ask the file manager to select the file through the freedesktop
  D-Bus interface `org.freedesktop.FileManager1.ShowItems`, which Nautilus, Dolphin,
  Nemo and others implement. Pass the path as a `file://` URI:

  ```
  ["dbus-send", "--session", "--print-reply",
   "--dest=org.freedesktop.FileManager1", "/org/freedesktop/FileManager1",
   "org.freedesktop.FileManager1.ShowItems",
   f"array:string:{path.as_uri()}", "string:"]
  ```

  If that fails (no `dbus-send`, or no service), fall back to
  `["xdg-open", str(path.parent)]`, which opens the containing folder.

Run the launch off the event loop (`asyncio.to_thread` or
`asyncio.create_subprocess_exec`), with a short timeout. A launch failure is logged,
and the route returns `{"revealed": false, "reason": "launch-failed"}`.

### 4. Expose `revealable` to the gallery

**File:** `ouestcharlie-woof/src/woof/gallery_session_manager.py`

Add `"revealable": {library_name: bool}` to the payload of `transfert_object()`,
covering every library that appears in the session's matches. The results and page
routes already return this payload, so nothing else changes on the server side. The
session manager needs the same library lookup as the route.

### 5. Gallery UI

**File:** `gallery/src/lib/api.svelte.js`

```js
export async function revealMediaFile(match) {
  // POST {library, partition, contentHash} to `${resolvedOrigin}/gallery/${sessionId}/reveal`
  // through the existing request() helper; returns {revealed, reason}
}
```

**File:** `gallery/src/components/PreviewPanel.svelte`

- Add a "Show in file manager" button in the metadata block, next to the file name.
  Use a platform-specific label (Finder / Explorer / file manager) only if the
  platform can be detected reliably; otherwise keep the generic one.
- Show it only when the payload's `revealable[match.library]` is true.
- On `revealed: false`, show the reason in a short inline message (`missing`: "File
  not found, it may have been moved since indexing").
- New messages through paraglide, in every locale.

### 6. Tests

**File:** `ouestcharlie-woof/tests/test_http_server.py`

- Match in session → the reveal helper is called with the resolved absolute path,
  and the route returns `revealed: true`.
- Unknown session → 404.
- `contentHash` not in the session, or the right hash with another partition or
  library → 403, no launch.
- The route ignores any `filename` in the request body.
- A match whose `filename` escapes the root (e.g. `../x.jpg`) → `out-of-root`, no
  launch.
- File missing on disk → `missing`, no launch.
- `cloud_mount` library → revealed like `filesystem`.
- Library with a non-revealable type → `not-revealable`, no launch.
- Results payload contains `revealable` for each library of the session's matches.

**File:** `ouestcharlie-woof/tests/test_reveal.py` (new)

- Per-platform argv, with `sys.platform` monkeypatched and the subprocess call
  mocked: macOS, Windows (single `/select,…` argument, exit code 1 treated as
  success), Linux (D-Bus call, then the `xdg-open` fallback when it fails).

**File:** `gallery/src/components/PreviewPanel.test.js`

- The button shows only when `revealable[match.library]` is true.
- Clicking it posts the match identifiers. A `revealed: false` response shows the
  message.

### 7. Documentation

**File:** `ouestcharlie-woof/doc/design/woof_LLD.md`

Document the reveal route next to the other gallery routes: session scoping,
filename taken from the session's match, the `revealable` property, the result
reasons, and the per-platform commands.

---

## Verification

1. `.venv/bin/pytest tests/ -k "reveal or http_server" -v` in `ouestcharlie-woof`;
   gallery tests with `npm test` in `ouestcharlie-woof/gallery`.
2. In Claude Desktop, open a photo from a `filesystem` library and click the
   button: Finder (macOS) or Explorer (Windows) opens with the file selected. On
   Linux, the file is selected, or its folder opens if the file manager has no
   D-Bus support. No file is downloaded or copied.
3. Same with a video, and with a photo from a `cloud_mount` library.
4. Same from the standalone gallery in a browser (`/gallery/{session_id}/html`).
5. Move a file away after indexing, then click the button: the "not found" message
   shows, and nothing is launched.
6. With `curl`, post a `contentHash` that is not in the session: 403.

---

## Open points

### ⚠️ BLOCKING: Woof must not resolve OS paths. Move path work to the agents

**This point must be settled before the spec moves to `todo`. It changes Changes
§1–§3 and §6.**

Woof is the orchestrator. Storage access, and the `Backend` abstraction that maps
library-relative paths to OS paths (`Backend.local_path`), belong to the agents
(Wally, Whitebeard). As written, the spec has Woof join `library.path`, the partition
and the filename into an OS path, check that path against the root, test the file
for existence, and launch the file manager. Woof also decides `revealable` from the
library type string. All of that bypasses the backend abstraction, and it would have
to be redone in Woof for every new backend type.

Proposed direction: **Wally owns the reveal**, Woof only checks the session scope
and forwards the request.

- Woof keeps the session check (§2 steps 1–2: unknown session → 404, match not in
  session → 403), then forwards the request to Wally, as `proxy_media` already does
  for thumbnails, previews and videos.
- Wally resolves the file through its backend (`backend.local_path`), reading the
  filename from its own index by `(partition, content_hash)` rather than taking it
  from Woof. Wally does the root check, the existence check and the reveal launch
  (§3's helper moves to Wally, or to py-toolkit if Whitebeard may need it).
- `revealable` becomes a backend capability (e.g. a `Backend` property, true for
  `LocalBackend` and so for `CloudMountedBackend`), reported by Wally, instead of
  a type check in Woof's `LibraryConfig` (§1). Woof passes it through to the
  gallery as is.

To decide:

1. **Transport Woof → Wally:** a new route on Wally's preview HTTP server (the server
   `proxy_media` already forwards to, with its bearer token), or a Wally MCP tool
   called through `agent_client`? The HTTP route mirrors the media path. The MCP
   tool keeps Wally's preview server read-only (GET only).
2. **Is Wally the right agent?** Wally is the read-only search agent. Launching a
   file manager writes nothing to the library, but it is a side effect on the
   user's desktop. Is that acceptable for Wally, or does it belong elsewhere?
3. **How the gallery learns `revealable`:** Wally adds it to each search result page
   (per library), or Woof asks Wally once per library and caches it, like
   `list_search_fields`.

- Button label: generic ("Show in file manager"), or per platform? The gallery runs
  in the host's webview, where `navigator.userAgentData`/`navigator.platform` may not
  reflect the OS reliably. Alternatively, the server could add its platform to the
  payload.
- Should a reveal also be offered from the grid (e.g. context menu), or only from the
  preview panel? Preview panel only in V1.
