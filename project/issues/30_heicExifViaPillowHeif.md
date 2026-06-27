# OEC-30: HEIC EXIF extraction via pillow-heif

#status:todo

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

`libheif` must be installed system-wide:
- macOS: `brew install libheif`
- Debian/Ubuntu: `apt install libheif-dev`

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
    36880: "Exif.Photo.OffsetTimeOriginal",
    36881: "Exif.Photo.OffsetTime",
    40962: "Exif.Photo.PixelXDimension",
    40963: "Exif.Photo.PixelYDimension",
    34855: "Exif.Photo.ISOSpeedRatings",
    33437: "Exif.Photo.FNumber",
    33434: "Exif.Photo.ExposureTime",
    37386: "Exif.Photo.FocalLength",
    41989: "Exif.Photo.FocalLengthIn35mmFilm",
    42036: "Exif.Photo.LensModel",
}
```

GPS lives in its own IFD (`img.getexif().get_ifd(0x8825)`); map those tag IDs to
`Exif.GPSInfo.*` keys. PIL returns rational values as `IFDRational` objects — convert
to `"n/d"` strings to match the format `_parse_exif_gps` / `_rational_or_none` expect.

Returns `dict[str, str]` in the same format as `pyexiv2.read_exif()`.

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

### 5. Tests — `tests/test_photo.py`

- Add a minimal HEIC sample to `tests/sample-images/` (generated via
  `pillow_heif.from_pillow()` in a one-off script, committed as a binary fixture).
- `test_extract_exif_heic_returns_sidecar`: assert `sidecar` is an `XmpSidecar` and
  `camera_make` / `date_taken` are populated from the fixture.
- `test_read_heif_exif_gps`: unit-test `_read_heif_exif` on a HEIC with GPS tags.

### 6. Documentation

- `ouestcharlie-py-toolkit/CLAUDE.md` — note dual-reader strategy and system
  prerequisite (`brew install libheif` / `apt install libheif-dev`)
- `HLD.md` or installation guide — add `libheif` to system dependencies

---

## Verification

1. `brew install libheif`
2. `uv add pillow-heif Pillow` in `ouestcharlie-py-toolkit`
3. `.venv/bin/pytest tests/test_photo.py -v` — all tests pass including new HEIC ones
4. Re-run whitebeard indexing on `kDrive/Images/2026/2026-06-06+07_LaCoteDAime` —
   no `RuntimeError` errors; `20260606_155306.heic` appears in the index with correct
   `date_taken` and `camera_make`.
