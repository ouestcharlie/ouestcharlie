# OEC-30a: HEIC pixel decoding shipped by default in image-proc wheels

#status:done

## Context

[OEC-30](30_heicExifViaPillowHeif.md) fixed HEIC **EXIF metadata** reading on the
Python side (pillow-heif, bundled wheels, no system `libheif` needed). It did not
touch **pixel decoding** — the Rust `image-proc` binary (thumbnail grid assembly +
preview generation) still cannot actually decode HEIC files:

- `decode_heic()` in `image-proc/src/main.rs:360-368` is an unimplemented stub —
  `Err("HEIC decode not yet implemented (--features heic stub)")` — regardless of
  whether the `heic` Cargo feature is compiled in.
- CI (`.github/workflows/_build.yml:55-57`) only sets `IMAGE_PROC_FEATURE_RAW=1` when
  building wheels — `IMAGE_PROC_FEATURE_HEIC` is never set, so **published wheels
  never include HEIC support today**, and even if they did, decoding would still fail.

This means Woof/Whitebeard cannot generate thumbnails or previews for HEIC photos at
all — EXIF is read correctly (OEC-30), but the pixels can't be processed. This issue
closes that gap: implement real HEIC decoding and ship it in published wheels by
default, without reintroducing the "every user needs `brew install libheif`" problem
that OEC-30 specifically eliminated on the EXIF side.

**Decisions made during review**:
- Implement real decoding via `libheif-rs`, not just a config/docs change.
- Ship it self-contained: bundle `libheif`'s shared library into the wheel at build
  time (mirroring what `pillow-heif`'s own wheels already do), so end users need
  nothing extra at runtime — CI needs `libheif` only at *build* time.
- **Mirror RAW's existing pattern exactly, do not introduce a new mechanism**: the
  `heic` Cargo feature stays opt-in (no `[features] default`, so a bare `cargo build`
  still excludes it, same as `raw` today). What changes is CI — add
  `IMAGE_PROC_FEATURE_HEIC: "1"` next to the existing `IMAGE_PROC_FEATURE_RAW: "1"` in
  the wheel-build step, so **published wheels include HEIC by default**. Disabling it
  for a given build is already possible today the same way RAW is: don't set the env
  var. No new opt-out flag needed.
- Applies on all three platforms (macOS, Linux, Windows), accepting that the Windows
  CI step (via vcpkg) is slower/less proven than Homebrew/apt and may need follow-up
  hardening.

---

## Changes

### 1. `image-proc/Cargo.toml` — unchanged

No `default` feature. `heic = ["dep:libheif-rs"]` stays exactly as it is today —
symmetric with `raw`. Keep the `libheif-rs = "1"` pin; regenerate `Cargo.lock` as part
of the build once `libheif` dev headers are available locally.

### 2. `image-proc/src/main.rs` — implement `decode_heic()`

Replace the stub (lines 360-368) with a real decode using `libheif-rs`, following the
same `Result<DynamicImage, String>` contract as `decode_raw`/the rest of
`decode_photo`:

- `LibHeif::new()` → `HeifContext::read_from_file(path)` → `primary_image_handle()`
- Decode to an interleaved RGB plane (`ColorSpace::Rgb(RgbChroma::Rgb)`)
- Copy plane data into an `image::RgbImage` respecting the plane's `stride` (HEIF
  planes are often padded — do not assume `stride == width * 3`), then wrap as
  `DynamicImage::ImageRgb8(..)`
- Map every `libheif-rs` error into the existing `format!("... {}: {e}", path.display())`
  error-string style used by `decode_raw`/`image::open`

**Verify the exact `libheif-rs` 1.1.0 API against docs.rs during implementation** —
the intended call shape above is from general knowledge of the crate, not a verified
transcript; minor API details (method names, plane accessor shape) may differ
slightly and should be checked against the pinned version.

Keep the `#[cfg(feature = "heic")]` / `#[cfg(not(feature = "heic"))]` split exactly as
it is — a build without `--features heic` still degrades to today's clear "rebuild
with --features heic" error, unchanged.

