# OEC-25: Switch XMP Sidecar Naming to Full-Name Convention (Darktable Compatibility)

#status:open

## Context

OuEstCharlie currently strips the photo extension before appending `.xmp`:
- `IMG_001.cr3` → `IMG_001.xmp`

This is incompatible with **Darktable** and **digiKam**, both of which use the full-name convention:
- `IMG_001.cr3` → `IMG_001.cr3.xmp`

The current approach also has a collision risk: `photo.cr3` and `photo.jpg` in the same folder both resolve to `photo.xmp`, silently overwriting each other's sidecar.

Darktable is the primary open-source Lightroom alternative (~12k GitHub stars, actively maintained, 2026 releases), and digiKam shares the same convention. Supporting this naming convention makes OuEstCharlie compatible with the open-source photography ecosystem.

---

## Changes

### 1. Core function — `xmp_path_for()`

**File:** `ouestcharlie-py-toolkit/src/ouestcharlie_toolkit/xmp.py` (lines 134–144)

Change `Path.with_suffix(".xmp")` (strips extension) to append `.xmp` to the full filename:

```python
# Before
p = Path(photo_path)
return p.with_suffix(".xmp").as_posix()

# After
p = Path(photo_path)
return (p.parent / (p.name + ".xmp")).as_posix()
```

### 2. Tests

**File:** `ouestcharlie-py-toolkit/tests/test_xmp.py` (lines 27–62)

Update all expected sidecar paths to include the photo extension:
- `"photo.xmp"` → `"photo.jpg.xmp"`
- `"2024/IMG_001.xmp"` → `"2024/IMG_001.jpg.xmp"`
- etc.

Add a new test: two photos with the same stem but different extensions (`photo.cr3`, `photo.jpg`) must produce distinct sidecar paths.

### 3. Schema version bump

**File:** `ouestcharlie-py-toolkit/src/ouestcharlie_toolkit/schema.py` line 16

Increment `SCHEMA_VERSION`: `3` → `4`.

This triggers the existing migration path in `whitebeard/indexer.py` (lines 336–350): on the next `index_library()` run, `force_full_index=True` causes all manifests, XMP sidecars, and thumbnails to be regenerated under the new naming convention.

### 4. Orphaned old-name sidecars

Bumping the schema and re-indexing regenerates content but does not clean up orphaned `photo.xmp` files that were replaced by `photo.jpg.xmp`. These should be surfaced as logged warnings during reindex (log each orphaned old-name sidecar found) but **not auto-deleted**, to avoid silently removing user data. A dedicated `clean_orphaned_sidecars()` utility can be provided separately.

### 5. Documentation

- **`ouestcharlie/HLD.md`**: Update folder structure example to show `IMG_001.jpg.xmp`
- **`ouestcharlie-py-toolkit/py_toolkit_LLD.md`**: Update XMP sidecar format section (lines 141–176), naming convention description and examples

---

## Verification

```bash
cd ouestcharlie-py-toolkit
.venv/bin/pytest tests/test_xmp.py -v
.venv/bin/pytest tests/ -v   # full suite to catch regressions
```

Manually confirm: place `photo.cr3` and `photo.jpg` in a test library, run indexing, verify two distinct sidecars (`photo.cr3.xmp`, `photo.jpg.xmp`) are created and that Darktable can open the CR3 sidecar.
