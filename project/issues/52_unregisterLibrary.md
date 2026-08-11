# OEC-52: Unregister a library (MCP tool) with optional metadata purge

#status:done

Status flow: draft (write spec) -> open (review spec) -> todo (spec validated) -> ongoing (implementation started) -> done (merged)

## Context

A library can be **registered** (today's `add_library` tool in `mcp_server.py`,
persisted to `~/.ouestcharlie/config.json` via `WoofConfig.add_library`) but there
is no way to **unregister** one. Removing a library today means hand-editing the
config file.

This issue adds an MCP tool to unregister a library and, for a clean and symmetric
MCP surface, **renames the existing `add_library` tool to `register_library`** so
the pair reads `register_library` / `unregister_library`. It also introduces a
deliberate split
between two very different operations:

1. **Forget the library** (default, non-destructive) — drop the entry from Woof's
   configuration. Nothing on disk is touched; the photos and all metadata remain
   exactly where they are and the library can be re-registered later at the same
   path.
2. **Purge the metadata directory** (opt-in) — additionally delete the
   `.ouestcharlie/` directory at the library root (manifests, `summary.json`, the
   LanceDB index, AVIF thumbnail grids, cached previews). This is a destructive,
   storage-side operation, so it is owned by **Whitebeard** — the write/indexing
   agent that *creates* `.ouestcharlie/` — not by Woof directly and not by the
   read-only Wally agent.

### Non-negotiable invariant: never remove XMP sidecars

The purge must **never** delete XMP sidecars. Sidecars live *alongside the original
photos*, outside `.ouestcharlie/`, and represent user-facing enrichment (tags,
ratings, descriptions) that is expensive or impossible to regenerate. Deleting the
`.ouestcharlie/` directory only removes derived/cacheable artifacts — manifests,
index, thumbnails, previews — all of which a subsequent re-index rebuilds. Because
sidecars are never under `.ouestcharlie/`, scoping the purge to that directory
already guarantees the invariant; the spec and tests make it explicit so a future
change cannot silently broaden the deletion.

---

## Decisions

### 0. Symmetric tool names: `register_library` / `unregister_library`

Rename the current `add_library` MCP tool to `register_library`, and name the new
tool `unregister_library`. This keeps the public MCP API a clean matched pair and
matches the "(un)register a library" mental model. The internal
`WoofConfig.add_library` / `WoofConfig.remove_library` methods keep their names —
only the MCP-facing tool names change. Update the one user-facing mention of
`add_library` in the empty-libraries hint (`mcp_server.py:563`) to
`register_library`.

### 1. One unregister tool, one opt-in flag

A single `unregister_library(library_name, purge_metadata=False)` tool. Default
behavior is the safe one (forget only). Purge is strictly opt-in via
`purge_metadata=True`, mirroring how destructive intent is made explicit elsewhere.

### 2. Purge is a Whitebeard tool, not a Woof/Wally responsibility