### 3. `hatch_build.py`

No change to the feature-selection logic — it already does the right thing once CI
sets the env var:

```python
if os.environ.get("IMAGE_PROC_FEATURE_RAW"):
    features.append("raw")
if os.environ.get("IMAGE_PROC_FEATURE_HEIC"):
    features.append("heic")
```

On Windows only, add a new post-build step to copy `libheif`'s runtime DLLs next to
`image-proc.exe` in `src/ouestcharlie_imageproc/bin/` whenever the `heic` feature was
built — Windows resolves DLLs from the executable's own directory first, so
co-locating them there is sufficient. Gate this on detecting the DLLs exist (i.e. only
copy if the `heic` feature was actually requested), so it's a no-op when HEIC is
disabled, and so **editable/dev installs on Windows also get working DLLs**, not just
CI wheels.

### 4. CI — `.github/workflows/_build.yml`

**Set the feature flag** — the one-line core of this issue, mirroring RAW exactly:

```yaml
- name: Build wheel
  run: hatch build --target wheel
  env:
    IMAGE_PROC_FEATURE_RAW: "1"
    IMAGE_PROC_FEATURE_HEIC: "1"
```

**Install `libheif` at build time**, per OS, before the Rust build/test steps (new
steps, alongside the existing `nasm`/`inih` installs):
- macOS: `brew install nasm inih libheif`
- Linux: `sudo apt-get install -y nasm libheif-dev`
- Windows: `vcpkg install libheif:x64-windows` (or via the `vcpkg` GitHub Action) —
  wire `libheif-sys`'s vcpkg detection (check its build.rs / crate docs for the exact
  env vars it expects, e.g. `VCPKG_ROOT`/triplet). Highest-risk step in this issue:
  vcpkg-built `libheif` pulls in `libde265`, `x265`, `aom`, etc. and may be slow or
  need extra `vcpkg install` flags. Time-box during implementation; if it proves too
  unreliable, the fallback is dropping `IMAGE_PROC_FEATURE_HEIC: "1"` from the Windows
  matrix leg only (asymmetric platform default) as an explicit follow-up rather than
  blocking the whole issue.

**Bundle the shared library into the wheel** so end users need nothing at runtime:
- Linux: already runs `auditwheel repair` — should auto-vendor `libheif.so` and its
  transitive deps. Verify the resulting wheel isn't rejected by auditwheel's manylinux
  policy check because of the added shared libraries.
- macOS: add a new `delocate-wheel` step (add `delocate` next to `hatch`/`auditwheel`
  in the "Install build tools" step) to vendor `libheif.dylib` + transitive deps,
  mirroring the Linux auditwheel step.
- Windows: no auditwheel/delocate equivalent. Covered by the `hatch_build.py`
  DLL-copy step in #3 above, which runs during the wheel build itself.

### 5. Documentation

- `README.md` (repo root) — "Supported formats" table: HEIC/HEIF row becomes
  `Enable with IMAGE_PROC_FEATURE_HEIC=1 — bundled into published wheels by default;
  requires libheif at build time only, none at runtime`. "Building" section: add
  `libheif` next to `nasm` in the per-OS prerequisite commands.
- `image-proc/README.md` — "Optional features" section stays structurally the same
  (`cargo build --release --features heic` is still how you opt in locally); add a
  note that published wheels set this via CI (`IMAGE_PROC_FEATURE_HEIC=1`) so it's on
  by default for anyone installing from PyPI, even though a bare local `cargo
  build`/`pip install -e .` without the env var still excludes it (matches `raw`
  today — call out the symmetry explicitly since it's easy to assume "default in
  practice" means "default in Cargo.toml").
- `imageproc_LLD.md` — Format Support and Platform Matrix (lines 111-123): HEIC row's
  "System dependency" column gains a note that it's build-time only (bundled at
  runtime); drop or reword the Windows ⚠️ if the vcpkg build lands cleanly, otherwise
  keep it with a note on why. Update the "System dependencies required at build time"
  list (lines 137-140) to add `libheif` per OS.
