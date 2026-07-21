# OEC-34: Fall Back to EXIF `XPKeywords` When `dc:subject` Is Empty

#status:done

NOTE: other XP fields not processed (XPTitle/XPComment/XPSubject/XPAuthor)

## Context

`Exif.Image.XPKeywords` is a Windows-specific EXIF field (historically written by Windows Explorer/Photos, and read by some tools like digiKam) holding a semicolon-separated list of keywords, UTF-16LE encoded in the raw EXIF but decoded to a plain string by `pyexiv2`.

OuEstCharlie does not reference `XPKeywords` anywhere in `photo.py`, `xmp.py`, or `schema.py`. It falls through the generic `_map_exif_extra()` passthrough (`photo.py:139-160`) like any unrecognized EXIF field and is stashed as an opaque string in `_extra` — never split into a keyword list, never merged into `sidecar.tags`.

Practical impact: a photo library tagged only via Windows Explorer/Photos (no `dc:subject`/IPTC keywords, no Darktable/Lightroom XMP at all) will index into Woof with **no tags at all**, even though keyword data exists on disk in `XPKeywords`. This is a first-ingestion gap — `extract_exif()` (`photo.py:222`) builds the initial `XmpSidecar` and currently has no path from `XPKeywords` to `tags`.

---

## Changes

### 1. Extraction — `photo.py`

**File:** `ouestcharlie-py-toolkit/src/ouestcharlie_toolkit/photo.py`, in `extract_exif()` (~line 222) / near the tags-building logic (~lines 298-314)

Add a fallback: if no tags were already populated from other sources (`dc:subject`, IPTC keywords) **and** `Exif.Image.XPKeywords` is present and non-empty in the raw EXIF dict, split it on `;` into `tags`, trimming whitespace on each entry and dropping empties.

```python
if not tags and (xp_keywords := exif.get("Exif.Image.XPKeywords")):
    tags = [t.strip() for t in xp_keywords.split(";") if t.strip()]
```

This only applies at **first extraction** (no existing sidecar) — it must not override tags already present in an existing sidecar being re-read/updated, since `XPKeywords` fallback is a bootstrap for untagged photos, not an authoritative source that should fight with `dc:subject` edits made later via Woof or Darktable.

### 2. Scope check — where does this apply?

Confirm this only fires in `read_or_create_from_picture()`'s "create" branch (`xmp.py:346`, no sidecar exists yet) — i.e. it's the same code path OEC-25 identified as "brand-new extractions." No change needed to `read()`/`write()`/`XmpStore` merge logic, since this is purely about what `extract_exif()` seeds into a freshly created sidecar.

### 3. Tests

**File:** `ouestcharlie-py-toolkit/tests/test_photo.py` (or wherever `extract_exif()` is tested)

- Photo with `XPKeywords` set and no other keyword source → `tags` populated from the semicolon-split list, whitespace trimmed, empty segments dropped.
- Photo with both `dc:subject`-equivalent tags (e.g. IPTC keywords) and `XPKeywords` → existing tags win, `XPKeywords` ignored (no duplication or merge).
- Photo with no `XPKeywords` and no other tag source → `tags == []`, no error.
- Malformed/empty `XPKeywords` (e.g. `";;;"` or `""`) → yields empty `tags`, not a list of blank strings.

### 4. Documentation

**`ouestcharlie-py-toolkit/py_toolkit_LLD.md`**: note the `XPKeywords` fallback as a first-ingestion-only bootstrap behavior, distinct from the authoritative `dc:subject` tag source, so future readers don't mistake it for a bidirectional sync.

---

## Verification

```bash
cd ouestcharlie-py-toolkit
.venv/bin/pytest tests/test_photo.py -v
.venv/bin/pytest tests/ -v   # full suite to catch regressions
```

Manually confirm:
- Take a JPEG tagged only via Windows Explorer/Photos (`XPKeywords` set, no `dc:subject`), run indexing, verify the created sidecar's `tags` list matches the Windows keywords.
- Re-index the same photo after editing tags via Woof — confirm the `XPKeywords` fallback does not re-inject old Windows keywords over the new ones (fallback only applies on first creation, not on subsequent reads).
