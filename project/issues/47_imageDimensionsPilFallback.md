# OEC-47: Image width/height fallback via PIL when EXIF has no dimension tags

#status:done

## Context

`Photo.extract_exif()` derives `width`/`height` purely from EXIF dimension tags
(`Exif.Photo.PixelXDimension` / `Exif.Image.ImageWidth`, and the matching
Y/Length pair). When those tags are absent, both fields stay null even though the
pixel dimensions are always recoverable by decoding the image header.

This gap is real for non-HEIC files read through pyexiv2:

- Many JPEGs — scans, exports, screenshots, files stripped by re-encoders or social
  apps — carry no `PixelXDimension`/`ImageWidth` at all.
- PNG, WebP, TIFF, and other formats routinely have no EXIF dimension tags.

The consequence is null `width`/`height` in the sidecar and Lance index, which
breaks aspect-ratio layout in the gallery, orientation/portrait-landscape filters,
and any dimension-based statistics.

The two other media paths already avoid this by reading dimensions from the
decoded pixels rather than trusting metadata tags:

- **HEIC** (`_read_heif_exif`) opens the file with Pillow and sets
  `PixelXDimension`/`PixelYDimension` from `img.size`, overriding any EXIF value —
  see `photo.py` lines 279–285.
- **Video** (`video.py` `extract_metadata`) reads `width`/`height` from the decoded
  video stream's `codec_context`, swapping axes for a 90°/270° display rotation.

This issue brings the pyexiv2 image path in line: when EXIF yields no usable
dimensions, fall back to Pillow's `img.size`, applying the same orientation-aware
axis swap the HEIC and video paths already do.

---

## Changes

### 1. PIL dimension fallback in `extract_exif()`

**File:** `ouestcharlie-py-toolkit/src/ouestcharlie_toolkit/photo.py`
(`Photo.extract_exif()`, around the `width`/`height` derivation at lines 408–415)

After parsing `width`/`height` from EXIF, if either is `None` for a non-HEIC file,
open the image with Pillow and take `img.size`. Pillow is already a toolkit
dependency (used by the HEIC and video paths) and decodes JPEG/PNG/WebP/TIFF
header dimensions cheaply without loading full pixel data.

Orientation handling must follow the **stored-orientation convention** this path
uses (see [HLD § Orientation and stored dimensions](../../HLD.md#orientation-and-stored-dimensions)).
Unlike HEIC (upright convention: pillow-heif renders upright, resets orientation to
1, and stores display dimensions), the pyexiv2 path keeps the EXIF `Orientation`
value in the sidecar and stores the **pre-rotation** dimensions — EXIF
`PixelXDimension`/`ImageWidth` describe the stored buffer, not the display view. So
the PIL fallback must also return stored dimensions: use `img.size` directly,
**without** swapping axes, so that width/height agree with `orientation` exactly as
EXIF-provided values would. PIL's `img.size` returns the stored buffer size, so no
swap is the correct choice — do not apply `ImageOps.exif_transpose`.

```python
# After: width_s/height_s parsed from EXIF as today
width = _int_or_none(width_s)
height = _int_or_none(height_s)

# Fallback: EXIF carried no dimension tags (common for scans, PNG/WebP,
# re-encoded JPEGs). The decoded header always has the real pixel size.
# HEIC already fills these in _read_heif_exif; this covers the pyexiv2 path.
if (width is None or height is None) and Path(self.path).suffix.lower() not in _HEIF_SUFFIXES:
    from PIL import Image

    try:
        with Image.open(local) as pil_img:
            width, height = pil_img.size
    except (OSError, ValueError):
        # Unreadable/unsupported by PIL — leave as null, same as today.
        pass
```

Notes:
- Reuse the already-resolved `local` path from `extract_exif()` — do not re-download.
- Keep the fallback lazy-importing `PIL.Image` inside the function, matching the
  existing pattern in `_read_heif_exif` and `video.py`.
- Guard for formats PIL cannot open so extraction never fails harder than today
  (null dimensions) on an unsupported/corrupt file.

### 2. Tests

**File:** `ouestcharlie-py-toolkit/tests/test_photo.py`

Add cases:
- JPEG with EXIF dimension tags → width/height come from EXIF (unchanged behavior;
  fallback not triggered).
- JPEG **stripped of** `PixelXDimension`/`ImageWidth` (but a real image body) →
  width/height populated from PIL and equal to the actual pixel size.
- PNG (no EXIF at all) → width/height populated from PIL.
- Corrupt/zero-byte-body file where PIL cannot open → width/height stay null and no
  exception propagates.
- Regression: a rotated (Orientation 6/8) JPEG without dimension tags → assert
  `width`/`height` are the **stored** (pre-rotation) size and `orientation` is
  preserved, matching the stored-orientation convention (no axis swap).

### 3. Documentation

- No HLD/schema change — `width`/`height` fields already exist in `XmpSidecar`.
- Add a short comment at the fallback site explaining the orientation convention
  (why axes are/aren't swapped versus the HEIC path).

---

## Verification

- `.venv/bin/pytest tests/test_photo.py -v` — new dimension-fallback cases pass.
- Re-index a library containing PNGs and EXIF-stripped JPEGs; confirm sidecars and
  the Lance index now carry non-null `width`/`height` for files that previously had
  null dimensions.
- Spot-check the gallery: aspect-ratio layout and orientation filters work for the
  previously-nulled files.
