# Plan: JPEG SOF fallback for width/height when EXIF is absent

#status:open

## Context

WhatsApp re-encodes photos as bare JFIF JPEGs, stripping all metadata segments before sending. `pyexiv2` finds no EXIF, XMP, or IPTC data in these files, so `width` and `height` are `null` in the LanceDB index. The JPEG SOF (Start of Frame) segment is always present in a valid JPEG and contains pixel dimensions — this is the correct binary fallback, requires no new dependencies, and applies to any JPEG without EXIF dimension tags.

No other useful metadata can be recovered: `date_taken`, orientation, make/model, and GPS are simply absent from the file. WhatsApp always re-encodes to the correct visual orientation, so the absence of an orientation tag is correct (defaults to 1 = upright).

---

## Implementation

**Single file:** `ouestcharlie-py-toolkit/src/ouestcharlie_toolkit/photo.py`

### 1 — Add `struct` to imports

```python
import struct
```

### 2 — Add `_read_jpeg_dimensions` helper (alongside other EXIF helpers)

Scans JPEG segments sequentially until a SOF marker is found, then reads height and width from it. Returns `None` on any parse or I/O failure.

```python
def _read_jpeg_dimensions(path: Path) -> tuple[int, int] | None:
    try:
        with open(path, "rb") as f:
            if f.read(2) != b"\xff\xd8":
                return None
            while True:
                marker = f.read(2)
                if len(marker) < 2 or marker[0] != 0xFF:
                    return None
                seg = marker[1]
                if seg in (0xD8, 0xD9):          # SOI / EOI — no length field
                    continue
                length_bytes = f.read(2)
                if len(length_bytes) < 2:
                    return None
                length = struct.unpack(">H", length_bytes)[0]
                # SOF markers: C0–C3, C5–C7, C9–CB, CD–CF (exclude C4 DHT, C8, CC)
                if 0xC0 <= seg <= 0xCF and seg not in (0xC4, 0xC8, 0xCC):
                    if length < 7:
                        return None
                    f.read(1)                      # precision byte
                    h, w = struct.unpack(">HH", f.read(4))
                    return w, h
                f.seek(length - 2, 1)
    except OSError:
        return None
```

### 3 — Call as fallback in `extract_exif()`

After the EXIF-based `width`/`height` extraction and before building `XmpSidecar`, add:

```python
        if (width is None or height is None) and local is not None:
            dims = _read_jpeg_dimensions(local)
            if dims:
                w, h = dims
                if width is None:
                    width = w
                if height is None:
                    height = h
```

`local` is the `Path` returned by `backend.local_path()` already in scope at that point.

---

## Verification

```python
# Smoke test in the whitebeard venv:
from ouestcharlie_toolkit.photo import _read_jpeg_dimensions
from pathlib import Path
dims = _read_jpeg_dimensions(Path("test-perso/2026/2026-03-27+28+29_Queyras/Ivan/IMG-20260329-WA0003.jpg"))
assert dims is not None
print(dims)  # expect (width, height) integers
```

Then force-index the partition (or delete the existing XMP sidecars and re-index) and confirm `width`/`height` are populated in the LanceDB rows.
