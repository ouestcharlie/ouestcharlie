# OEC-29: Legacy Library Indexing Fixes

#status:done

## Context

Indexing a real-world photo library (`kDrive/Images`) surfaced several failures on old photos
(pre-2005 era) and edge cases in kDrive-mounted storage. This issue tracks the fixes applied
during the 2026-06-27 debugging session.

---

## Changes

### 1. EXIF encoding fallback for legacy cameras (`photo.py`)

**File:** `ouestcharlie-py-toolkit/src/ouestcharlie_toolkit/photo.py`

Pre-2005 cameras (and Windows software of that era) wrote EXIF string fields in latin-1 /
Windows-1252 rather than UTF-8. `pyexiv2.read_exif()` defaults to UTF-8 and raises
`UnicodeDecodeError` on those bytes.

Fix: catch `UnicodeDecodeError` and retry with `latin-1`, which is lossless for all byte values.

```python
# Before
exif_data: dict[str, str] = img.read_exif()

# After
try:
    exif_data: dict[str, str] = img.read_exif()
except UnicodeDecodeError:
    exif_data = img.read_exif(encoding="latin-1")
```

### 2. Suppress spurious debug traceback for zero-date sentinel (`photo.py`)

**File:** `ouestcharlie-py-toolkit/src/ouestcharlie_toolkit/photo.py`

Some cameras write `0000:00:00 00:00:00` in EXIF when their real-time clock was never set.
`_parse_exif_datetime()` already returned `None` via the `except ValueError` branch, but
`exc_info=True` caused a full traceback to appear in DEBUG logs for every such photo.

Fix: detect the sentinel before attempting the parse and return `None` directly.

```python
# Before (falls into except ValueError → logs traceback at DEBUG)
try:
    iso = date_str.strip().replace(":", "-", 2)...
    return datetime.fromisoformat(iso)
except ValueError:
    _log.debug("Could not parse EXIF datetime %r", date_str, exc_info=True)
    return None

# After
if date_str.strip() == "0000:00:00 00:00:00":
    return None
try:
    ...
```

### 3. Known upstream bug: pyexiv2 UCS-2 decode crash (deferred)

**Affected photos:** Windows-tagged JPEGs with multi-valued `Exif.Image.XPAuthor` or
`Exif.Image.XPKeywords` fields (e.g. tagged in Windows Explorer).

**Error:** `AttributeError: 'list' object has no attribute 'split'` inside
`pyexiv2/convert.py:decode_ucs2()`. pyexiv2 2.15.5 is the latest release; no fix is available.

**Current behavior:** whitebeard's indexer catches the exception and logs it at `ERROR` level,
skipping the photo. No action taken until pyexiv2 ships a fix.

---

## Verification

- Re-run indexing on `kDrive/Images/2002/` partitions — no `UnicodeDecodeError` should appear.
- Spot-check that camera make/model fields are populated correctly on affected photos.