- `ouestcharlie-py-toolkit/py_toolkit_LLD_rationale.md` — the "RAW and HEIC as
  compile-time features" rationale (lines 21-23) currently justifies both being opt-in
  *Cargo features* specifically to avoid "forcing `brew install libheif` on all
  developers." That's still true and unchanged (the Cargo feature itself is
  untouched) — but add a clarifying sentence that published wheels enable `heic` via
  CI regardless, because the runtime system-dependency concern is solved by bundling
  `libheif`'s shared library into the wheel (build-time-only, like `nasm`), not by
  leaving it uncompiled for end users.

### 6. Tests

- **Rust unit test** (`image-proc/src/main.rs` or a `tests/` module, `#[cfg(feature =
  "heic")]`) decoding a small real `.heic` fixture and asserting successful decode +
  correct dimensions.
- **Fixture**: commit a small real HEIC sample (few KB) to `tests/sample-images/`,
  matching the existing precedent there (`001.jpg`, `002.JPG`) rather than generating
  one in-process — this repo's Rust tests don't have a Python HEIC-encoding dependency
  available the way `ouestcharlie-py-toolkit`'s tests now do.
- **Integration test** (`tests_integration/test_image_proc_integration.py`) — add a
  `.heic` case alongside the existing `test_one_time_jpeg_preview_returns_dimensions`,
  exercising the full JSON stdin/stdout protocol end-to-end and asserting correct
  output dimensions. Gate with the existing `requires_binary` skip marker.

---

## Verification

1. ✅ `cargo build --release --features heic` in `image-proc/` — builds and links
   against locally-installed `libheif` (1.23.1 via Homebrew).
2. ✅ `cargo build --release` (no flags) — HEIC excluded, same as today (confirms the
   Cargo-level default is untouched, matching `raw`'s existing behavior).
3. ✅ `cargo test --release --features heic` in `image-proc/` — 42 passed, including
   the new `decode_heic_returns_correct_dimensions` test against a real HEIC fixture
   (`tests/sample-images/003.heic`, committed). `cargo test --release` (no features)
   still passes at 41 (the HEIC test is `#[cfg(feature = "heic")]`-gated).
4. ✅ `cargo clippy --release --features heic` — clean, no warnings.
5. ✅ Manual end-to-end check: built the binary with `--features heic` and fed it a
   real `.heic` file via the JSON stdin/stdout protocol directly — produced a correct
   64×48 JPEG preview (verified pixel values against the source gradient image, no
   channel swap or stride corruption).
6. ✅ `python -m pytest tests_integration/ -v` — new
   `test_one_time_heic_preview_returns_dimensions` passes against the heic-enabled
   binary; correctly **skips** (rather than fails) when run against a binary built
   without `--features heic`, verified by rebuilding without the flag and re-running.
   19/19 tests pass across `tests/` + `tests_integration/`.
7. ☐ Not yet verified — needs actual CI/multi-platform runners, out of reach from this
   local dev environment:
   - `IMAGE_PROC_FEATURE_RAW=1 IMAGE_PROC_FEATURE_HEIC=1 hatch build --target wheel`
     followed by `delocate-wheel`/`auditwheel repair`, then confirming the *repaired*
     wheel decodes HEIC with `libheif` **not** installed system-wide (proves the
     shared library was actually bundled, not just found on the build machine).
   - CI green on all three OS matrix legs in `.github/workflows/_build.yml`, in
     particular the new Windows vcpkg bootstrap step — flagged in the plan as the
     highest-risk part of this issue and explicitly not verifiable locally on macOS.
   - The Windows DLL-copy logic in `hatch_build.py` (`_copy_windows_heic_dlls`) —
     written against `libheif-sys`'s documented `vcpkg` crate usage but never run on
     an actual Windows machine.
