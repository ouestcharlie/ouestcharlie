# OEC-69: Image format coverage (RAW and standard formats), benchmarked on RapidRAW

#status:done

Status flow: draft (write spec) -> open (review spec) -> todo (spec validated) -> ongoing (implementation started) -> done (merged)

Reference: [RapidRAW supported file formats](https://www.getrapidraw.com/docs/file-formats).

## Context

RapidRAW is an open-source RAW editor that people may use alongside Woof. Its format list is
a useful benchmark: users who shoot RAW expect the files their editor opens to also show in
their photo library. It also matters for interop, because RapidRAW exports TIFF, WebP,
JPEG XL and AVIF files that land back in the library.

RapidRAW decodes RAW through **dnglab** (`rawler` crate). image-proc already depends on the
same crate (`rawler = "=0.7.2"`, `raw` feature), so the camera coverage gap is not a library
choice: we only need to wire it up.

This issue records what each layer supports today, what is missing, and how to test each
format. It is a tracking issue; the larger items should get their own sub-issues (69a, 69b…).

Intended outcome: every format in the "In scope" list is indexed, has correct EXIF fields,
shows a thumbnail and a preview in the gallery, and is covered by a test.

---

## Current state

A photo goes through three layers. A format works only if all three accept it.

| Layer | Where | What decides support |
|---|---|---|
| Discovery | `ouestcharlie-whitebeard/src/whitebeard/indexer.py` `PHOTO_EXTENSIONS` | Which files are indexed |
| EXIF | `ouestcharlie-py-toolkit/src/ouestcharlie_toolkit/photo.py` | pyexiv2 (libexiv2), except `.heic/.heif/.hif` read via pillow-heif |
| Pixels | `ouestcharlie-imageproc/image-proc/src/main.rs` `decode_photo()` | RAW list → `decode_raw`, `.heic/.heif` → libheif, rest → `image` crate (`jpeg`, `png`, `webp`, `tiff` features) |

Release wheels are built with `IMAGE_PROC_FEATURE_RAW=1` and `IMAGE_PROC_FEATURE_HEIC=1`
(`.github/workflows/_build.yml`).

### Matrix today

| Format | Indexed | EXIF | Thumbnail / preview | Status |
|---|---|---|---|---|
| JPEG `.jpg .jpeg` | yes | yes | yes | ✅ done |
| HEIC/HEIF `.heic .heif` | yes | yes (pillow-heif) | yes (libheif) | ✅ done (OEC-30, OEC-30a) |
| HEIF `.hif` (Canon/Sony HEIF) | **no** | yes | **no** (not in decoder match) | ⚠️ inconsistent |
| PNG `.png` | yes | yes (eXIf chunk, rare) | yes | ✅ done |
| TIFF `.tif .tiff` | **no** | yes | yes (decoder ready) | ⚠️ one-line gap |
| WebP `.webp` | **no** | yes | yes (decoder ready) | ⚠️ one-line gap |
| DNG, CR2, CR3, NEF, ARW, RAF, ORF, RW2 | yes | to verify per format (CR3 needs BMFF in libexiv2) | **no: `decode_raw` is a stub** returning "RAW decode not yet implemented" | ❌ broken |
| PEF | **no** | to verify | **no** (stub) | ❌ |
| JPEG XL `.jxl` | no | to verify (BMFF) | no | ❌ missing |
| AVIF `.avif` | no | to verify (BMFF) | no (we encode AVIF, but do not decode it) | ❌ missing |

The most visible bug: RAW files are indexed today, but `decode_raw` always fails, so they show
no thumbnail or preview. That is fixed first, before adding any new extensions.

---

## Gap versus RapidRAW

### RAW extensions RapidRAW opens (all via dnglab/rawler)

| Brand | RapidRAW | Woof today | Missing |
|---|---|---|---|
| Adobe / DJI / Leica / Ricoh | `.dng` | `.dng` | — |
| Apple ProRAW | `.pro` (as listed by RapidRAW; ProRAW files are usually `.dng`) | — | `.pro` (to confirm) |
| ARRI | `.ari` | — | `.ari` (low priority, cinema) |
| Canon | `.crw .cr2 .cr3` | `.cr2 .cr3` | `.crw` |
| Casio | `.bay` | — | `.bay` |
| Contax / Panasonic | `.raw` | — | `.raw` (ambiguous extension, see below) |
| Epson | `.erf` | — | `.erf` |
| Fujifilm | `.raf` | `.raf` | — |
| Hasselblad | `.3fr .fff` | — | `.3fr .fff` |
| Phase One / Imacon | `.iiq` | — | `.iiq` |
| Kodak | `.kdc .k25 .dcs .dcr` | — | all four |
| Leaf | `.mos` | — | `.mos` |
| Leica | `.rwl` | — | `.rwl` |
| Mamiya | `.mef` | — | `.mef` |
| Minolta | `.mrw` | — | `.mrw` |
| Nikon | `.nef .nrw` | `.nef` | `.nrw` |
| Olympus / OM System | `.orf` | `.orf` | — |
| Panasonic | `.rw2` | `.rw2` | — |
| Pentax | `.pef .ptx` | (`.pef` decoder only) | `.pef .ptx` |
| Samsung | `.srw` | — | `.srw` |
| Sigma | `.x3f` | — | `.x3f` |
| Sony | `.arw .srf .sr2` | `.arw` | `.srf .sr2` |

Since rawler handles all of these, adding them is mostly a list change once `decode_raw`
works. The real cost is testing and EXIF coverage in libexiv2 (X3F, IIQ, ARI are weak there).

`.raw` is risky: other tools use it for unrelated data. Index it only if rawler identifies
the file; skip it silently otherwise.

### Standard formats RapidRAW opens

| Group | Formats | Proposal |
|---|---|---|
| Common | JPEG, PNG, GIF, BMP, TIFF, WebP, JPEG XL | Add all of them: Woof users are not only photographers, and screenshots, scans and old camera files are often GIF or BMP. |
| HDR | EXR, HDR | Out of scope for now (needs tone mapping for a thumbnail). |
| Graphics / icons | TGA, ICO, DDS | Out of scope (not photos). |
| Specialist / Netpbm | QOI, farbfeld, PNM/PBM/PGM/PPM/PAM | Out of scope. |

RapidRAW **exports** JPEG, PNG, TIFF, WebP, JPEG XL and AVIF. Woof should read all six, so an
edited export shows in the library. AVIF is not on RapidRAW's input list, but it is one of its
outputs, so it is in scope here.

### Sidecars and metadata

| RapidRAW | Relevance to Woof |
|---|---|
| `.rrdata` (JSON edit data, per photo and per virtual copy) | Not media: must never be indexed. Add a test that it is ignored. Reading edits is out of scope. |
| `.rrexif` (original EXIF kept when Denoise, Stitch, HDR Merge or Negative Convert writes a new pixel file) | Those new files may have no capture date. Follow-up: read `.rrexif` as an EXIF fallback (same family as OEC-63, darktable sidecars). |
| XMP sync of rating, colour label, tags (Lightroom compatible, "Create XMP if missing" option) | Check that Woof reads RapidRAW-written XMP and that RapidRAW reads Woof's. Fold into OEC-63's interop tests. |
| Export "Preserve timestamps" off by default | Exports get a new file time. Confirms Woof must take dates from EXIF, not file time. |

---

## Changes

Package chain: `ouestcharlie-imageproc` → `ouestcharlie-py-toolkit` (pins `ouestcharlie-imageproc~=3.0`)
→ `ouestcharlie-whitebeard` (indexing) and `ouestcharlie-wally` (search, serves previews through
`generate_preview_jpeg`) → `ouestcharlie-woof` (MCP server, gallery, skills). A fix in image-proc
reaches users only after a release of each package down the chain. The gallery has no
format-specific code, so no change is needed there.

| Sub-issue | imageproc | py-toolkit | whitebeard | wally | woof | ouestcharlie (docs) |
|---|---|---|---|---|---|---|
| 69a RAW decoding | code (done) | pin + tests (done) | release | release | release | LLD |
| 69b Standard formats + shared list | code + build (done) | code (done) | code (done) | release | skill scripts (done) | HLD (done) |
| 69c Extra RAW extensions | code (done) | list + EXIF tests (done) | test (done) | — | skill scripts (done) | HLD, user docs (done) |

### 1. Implement RAW decoding in image-proc (69a)

**Version:** image-proc moves to **3.0.0** (major bump, `protocol_version` 3). The Rust crate,
the Python package and `IMAGE_PROC_PROTOCOL_MAJOR_VERSION` change together, so a toolkit still
pinned to 2.x gets a clear "unsupported protocol version" error instead of silently failing
on RAW files. py-toolkit moves its pin to `ouestcharlie-imageproc~=3.0`, which can only be
locked once 3.0.0 is published. Until then, develop against the local checkout (the
commented-out `[tool.uv.sources]` path in py-toolkit's `pyproject.toml`).

**Impacted:**
- `ouestcharlie-imageproc`: RAW decoder in the `image-proc` crate (embedded JPEG first,
  develop + auto exposure as fallback), Rust tests on a small committed CC0 DNG, opt-in
  raw.pixls.us download test, LLD section on RAW decoding. CI integration tests now also
  get `IMAGE_PROC_FEATURE_RAW`, so RAW tests fail instead of skipping in CI (release wheels
  already enabled RAW). The crate was also split from a single file into a library (protocol,
  commands, decoders, transforms) with a thin binary. Release 3.0.0.
- `ouestcharlie-py-toolkit`: move the pin to `~=3.0`; add RAW cases to
  `test_thumbnail_builder.py` and `test_preview_builder.py`; check RAW EXIF in `test_photo.py`
  (CR3 in particular). No change expected in `photo.py` unless pyexiv2 fails on CR3.
- `ouestcharlie-whitebeard`, `ouestcharlie-wally`: no code change, release with the new toolkit.
- `ouestcharlie-woof`: no code change, release with the new dependencies.

Two options, both with rawler 0.7.2:

1. **Embedded preview (recommended first):** extract the largest embedded JPEG preview and
   decode it with the `image` crate. Fast, and colours match the camera's own rendering.
   Good enough for 256 px tiles and a 1600 px preview on most bodies.
2. **Full develop:** demosaic and apply a basic colour pipeline. Slower and colours will
   differ from the camera JPEG, but works when the preview is missing or tiny (some DNGs,
   older bodies).

Use 1, fall back to 2 when the preview is missing or smaller than the requested long edge.
Check orientation: embedded previews are usually not rotated, so the EXIF orientation must
still apply, but some bodies store rotated previews.

### 2. Align the extension lists (part of 69b)

**Files:** `whitebeard/indexer.py` `PHOTO_EXTENSIONS`, `image-proc/src/main.rs` `decode_photo()`,
`py-toolkit/photo.py` `_HEIF_SUFFIXES`, and the copies in
`ouestcharlie-woof/plugins/woof-photo-workflows/skills/*/scripts/{sort_photos,verify_sort,tag_files}.py`.

- Today each layer has its own list and they disagree (`.hif`, `.pef`, `.tif`, `.webp`).
- Define the photo list once in the toolkit (next to `VIDEO_SUFFIXES`) and import it in
  Whitebeard. The skill scripts run standalone, so keep their copy, but add a test that
  compares it to the toolkit list.
- Pass the list (or a `raw` / `standard` split) to image-proc in the request, or keep the
  Rust match in sync with a test.

### 3. Add standard formats (69b)

- TIFF, WebP: add to the index list (decoders exist). Check multi-page TIFF (first page)
  and 16-bit TIFF (downscale to 8-bit).
- JPEG XL: `jxl-oxide` crate (pure Rust) behind a feature.
- AVIF: decode via `image` crate `avif-native` (dav1d, system dependency) or libheif, which
  is already linked for HEIC and can decode AVIF. libheif is the cheaper option.
- Check pyexiv2 reads EXIF from JXL and AVIF (both need BMFF support in libexiv2). If not,
  read it the same way as HEIF.

**Impacted (sections 2 and 3):**
- `ouestcharlie-imageproc` (done, ships in 3.0.0 with 69a):
  - `.hif` and AVIF decode through libheif; JPEG XL through jxl-oxide, built in by default
    rather than behind a feature (pure Rust, no system dependency, so a feature would only
    add CI wiring). Windows CI adds dav1d to vcpkg's libheif, which has no AV1 decoder by
    default; macOS and Linux libheif already use aom.
  - TIFF: 16-bit, CMYK, LZW/deflate/JPEG compression and multi-page (first page) work out
    of the box; WebP lossless and animated (first frame) too. GIF (first frame) and BMP
    enabled in the `image` crate. 32-bit float TIFF is not
    supported by the `image` crate: known gap.
  - image-proc ignores the request orientation for HEIC, AVIF and JPEG XL, whose decoders
    already return upright pixels.
  - `image-proc --formats` and the Python `supported_extensions()` list the extensions the
    build decodes, for the shared list below.
  - Small committed fixtures for each format, with the script that regenerates them.
- `ouestcharlie-py-toolkit`: new shared photo suffix constant next to `VIDEO_SUFFIXES`, exported
  from `__init__.py`, with a test that it is a subset of `supported_extensions()`; EXIF
  fallback for JXL/AVIF in `photo.py` if pyexiv2 cannot read them. AVIF and JPEG XL follow
  the HLD upright convention like HEIC: store orientation 1 and display dimensions (update
  the HLD "Orientation and stored dimensions" list). Fixtures in `test_photo.py`,
  `test_thumbnail_builder.py`, `test_preview_builder.py` (image-proc's
  `tests/sample-images` set can be reused); bump the imageproc pin.
- `ouestcharlie-whitebeard`: `indexer.py` imports the shared list instead of `PHOTO_EXTENSIONS`;
  test that each new extension is indexed and `.rrdata` / `.rrexif` / `.rrpreset` are ignored.
- `ouestcharlie-wally`: no code change, release with the new toolkit.
- `ouestcharlie-woof`: extension lists in
  `plugins/woof-photo-workflows/skills/*/scripts/{sort_photos,verify_sort,tag_files}.py`
  (both skills), plus a test that compares them to the toolkit list; release.

### 4. Add RAW extensions (69c)

Add the missing RAW extensions in priority order:

1. Current bodies: `.nrw .srw .pef .rwl .iiq .3fr .fff .crw .srf .sr2`
2. Legacy: `.mrw .erf .kdc .k25 .dcs .dcr .mos .mef .bay .x3f`
3. Special cases: `.raw` (only if rawler identifies it), `.ari`, `.pro` (confirm first)

**Outcome of testing** (one CC0 raw.pixls.us sample per extension, extra camera models
where a first sample failed):

| Result | Extensions |
|---|---|
| Added | `.crw .nrw .srf .sr2 .rwl .srw .erf .3fr .fff .iiq .mos` (`.pef` was already decoded, now listed) |
| Set aside: decoder problem | `.mrw` (rawler knows 1 of 4 Minolta models tested), `.x3f` (rawler cannot read the file layout), `.kdc` `.dcr` (decode with strong colour casts) |
| Set aside: out of scope | `.ari` (ARRI cinema frames, log-encoded) |
| Set aside: untested | `.k25 .dcs .mef .bay` (no CC0 sample available) |
| Set aside: ambiguous | `.raw` (also used by unrelated software), `.pro` (unclear format; ProRAW is `.dng`) |

Support is also per camera model: rawler fails with "Unknown camera" on models missing
from its list, even in an added format (Leica D-Lux 6 RWL, Phase One P40+ IIQ). Revisit
the set-aside formats and these models when upgrading rawler. Details and per-format
decode paths are in `imageproc_LLD.md` ("RAW decoding").

**Impacted:**
- `ouestcharlie-imageproc` (done, ships in 3.0.0 with 69a and 69b): extension list,
  samples added to the opt-in raw.pixls.us test (21 cameras, ~500 MB), LLD.
- `ouestcharlie-py-toolkit`: add the extensions to the shared list (or derive it from
  `supported_extensions()`); EXIF test per extension, noting the ones libexiv2 reads
  poorly (IIQ). Medium-format IIQ and MOS files are stored rotated, so their thumbnails
  rely on the EXIF orientation being read correctly. Bump the imageproc pin.
- `ouestcharlie-whitebeard`: no code change once the list is shared; extend the indexing test.
- `ouestcharlie-wally`: none.
- `ouestcharlie-woof`: skill script extension lists; release.

### Downstream packages: outcome

Done on the `feature/oec-69_improveImageSupport` branches, not released yet. Version bumps
(py-toolkit 0.17.0, then Whitebeard's `ouestcharlie-py-toolkit>=0.17.0` floor and the Woof
dependencies) are left for the release.

- `ouestcharlie-py-toolkit`: pin `ouestcharlie-imageproc~=3.0` (3.0.1 is on PyPI).
  `PHOTO_SUFFIXES` in `photo.py`, exported, with a test that it is a subset of
  `supported_extensions()`. EXIF findings:
  - pyexiv2 reads EXIF from AVIF and from JPEG XL in its ISO BMFF container, so no
    pillow-heif-style fallback is needed. It cannot open a bare JXL codestream (cjxl's
    default output): such files have no EXIF, and are now indexed without it instead of
    failing.
  - AVIF and JPEG XL follow the upright convention: orientation 1, display dimensions.
    AVIF size and rotation come from Pillow (which reports the `irot`/`imir` boxes as the
    orientation, like libheif applies them); JPEG XL size and orientation come from the
    codestream header, parsed in `photo.py` since Pillow cannot open JXL. An EXIF
    orientation in these files is ignored, as their decoders do.
  - RAW dimensions were wrong for most formats: the EXIF dimension tags often describe an
    embedded preview (NEF 160x120, RAF 1920x1280, iPhone DNG 852x640) or are missing (RW2,
    RWL, NRW). RAW files now use libexiv2's main-image size (`get_pixel_width`), or the DNG
    `DefaultCropSize` when present. Checked on the 21 raw.pixls.us samples. Known gaps:
    - CR3 and IIQ report the preview size (aspect right, smaller numbers).
    - Some sizes include sensor borders, so the aspect is a little off: RWL ~3%, SRF and
      SR2 ~2%.
    - Leaf MOS: pyexiv2 reads no make, model, date or orientation. Make and model are only
      in embedded XMP, and the rotation (`RotationAngle` 90) is in Leaf's own metadata
      block, so the tested Aptus 22 file shows rotated 90° in the gallery. Fixing it needs a
      Leaf-specific reader (or rotation from rawler in image-proc); to decide whether MOS
      stays in the list.
  - Tests: one sample per format family (JPEG, PNG, TIFF, WebP, GIF, BMP, AVIF generated
    with Pillow; JXL and a Sigma fp DNG committed under `tests/sample-images/formats/`),
    checked for EXIF, dimensions, and an upright preview and thumbnail through the real
    image-proc binary. The full raw.pixls.us set was checked by hand (not in CI).
- `ouestcharlie-whitebeard`: `indexer.py` uses `PHOTO_SUFFIXES`. Tests: every shared
  extension is discovered, RapidRAW `.rrdata` / `.rrexif` / `.rrpreset` files are ignored,
  standard formats are indexed with thumbnails, a corrupt file is one error.
- `ouestcharlie-wally`: no change.
- `ouestcharlie-woof`: one media list per skill (`scripts/media_ext.py`, imported by the
  scripts), identical in both skills and checked against the toolkit by tests; `verify_sort.py`
  now recognises current-style sidecars (`photo.ext.xmp`) for every media extension, not
  only jpg/jpeg/heic/mp4/mov. README: supported formats section.
- `ouestcharlie` HLD: "Supported photo formats" section; AVIF and JPEG XL added to the
  upright convention.

### 5. Documentation

Repositories: `ouestcharlie` (HLD, LLDs), `ouestcharlie-imageproc` (`imageproc_LLD.md`),
`ouestcharlie-woof` (README).

- HLD / Whitebeard LLD: supported format list, one place.
- `imageproc_LLD.md`: RAW decode strategy (preview first, develop as fallback).
- User docs (Woof README or blog): list of supported formats, and how to request one.

---

## Verification

### Test fixtures

- **Standard formats:** generate small files in tests with Pillow (JPEG, PNG, TIFF 8 and 16
  bit, multi-page TIFF, WebP, AVIF, JXL), with known EXIF (date, camera, orientation 6).
  No binary files needed in the repo.
- **RAW:** use [raw.pixls.us](https://raw.pixls.us), the sample archive dnglab itself tests
  against. Files are CC0, which also fits RapidRAW's rule for sample sets. They are several MB
  each, so do not commit them: an integration test downloads one file per extension, checks a
  pinned SHA-256, caches it, and is skipped when offline. One or two small DNGs can be
  committed as unit fixtures.
- Include for each RAW family: a portrait-oriented shot (orientation), and where possible a
  file with no or a tiny embedded preview (fallback path).

### Per-format checks

For each in-scope format:

1. **Indexed:** the file appears in the partition manifest after `index_library`.
2. **EXIF:** capture date, camera make/model, lens, orientation, dimensions are filled
   (`get_summary` / search filters such as camera model).
3. **Thumbnail:** the tile in the AVIF grid is not blank and is upright.
4. **Preview:** `jpeg_preview` returns the expected long edge and correct orientation.
5. **Gallery:** the photo shows in `browse_gallery`, and the full view opens.
6. **Errors:** a truncated or corrupt file produces one indexing error entry, not a crash
   of the partition.

### Test layers

| Layer | Test |
|---|---|
| image-proc (Rust) | `decode_photo` per extension returns the expected size; `cargo test --release --features raw,heic` |
| py-toolkit | `test_photo.py`: EXIF per format; `test_thumbnail_builder.py`, `test_preview_builder.py`: one case per format family |
| Whitebeard | indexer picks up each extension, ignores `.rrdata` / `.rrexif` / `.rrpreset` |
| Integration (`tests_integration`) | raw.pixls.us set, one file per RAW extension, run in CI on a schedule |
| Manual | index a folder with one file per format, open it in the gallery on Claude Desktop |

### Interop check with RapidRAW (manual)

1. Open a RAW in RapidRAW, set a rating, colour label and tags with XMP sync on.
2. Export it as JPEG, TIFF, WebP, JPEG XL and AVIF into the library.
3. Re-index: the RAW shows its rating and tags; each export shows, with the capture date
   from EXIF (not the export time).
4. Tag a photo in Woof, open it in RapidRAW: the tags show.
