# OEC-44: Reveal original file in system file manager from the gallery

#status:open

## Context

When a user views a photo or video in the embedded gallery (running inside Claude
Desktop or another MCP host), there is currently no way to open the *original* file on
disk — you can only look at the derived thumbnail/preview. Users working with a
local-filesystem library often want to jump from the gallery to the actual file (to
edit it in another app, move it, inspect siblings in the same folder, etc.) **without
downloading a copy**.

The gallery's host bridge is the MCP Apps SDK (`@modelcontextprotocol/ext-apps`, see
`gallery/src/App.svelte`). That bridge deliberately exposes **no** primitive that
opens or reveals a local path:

- `openLink({ url })` opens a URL in the default browser — URL-oriented, not a
  file-manager reveal, and the host may deny it.
- `downloadFile(...)` is a host-mediated **export** (save dialog) — the exact
  copy-producing behaviour we want to avoid.

The only viable route is the same one the gallery already uses to talk to the server:
`mcpApp.callServerTool(...)` (the bridge already drives `updateModelContext` /
`sendMessage` from `gallery/src/components/IndexingProgress.svelte`). A **new Woof MCP
tool** reconstructs the absolute path server-side from identifiers the gallery already
holds, and runs the OS-native reveal command.

This only makes sense for local-filesystem backends. Per `CLAUDE.md` (storage-agnostic:
"Never hardcode assumptions about storage backend"), the tool must return a friendly
non-error result for cloud-mounted / remote backends, and the UI must hide or disable
the action in that case.

---

## Changes

### 1. New Woof MCP tool `reveal_media_file`

**File:** `ouestcharlie-woof/src/woof/mcp_server.py` (register near `browse_gallery`,
~L397)

App-invoked tool that reveals the original media file in the OS file manager.

- **Args:** `library`, `partition`, `content_hash`, `filename` — the same identifiers
  the gallery already carries per match (see `gallery/src/lib/api.svelte.js`
  `previewUrl`/`videoUrl` and the match objects in `App.svelte`).
- **Path resolution:** resolve the entry's absolute local path through the
  Backend/Library abstraction (`backend.py`, the `local_path()` accessor already relied
  on by the video LLD, #39a §1). Do **not** rebuild paths by string concatenation.
- **Backend gating:** if the resolved backend is not local-filesystem (cloud-mounted /
  remote), return `{ "revealed": false, "reason": "not-local" }` rather than raising —
  the model/host should treat this as a normal outcome, not an error.
- **Path-traversal guard:** after resolution, verify the real path is inside the
  library root (`Path.resolve()` + `is_relative_to`) before launching anything. Reject
  otherwise with `{ "revealed": false, "reason": "out-of-root" }`.
- **Cross-platform reveal** (macOS / Windows / Linux — `CLAUDE.md`):
  - macOS: `open -R <path>` (selects the file in Finder)
  - Windows: `explorer /select,<path>` (selects the file in Explorer)
  - Linux: `xdg-open <parent-dir>` — there is no portable single-file-select, so open
    the containing directory (see open points)
- Launch via `subprocess.run` with an **argument list** (never `shell=True`), so the
  path is passed as a single argv element and needs no shell quoting.
- **Visibility:** register with `visibility: ["app"]` so the tool is invoked by the
  gallery UI and not surfaced as a model-callable action (MCP Apps app-only pattern).

```python
# Sketch — follow the existing @self.mcp.tool registration style in mcp_server.py
@self.mcp.tool(visibility=["app"])
async def reveal_media_file(library: str, partition: str,
                            content_hash: str, filename: str) -> dict:
    backend = self._resolve_backend(library)
    if not backend.is_local:
        return {"revealed": False, "reason": "not-local"}
    path = backend.local_path(partition, content_hash, filename).resolve()
    if not path.is_relative_to(backend.root.resolve()):
        return {"revealed": False, "reason": "out-of-root"}
    _reveal_in_file_manager(path)   # platform switch, subprocess.run([...])
    return {"revealed": True}
```

### 2. Gallery UI action

**File:** `gallery/src/components/PreviewPanel.svelte` (the details panel, per #42)

Add a "Reveal in Finder/Explorer" button to the metadata block. Show it only when the
current library backend is local (see gating note below). On the `revealed: false`
response, surface the reason unobtrusively (disable the button or a small toast).

**File:** `gallery/src/lib/api.svelte.js`

Add a helper alongside `thumbnailUrl()`/`previewUrl()`:

```js
export async function revealMediaFile(mcpApp, match) {
  const res = await mcpApp.callServerTool({
    name: 'reveal_media_file',
    arguments: {
      library: match.library, partition: match.partition,
      content_hash: match.contentHash, filename: match.filename,
    },
  });
  // parse res content → { revealed, reason }
}
```

**Backend-locality gating:** the button should only appear for local libraries.
Determine whether the `browse_gallery` tool result payload already carries backend
locality (parsed in `App.svelte` `ontoolresult`); if not, add a boolean flag to that
payload in `mcp_server.py`'s `browse_gallery` return dict and thread it through.

### 3. Tests

**File:** `ouestcharlie-woof/tests/` (new test module for `reveal_media_file`)

- Local backend → resolves path, calls the reveal helper, returns `revealed: True`.
- Cloud/non-local backend → `revealed: False, reason: "not-local"`, no subprocess call.
- Path-traversal attempt (crafted `filename`/`content_hash`) → `out-of-root`, no launch.
- Per-OS argv construction: monkeypatch `sys.platform` and mock `subprocess.run`;
  assert the exact argument list for macOS / Windows / Linux.

Run with `.venv/bin/pytest ouestcharlie-woof/tests/ -k reveal -v`.

### 4. Documentation

- `HLD.md`: brief mention only if the reviewers consider the new interaction pattern
  (a gallery UI action proxying to an OS-side effect via an app-only MCP tool) worth
  recording. No XMP/manifest schema change, so no data-model edit.

---

## Open points

- [ ] **Backend-locality detection:** confirm whether `browse_gallery`'s result already
      exposes backend locality, or whether a new flag must be added and threaded to the
      UI.
- [ ] **Linux single-file select:** `xdg-open` opens the containing directory, not the
      selected file — acceptable for V1? (File-manager-specific selection, e.g.
      `nautilus --select`, is not portable across desktop environments.)
- [ ] **Host support for app-only tool invocation:** verify `callServerTool` is exposed
      on the app object the gallery holds, and that Claude Desktop's current host allows
      an app-only tool to be invoked from the UI (vs. only model-invoked tools).

---

## Verification

- `.venv/bin/pytest ouestcharlie-woof/tests/ -k reveal -v`
- Manual: launch the gallery, open a photo from a **local** library, click Reveal → the
  OS file manager opens with the file selected (macOS/Windows) or its containing folder
  shown (Linux); no file is downloaded/copied.
- Manual: open a photo from a **cloud-mounted** library → the button is hidden/disabled
  or shows a friendly "not available for this backend" message; no crash, no subprocess
  launched.
