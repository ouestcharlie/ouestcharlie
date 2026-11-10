# OEC-71: Drop unused encoders (x265, aom encoder) from the image-proc wheels

#status:draft

Status flow: draft (write spec) -> open (review spec) -> todo (spec validated) -> ongoing (implementation started) -> done (merged)

## Context

image-proc only **decodes** HEIF files (HEIC and AVIF). It never encodes them: thumbnail
grids are encoded to AVIF by rav1e, a Rust crate built into image-proc. Yet the published
wheels carry libheif's **encoders** as well, because each platform's libheif comes with
them:

| Platform | Encoders shipped | How |
|---|---|---|
| macOS | x265 (`libx265.216.dylib`, 7.6 MB), aom encoder and its `libvmaf` (0.9 MB) | Homebrew's libheif links them; `delocate` bundles every linked library |
| Linux | x265, aom encoder | CI installs `libx265-dev` and `libaom-dev` before building libheif from source, so libheif links them; `auditwheel` bundles them |
| Windows | x265 | vcpkg's libheif enables x265 by default (`hevc` feature); linked statically into `image-proc.exe` |

Two problems:

1. **Licence.** x265 is GPL-2.0. image-proc is MIT. Distributing a wheel that contains
   GPL code linked to our binary puts the wheel as distributed under the GPL's terms
   (source offer, licence of the combined work), which conflicts with publishing the
   package as MIT. The decoders we actually need are not GPL: libde265 (HEIC) is
   LGPL-3.0, dav1d (AV1) is BSD-2-Clause, aom is BSD-2-Clause.
2. **Size.** About 8.5 MB of the macOS wheel (and similar on Linux) is code that never
   runs, next to an 11 MB binary.

Intended outcome: wheels contain only the decoders image-proc uses: libde265 for HEVC and
one AV1 decoder. HEIC and AVIF still decode on all three platforms.

---

## Analysis

**AV1 decoder choice: dav1d.** It is decode-only, faster than aom's decoder and smaller,
and it is already the choice on Windows (vcpkg's libheif needs it for AVIF, see the
69b changes). Using dav1d everywhere removes the aom encoder and libvmaf and gives the
three platforms the same decoder set.

**macOS is the costly part.** Homebrew's libheif bottle is built with x265 and aom and
cannot be configured. Options:

| Option | Verdict |
|---|---|
| Build libheif from source on macOS too, like Linux, cached on `LIBHEIF_VERSION` | **Recommended.** Same recipe as Linux, one more cached build step. Codec libraries (`libde265`, `dav1d`) still come from Homebrew. |
| Keep the Homebrew bottle and delete x265 from the wheel after `delocate` | Rejected: libheif still links x265, so the binary would fail to load. |
| `brew install --build-from-source libheif` with options | Rejected: Homebrew formulas no longer take build options. |

libheif's source build selects codecs with CMake options (`WITH_X265`, `WITH_AOM_ENCODER`,
`WITH_AOM_DECODER`, `WITH_DAV1D`, `WITH_LIBDE265`, …); check the exact names for the
pinned `LIBHEIF_VERSION` (1.19.7) before relying on them, and check the minimum dav1d
version it accepts against Ubuntu 22.04's `libdav1d-dev`.

**Related licence check (no change expected).** libheif and libde265 are LGPL-3.0. On
Windows they are linked statically into `image-proc.exe`. The LGPL allows this as long
as users can relink against a modified library; image-proc being open source and
buildable from source covers that. Note it in the LLD rather than change anything.

---

## Changes

### 1. Linux build (`ouestcharlie-imageproc/.github/workflows/_build.yml`)

- apt: replace `libx265-dev libaom-dev` with `libdav1d-dev`; keep `libde265-dev`.
- libheif CMake: disable x265 and aom (encoder and decoder), enable dav1d and libde265.
- Change the libheif cache key (it caches the old codec set).

### 2. macOS build

- Replace `brew install libheif` with: `brew install libde265 dav1d`, then the same
  cached libheif source build as Linux (own prefix, same CMake options), pointed to by
  `PKG_CONFIG_PATH` for `libheif-sys`.
- Keep `MACOSX_DEPLOYMENT_TARGET` for the source build so `delocate`'s minimum-macOS
  check still passes.

### 3. Windows build

- `vcpkg install "libheif[core,libde265,dav1d]:x64-windows-static-md"`: `core` turns off
  the default features, which include x265.
- Bonus: x265 is the slowest port in the vcpkg build, so the step should get faster.

### 4. Tests (`ouestcharlie-imageproc/tests_integration/test_binary_health.py`)

- macOS and Linux: assert no bundled library name contains `x265`, `aom` or `vmaf`.
- Windows: no bundled libraries to inspect; rely on the strings check in Verification,
  or read the binary for the x265 banner string in a test if it proves cheap.
- Existing HEIC and AVIF integration tests must keep passing on all three platforms
  (they cannot skip in CI).

### 5. Documentation

- `imageproc_LLD.md`, format table: libheif needs an HEVC decoder (libde265) and an AV1
  decoder (dav1d); no encoders. Short licence note: decoders only, no GPL code, LGPL
  libraries statically linked on Windows.
- Windows CI comment: the vcpkg feature set and why.

---

## Verification

- CI green on all three platforms, including the HEIC and AVIF integration tests.
- Wheel contents (`unzip -l`): no `libx265*`, `libaom*` or `libvmaf*` in the macOS and
  Linux wheels; `libdav1d*` and `libde265*` present instead.
- Windows: `strings image-proc.exe | grep "x265 (build"` finds nothing.
- Wheel sizes drop by roughly 8 MB on macOS and Linux; note before/after in the PR.
