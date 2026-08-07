# OEC-30: HEIC EXIF extraction via pillow-heif

#status:done

## Context

pyexiv2's bundled `libexiv2.dylib` was not compiled with `libheif` support, so
`pyexiv2.Image()` raises `RuntimeError: Not a valid ICC Profile` on HEIC files
(observed during indexing of `kDrive/Images/2026/`). The fix is to detect HEIC/HEIF
files by extension and use `pillow-heif` + `Pillow` directly for those formats,
bypassing pyexiv2 entirely.

The existing EXIF parsing helpers (`_parse_exif_datetime`, `_parse_exif_gps`, etc.)
all expect a `dict` with pyexiv2-style key names (`Exif.Image.Make`, …). PIL's
`Image.getexif()` returns a `dict[int, Any]` keyed by numeric TIFF tag IDs. We bridge
the gap with a small mapping table covering the ~15 fields we actually consume.

---

## Changes

### 1. System prerequisite

**Confirmed: none.** `uv sync` with `pillow-heif>=0.18` on macOS pulled prebuilt
wheels (`pillow==12.3.0`, `pillow-heif==1.5.0`) with `libheif` statically
bundled — no `brew install libheif` or any system package was needed.
`pillow-heif` publishes wheels for macOS, Linux (manylinux), and Windows, all
with `libheif` bundled the same way.

**Documentation impact: none.** The Woof/Whitebeard/Wally READMEs' existing
"System prerequisites" sections (`macOS: brew install inih brotli gettext ...
/ Linux/Windows: no extra steps`) stay unchanged — this dependency adds no new
line to any of them. Do not add a `libheif` install step anywhere.

### 2. Add dependencies — `pyproject.toml`

```toml
dependencies = [
    ...
    "pillow-heif>=0.18",
    "Pillow>=11",
]
```

### 3. New helper `_read_heif_exif(path: Path) -> dict[str, str]` — `photo.py`

Add below the existing `_map_exif_extra` block. It:

1. Opens the file with `PIL.Image.open()` (pillow-heif registers a Pillow opener on
   import via `pillow_heif.register_heif_opener()`)
2. Calls `img.getexif()` and `img.getexif().get_ifd(0x8769)` (ExifIFD) to get
   numeric-keyed dicts
3. Maps tag IDs → pyexiv2-style key names via a local `_HEIF_TAG_MAP`:

```python
_HEIF_TAG_MAP: dict[int, str] = {
    270:   "Exif.Image.ImageDescription",
    271:   "Exif.Image.Make",
    272:   "Exif.Image.Model",
    274:   "Exif.Image.Orientation",
    256:   "Exif.Image.ImageWidth",
    257:   "Exif.Image.ImageLength",
    36867: "Exif.Photo.DateTimeOriginal",
    36868: "Exif.Photo.DateTimeDigitized",
    306:   "Exif.Image.DateTime",
    37521: "Exif.Photo.SubSecTimeOriginal",
    37520: "Exif.Photo.SubSecTime",
    36880: "Exif.Photo.OffsetTime",
    36881: "Exif.Photo.OffsetTimeOriginal",
    40962: "Exif.Photo.PixelXDimension",
    40963: "Exif.Photo.PixelYDimension",
    34855: "Exif.Photo.ISOSpeedRatings",
    33437: "Exif.Photo.FNumber",
    33434: "Exif.Photo.ExposureTime",
    37386: "Exif.Photo.FocalLength",
    41989: "Exif.Photo.FocalLengthIn35mmFilm",
    42036: "Exif.Photo.LensModel",
    40094: "Exif.Image.XPKeywords",
    40095: "Exif.Image.XPSubject",
}
```

**Note the tag IDs for the offset fields**: 36880 is `OffsetTime`, 36881 is
`OffsetTimeOriginal` (an earlier draft of this map had them swapped, which
would have made `_parse_exif_datetime`'s UTC-offset resolution read the wrong
field for HEIC files).

`ImageDescription`, `XPKeywords`, and `XPSubject` are required here even
though they're skipped by `_map_exif_extra` — `extract_exif()` (photo.py:309,
317, 319) reads them directly off `exif_data` to populate `description` and
keywords, so without these three entries HEIC photos would silently get no
description and no keywords in the sidecar.

GPS lives in its own IFD (`img.getexif().get_ifd(0x8825)`); map those tag IDs to
`Exif.GPSInfo.*` keys. PIL returns rational values as `IFDRational` objects — convert
to `"n/d"` strings to match the format `_parse_exif_gps` / `_rational_or_none` expect.

Returns `dict[str, str]` in the same format as `pyexiv2.read_exif()`.

**Dimensions come from the decoded image, not EXIF** (fix, 2026-08-07): many HEIC
files — including Apple's — carry no `PixelXDimension`/`ImageWidth` EXIF tags at all,
so relying on the tag map alone left `width`/`height` null in the sidecar.
`_read_heif_exif` now sets `Exif.Photo.PixelXDimension` / `PixelYDimension` from
`img.width` / `img.height` **after** the tag-map loop, so they always win: PIL returns
SHORT-type tags as raw bytes, so a present-but-mangled EXIF `PixelXDimension` would
otherwise overwrite the correct size with a non-numeric string (→ null again). This
was an EXIF-side gap only — the Rust `image-proc` binary reads HEIC dimensions
straight from libheif and was never affected.

