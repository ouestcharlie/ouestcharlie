# OEC-36: Fall Back to EXIF `ImageDescription` / `XPSubject` When `dc:description` Is Empty

#status:done

## Context

`Exif.Image.ImageDescription` (EXIF tag 0x010E) is the standard EXIF caption field, widely written by cameras and photo tools. `Exif.Image.XPSubject` (tag 0x9C9B) is its Windows Explorer/Photos-specific counterpart — a short "Subject" property, UTF-16LE encoded in the raw EXIF but decoded to a plain string by `pyexiv2`, same family as `XPKeywords`/`XPTitle`/`XPComment` (see OEC-34).

Neither field is referenced in `photo.py`. Both fall through the generic `_map_exif_extra()` passthrough (`photo.py:141-160`) and are stashed as opaque strings in `_extra` — never surfaced as `sidecar.description`.

Practical impact: a photo with only camera-written `ImageDescription` or only a Windows-tagged `XPSubject` (no `dc:description`, no AI-generated caption yet) indexes into Woof with **no description at all**, even though descriptive text exists on disk. Same first-ingestion gap as OEC-34, but for `description` instead of `tags`.

---

## Changes

### 1. Extraction — `photo.py`

**File:** `ouestcharlie-py-toolkit/src/ouestcharlie_toolkit/photo.py`, in `extract_exif()` (~line 222), near the tags-building logic (~lines 298-314) that OEC-34 added.

Add a fallback: if no `description` was already populated (from an existing sidecar or other source) **and** `Exif.Image.ImageDescription` is present and non-empty, use it. If `ImageDescription` is absent/empty, fall back to `Exif.Image.XPSubject`.

```python
if not description:
    description = (exif.get("Exif.Image.ImageDescription") or "").strip() or None
if not description:
    # XPSubject is UTF-16LE, null-terminated; pyexiv2 decodes the bytes but
    # leaves the trailing NUL, same as XPKeywords (see photo.py:306).
    description = (exif.get("Exif.Image.XPSubject") or "").rstrip("\x00").strip() or None
```

`ImageDescription` takes priority over `XPSubject` since it's the cross-platform standard field most tools write to; `XPSubject` is a Windows-only bootstrap for libraries that only ever went through Explorer/Photos.

This only applies at **first extraction** (no existing sidecar) — same scope restriction as OEC-34's `XPKeywords` fallback. It must not override a `description` already present in an existing sidecar (e.g. AI-generated caption, or a caption manually edited via Woof/Darktable).

### 2. Add both keys to `_EXIF_EXTRA_SKIP`

**File:** `photo.py:102-138`

```python
# Bootstrapped into description below
"Exif.Image.ImageDescription",
"Exif.Image.XPSubject",
```

Otherwise they'll leak into `_extra` in addition to being consumed (harmless duplication, but inconsistent with how `XPKeywords` was handled in OEC-34).

### 3. Scope check — where does this apply?

Confirm this only fires in `read_or_create_from_picture()`'s "create" branch (`xmp.py:346`, no sidecar exists yet), same as OEC-34. No change to `read()`/`write()`/`XmpStore` merge logic.

### 4. Tests

**File:** `ouestcharlie-py-toolkit/tests/test_photo.py`

- Photo with `ImageDescription` set, no `XPSubject`, no existing sidecar description → `description` populated from `ImageDescription`.
- Photo with both `ImageDescription` and `XPSubject` set → `ImageDescription` wins.
- Photo with only `XPSubject` set (no `ImageDescription`) → `description` populated from `XPSubject`.
- Photo with an existing sidecar `description` (e.g. AI caption) and EXIF `ImageDescription`/`XPSubject` also present → existing description wins, EXIF fields ignored (no overwrite).
- Photo with neither field set → `description is None`, no error.
- Empty/whitespace-only `ImageDescription`/`XPSubject` → treated as absent, no empty-string description.
- `XPSubject` with a trailing NUL (e.g. `"Beach day\x00"`) → NUL stripped, description is `"Beach day"`, not `"Beach day\x00"`.

### 5. Documentation

**`ouestcharlie-py-toolkit/py_toolkit_LLD.md`**: note the `ImageDescription`/`XPSubject` fallback as a first-ingestion-only bootstrap, same caveat as OEC-34's `XPKeywords` note — not a bidirectional sync with EXIF.

---

## Verification

```bash
cd ouestcharlie-py-toolkit
.venv/bin/pytest tests/test_photo.py -v
.venv/bin/pytest tests/ -v   # full suite to catch regressions
```

Manually confirm:
- Index a JPEG with only `ImageDescription` set (e.g. via `exiftool -ImageDescription="..."`) → sidecar `description` matches.
- Index a JPEG tagged only via Windows Explorer/Photos "Subject" field (`XPSubject` set, no `ImageDescription`) → sidecar `description` matches.
- Re-index after editing the description via Woof or generating an AI caption — confirm the EXIF fallback does not overwrite it on subsequent reads.
