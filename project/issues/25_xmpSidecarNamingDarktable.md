# OEC-25: Dual-Convention XMP Sidecar Naming (Darktable/digiKam Compatibility, Immich-Style Resolution)

#status:done

## Context

OuEstCharlie currently strips the photo extension before appending `.xmp`:
- `IMG_001.cr3` → `IMG_001.xmp`

This is incompatible with **Darktable** and **digiKam**, both of which use the full-name convention:
- `IMG_001.cr3` → `IMG_001.cr3.xmp`

The stripped-extension form is also a real, still-used convention (e.g. what Lightroom writes), not a "legacy" mistake to eliminate — so this isn't a hard rename, it's adding a second convention.

Immich handles exactly this by trying the full-name sidecar first and falling back to other conventions if absent (https://docs.immich.app/features/xmp-sidecars/). OuEstCharlie should do the same:

- **Reading**: prioritize the full-name sidecar (`IMG_001.cr3.xmp`); fall back to the stripped-extension form (`IMG_001.xmp`) if the full-name one isn't present. Existing libraries keep working with no migration step.
- **Writing**: only *newly created* sidecars (photos with no sidecar at all yet) use the new full-name convention. Sidecars that already exist — in either naming form — continue to be updated in place at whatever path they were found, so nothing silently forks a duplicate sidecar next to an existing one.

The current stripped-extension-only approach also has a collision risk: `photo.cr3` and `photo.jpg` in the same folder both resolve to `photo.xmp`, silently overwriting each other's sidecar. The full-name convention fixes this for all newly created sidecars.

Darktable is the primary open-source Lightroom alternative (~12k GitHub stars, actively maintained, 2026 releases), and digiKam shares the same convention. Supporting it makes OuEstCharlie compatible with the open-source photography ecosystem without breaking compatibility with tools that use the stripped-extension form.

This approach needs no `SCHEMA_VERSION` bump and no forced full reindex — nothing is being invalidated or regenerated, so there's nothing to migrate or orphan.

---

## Changes

### 1. Core function — `xmp_path_for()`

**File:** `ouestcharlie-py-toolkit/src/ouestcharlie_toolkit/xmp.py` (lines 134–144)

Give it an explicit `with_photo_extension` parameter instead of a single fixed behavior:

```python
def xmp_path_for(photo_path: str, *, with_photo_extension: bool) -> str:
    p = Path(photo_path)
    if with_photo_extension:
        return (p.parent / (p.name + ".xmp")).as_posix()
    return p.with_suffix(".xmp").as_posix()
```

Its only caller today is inside `xmp.py` itself, so no other file needs a signature-change update.

### 2. Read/write resolution in `XmpStore`

`Backend` already exposes `async def exists(path) -> bool`. Add a private resolver used by both `read()` and `write()`:

```python
async def _resolve_existing_xmp_path(self, photo_path: str) -> str | None:
    full_ext_path = xmp_path_for(photo_path, with_photo_extension=True)
    if await self.backend.exists(full_ext_path):
        return full_ext_path
    stripped_path = xmp_path_for(photo_path, with_photo_extension=False)
    if await self.backend.exists(stripped_path):
        return stripped_path
    return None
```

- `read()`: resolve via `_resolve_existing_xmp_path`; raise `FileNotFoundError` if neither path exists; read from whichever path matched.
- `write()`: resolve via the same helper, so it always targets the same path `read()` would have used for the current on-disk state (important since `write_conditional`'s `VersionToken` is only valid against the exact path it was read from). Falls back to `xmp_path_for(with_photo_extension=True)` only if neither path exists yet.
- `create()`: always uses `xmp_path_for(with_photo_extension=True)` — it's only reached when no sidecar exists in either form (`read_or_create_from_picture`'s "not found" branch), so brand-new extractions always get the Darktable/digiKam-compatible name.

`read_or_create_from_picture()` and `read_modify_write()` need no changes — they already compose `read()`/`write()`/`create()` and inherit this resolution behavior.

### 3. Tests

**File:** `ouestcharlie-py-toolkit/tests/test_xmp.py` (lines 27–62)

- Update the existing `xmp_path_for()` tests to call it with `with_photo_extension=True`/`False` and assert both conventions explicitly (`"photo.jpg" → "photo.jpg.xmp"` with the extension kept, `"photo.jpg" → "photo.xmp"` with it stripped).
- Invert the collision test: with `with_photo_extension=True`, `.JPG`/`.dng`/`.cr2`/`.nef` must produce **distinct** sidecar paths.
- Add `XmpStore`-level tests covering:
  - Read prioritizes the full-name sidecar when both conventions exist for the same photo.
  - Read falls back to the stripped-extension sidecar when only that one exists.
  - Modifying (`read_modify_write`) a photo whose sidecar exists only in stripped-extension form updates that file in place — no full-name sidecar is created alongside it. Use the existing `tests/sample-images/001.jpg` / `001.xmp` fixture pair (`001.xmp` is already versioned in the repo, stripped-extension form) rather than a synthetic one.
  - `read_or_create_from_picture()` on a photo with no sidecar at all creates one at the full-name path.
  - Two photos with the same stem, different extensions (`photo.cr3`, `photo.jpg`) get distinct, independently creatable sidecars.

### 4. Documentation

- **`ouestcharlie/HLD.md`**: Update folder structure example to show `IMG_001.jpg.xmp`, and note the read-priority/fallback behavior (not a hard rename).
- **`ouestcharlie-py-toolkit/py_toolkit_LLD.md`**: Update XMP sidecar format section (lines 141–176) to describe the dual-convention resolution and new-only write behavior.

---

## Verification

```bash
cd ouestcharlie-py-toolkit
.venv/bin/pytest tests/test_xmp.py -v
.venv/bin/pytest tests/ -v   # full suite to catch regressions
```

Manually confirm:
- Place `photo.cr3` and `photo.jpg` (same stem) in a test library, run indexing, verify two distinct new sidecars (`photo.cr3.xmp`, `photo.jpg.xmp`) are created and that Darktable can open the CR3 sidecar.
- Drop a stripped-extension sidecar (`old.xmp`) next to `old.jpg` with no full-name sidecar present, run indexing/read, and confirm it's read and updated in place rather than a second `old.jpg.xmp` being created alongside it.