**Dimensions account for orientation** (fix, 2026-08-07): pillow-heif renders HEIC
upright and **resets the EXIF orientation tag to 1**, exposing the file's real
orientation in `img.info["original_orientation"]`; libheif (image-proc) likewise
applies the HEIF rotation transform when decoding. So the sidecar's `orientation`
correctly stays 1, which means its `width`/`height` must be the *display* dimensions —
but `img.size` is the stored (pre-rotation) size. `_read_heif_exif` now swaps the axes
when `original_orientation` is a 90°/270° rotation (values 5–8). Note this is the
opposite convention from the JPEG/pyexiv2 path (which stores pre-rotation dims +
a non-1 orientation and lets `image-proc`'s `apply_orientation` rotate) — correct
because the HEIC decoders auto-orient while the JPEG decoder does not.

Before finalizing, diff this map's key set against every `exif_data.get("Exif...")`
call in `extract_exif()` and `_map_exif_extra`'s `_EXIF_EXTRA_SKIP` set to catch any
other field read directly (not just through the extras path) — that read/skip
distinction is what caused this gap.

### 4. Extend `extract_exif()` — `photo.py`

Dispatch on suffix before calling `pyexiv2.Image()`:

```python
HEIF_SUFFIXES = {".heic", ".heif", ".hif"}

local = await self.backend.local_path(self.path)
if Path(self.path).suffix.lower() in HEIF_SUFFIXES:
    exif_data = _read_heif_exif(local)
else:
    import pyexiv2
    pyexiv2.set_log_level(4)
    img = pyexiv2.Image(str(local))
    try:
        exif_data = img.read_exif()
    except UnicodeDecodeError:
        exif_data = img.read_exif(encoding="latin-1")
    img.close()
```

### 5. Tests — `tests/test_photo.py` (implemented)

Generates HEIC bytes in-memory per test via `pillow_heif.from_pillow()` +
`HeifFile.save(..., exif=...)` rather than a committed binary fixture — keeps
the exact tag values under test visible at the call site and avoids fixture
maintenance:
- `test_extract_exif_heic_returns_sidecar` — `sidecar` is an `XmpSidecar`,
  `camera_make`/`camera_model`/`date_taken` populated
- `test_extract_exif_heic_gps` — GPS lat/lon round-trip through the GPS IFD
- `test_extract_exif_heic_offset_time_not_swapped` — regression test for the
  36880/36881 `OffsetTime`/`OffsetTimeOriginal` tag-ID swap caught in review
- `test_extract_exif_heic_description_and_keywords` — regression test for the
  `ImageDescription`/`XPKeywords` tag-map gap caught in review
- `test_extract_exif_heic_dimensions_from_image_when_no_exif_tags` — regression
  test for the null width/height fix: a HEIC with no dimension EXIF tags still
  gets `width`/`height` from the decoded image size
- `test_extract_exif_heic_unrecognized_suffix_case_insensitive` — `.HEIC`
  dispatches the same as `.heic`

### 6. Documentation

- `ouestcharlie-py-toolkit/CLAUDE.md` — note the dual-reader strategy (HEIC/HEIF
  suffixes dispatch to `_read_heif_exif()`, everything else to pyexiv2) and
  that `_HEIF_TAG_MAP`/`_HEIF_GPS_TAG_MAP` must stay in sync with any EXIF
  field `extract_exif()` reads directly. **No system-prerequisite note** —
  confirmed `libheif` ships bundled in the `pillow-heif` wheel.
- `ouestcharlie-whitebeard/README.md`, `ouestcharlie-wally/README.md`, and
  `ouestcharlie-woof/README.md` — **unchanged.** Confirmed via `uv sync` that
  `pillow-heif`/`Pillow` install from prebuilt wheels with `libheif` bundled;
  the existing "System prerequisites" sections (`macOS: brew install inih
  brotli gettext ... / Linux/Windows: no extra steps`) already cover this
  correctly with no edit needed.
- `HLD.md` or installation guide — no change, same reason.

---

## Verification

1. ✅ `uv sync` in `ouestcharlie-py-toolkit` — installed `pillow==12.3.0` and
   `pillow-heif==1.5.0` from prebuilt wheels, no system `libheif` involved.
2. ✅ `.venv/bin/pytest tests/ -q` — 280 passed (34 in `test_photo.py`,
   including the 5 new HEIC tests).
3. ✅ `uvx ruff check` / `ruff format --check` — clean.
4. ✅ `.venv/bin/mypy src/ouestcharlie_toolkit/photo.py` — clean (added a
   `pillow_heif.*` override to `[[tool.mypy.overrides]]`, matching the
   existing `pyexiv2.*` one).
5. ☐ Re-run whitebeard indexing on `kDrive/Images/2026/2026-06-06+07_LaCoteDAime`
   — no `RuntimeError` errors; `20260606_155306.heic` appears in the index
   with correct `date_taken`, `camera_make`, `description`, and keywords
   (not just the fields that were already covered by the original tag map).
   Not yet run — needs the real kDrive mount.