Whitebeard already owns writes to `.ouestcharlie/` (it creates manifests, the
index, and thumbnails during `index_library`, and already deletes stale
`.ouestcharlie/<partition>/` directories). Deletion of the whole directory belongs
in the same agent. Wally stays read-only (it "never writes XMP sidecars or
manifests") and Woof stays storage-agnostic — it delegates the deletion through
the normal agent-call path rather than touching the backend itself.

### 3. Storage-agnostic deletion via the backend abstraction

The purge uses `Backend.delete_dir(METADATA_DIR)`, which already exists on the
backend interface (`backend.py`) and is implemented for the local backend
(`shutil.rmtree`). No storage-specific assumptions in Whitebeard or Woof.

### 4. Ordering and partial failure

Woof calls Whitebeard's purge tool **first** (when requested); only on success
does it remove the config entry. If the purge fails, the library stays registered
and the error surfaces to the caller, so the user can retry rather than being left
with an unregistered library and a half-deleted metadata directory.

---

## Changes

### 1. Woof `register_library` rename + `unregister_library` MCP tool

**File:** `ouestcharlie-woof/src/woof/mcp_server.py`

Rename the `add_library` tool to `register_library` (function name and any
`@mcp.tool(name=...)`; the body is unchanged). Add the new tool beside it:

```python
@mcp.tool()
async def unregister_library(library_name: str, purge_metadata: bool = False) -> dict:
    """Unregister a photo library.

    By default this only removes the library from Woof's configuration —
    nothing on disk is touched, and the library can be re-registered later at
    the same path. Photos and XMP sidecars are always left intact.

    Args:
        library_name: Name of the library to unregister (from list_libraries).
        purge_metadata: When True, also delete the library's ``.ouestcharlie/``
            metadata directory (manifests, index, thumbnails, previews) at the
            library root. XMP sidecars are never deleted. Defaults to False.

    Returns:
        ``name`` — the library that was unregistered.
        ``status`` — ``"removed"``.
        ``metadataPurged`` — True if ``.ouestcharlie/`` was deleted.
    """
    library = self._require_library(library_name)
    if purge_metadata:
        # Delegate destructive delete to Whitebeard; only forget on success.
        await self._agent.call_tool("whitebeard", "purge_metadata", {}, library)
    self.config.remove_library(library_name)
    _log.info("Library %r removed (purge_metadata=%s)", library_name, purge_metadata)
    return {"name": library_name, "status": "removed", "metadataPurged": purge_metadata}
```

### 2. Woof config — `remove_library`

**File:** `ouestcharlie-woof/src/woof/config.py`

Add the inverse of `add_library`:

```python
def remove_library(self, name: str) -> None:
    """Remove a library by name, then persist. No-op if absent is a KeyError."""
    if not any(b.name == name for b in self.libraries):
        raise KeyError(name)
    self.libraries = [b for b in self.libraries if b.name != name]
    self.save()
```

(`_require_library` in `mcp_server.py` already raises a clear error for an unknown
name before this is reached; keep both consistent.)

### 3. Whitebeard `purge_metadata` tool

**File:** `ouestcharlie-whitebeard/src/whitebeard/agent.py`

Add a destructive tool that deletes the whole metadata directory via the backend
abstraction:

```python
@mcp.tool(name="purge_metadata")
async def purge_metadata_tool(ctx: Context) -> dict:
    """Delete the library's ``.ouestcharlie/`` metadata directory.

    Removes all derived artifacts — manifests, ``summary.json``, the LanceDB
    index, AVIF thumbnail grids, and cached previews — at the backend root.
    XMP sidecars are never touched: they live alongside the original photos,
    outside ``.ouestcharlie/``. Photos are never touched. A subsequent
    ``index_library`` rebuilds everything this removes.

    Returns:
        ``metadataDir`` — the directory that was deleted (``.ouestcharlie``).
        ``existed`` — False if there was nothing to delete.
    """
    existed = await self.backend.exists(METADATA_DIR)
    if existed:
        await self.backend.delete_dir(METADATA_DIR)
    return {"metadataDir": METADATA_DIR, "existed": existed}
```

`METADATA_DIR` comes from `ouestcharlie_toolkit.schema`. Scoping the delete to
`METADATA_DIR` is what guarantees sidecars and originals are untouched.

### 4. Tests

**Files:** `ouestcharlie-woof/tests/test_mcp_server.py`,
`ouestcharlie-woof/tests/test_config.py`,
`ouestcharlie-whitebeard/tests/` (new `test_purge_metadata.py`)

- The renamed `register_library` tool still registers a library (update the
  existing `test_add_library` accordingly).
- `unregister_library` without `purge_metadata` drops the config entry and does
  **not** call Whitebeard; the `.ouestcharlie/` directory (mock) is untouched.
- `unregister_library(purge_metadata=True)` calls Whitebeard `purge_metadata`,
  then removes the config entry; returns `metadataPurged=True`.
- Purge failure leaves the library registered and propagates the error (config
  entry still present).
- `unregister_library` on an unknown name raises the same error `_require_library`
  already raises.
- `WoofConfig.remove_library` persists (reload shows the library gone) and raises
  `KeyError` for an absent name.
- Whitebeard `purge_metadata` deletes `.ouestcharlie/` via the backend but leaves
  XMP sidecars and originals in place; `existed=False` when the directory is
  absent (idempotent).

### 5. Documentation

Update the Woof LLD (tool inventory / library management) and the Whitebeard LLD
to document the new tools, the forget-vs-purge split, and the "never delete XMP
sidecars" invariant, and the `add_library` → `register_library` rename. Update
the tool list in `ouestcharlie-woof/README_DEV.md` (currently names
`add_library`). Do not enumerate individual implementation files.

---

## Verification

- `.venv/bin/pytest tests/ -v` in `ouestcharlie-woof` and `ouestcharlie-whitebeard`
  — new cases pass.
- Manual, in the MCP inspector:
  1. `register_library` a test folder, `index_library` it (creates
     `.ouestcharlie/`).
  2. `unregister_library` (no purge) → library gone from `list_libraries`;
     `.ouestcharlie/` and XMP sidecars still on disk; re-`register_library` works.
  3. Re-register, then `unregister_library(purge_metadata=True)` →
     `.ouestcharlie/` gone, **XMP sidecars and photos still present**;
     `metadataPurged=True`.

Out of scope: deleting photos or XMP sidecars; archiving/exporting metadata before
purge; UI affordance in the gallery.
