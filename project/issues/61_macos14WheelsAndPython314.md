# OEC-61: image-proc wheels for macOS 14+, and Python 3.14 across all packages

#status:done

Status flow: draft (write spec) -> open (review spec) -> todo (spec validated) -> ongoing (implementation started) -> done (merged)

## Context

### image-proc wheels install almost nowhere on macOS

`ouestcharlie-imageproc` 2.3.2 publishes these wheels on PyPI:

- `cp313-cp313-macosx_26_0_arm64`
- `cp313-cp313-manylinux_2_34_x86_64`
- `cp313-cp313-win_amd64`

Two things restrict the macOS wheel:

- **Python tag.** `hatch_build.py` sets `build_data["infer_tag"] = True`, so
  the wheel is tagged for the CPython version that built it (3.13). The package
  holds a standalone Rust binary and a thin Python wrapper, with no Python
  extension module. Nothing in it depends on the Python version.
- **macOS version.** The macOS job runs on `macos-latest`, currently macOS 26.
  The binary and the Homebrew libheif libraries that `delocate-wheel` bundles
  are all built for that OS, hence `macosx_26_0`. The wheel can't be installed
  on macOS 15 or older.

When no wheel matches, uv/pip silently fall back to the sdist and build locally.
`hatch_build.py` enables HEIC and RAW only when `IMAGE_PROC_FEATURE_HEIC` /
`IMAGE_PROC_FEATURE_RAW` are set, so the local build has neither. Indexing then
fails thumbnail generation for any partition containing a HEIC file
(`image-proc error: HEIC/HEIF format not supported; rebuild with --features
heic`). This has been observed on a macOS 15 machine running a Python 3.14 venv.

CI does not catch this. Woof's integration tests install image-proc on
`macos-latest` with Python 3.13, the one combination where the PyPI wheel
matches.

### Python 3.14

All five packages declare `requires-python = ">=3.13"`, and build and test only
on 3.13:

| Package | `requires-python` | CI | ruff / mypy target |
|---|---|---|---|
| ouestcharlie-py-toolkit | `>=3.13` | 3.13 | `py313` / `3.13` |
| ouestcharlie-imageproc | `>=3.13` | 3.13 | `py313` / `3.13` |
| ouestcharlie-whitebeard | `>=3.13` | 3.13 | `py313` / `3.13` |
| ouestcharlie-wally | `>=3.13` | 3.13 | `py313` / `3.13` |
| ouestcharlie-woof | `>=3.13` | 3.13 | `py313` / `3.13` |

The Woof bundle pins 3.13 at runtime too: `manifest.json` runs
`uv tool run --python 3.13` and declares `"python": "3.13"`, and
`pyproject_packaging.toml` requires `==3.13.*`.

A Woof development venv on Python 3.14 already runs the full stack (pyexiv2,
lancedb, pyarrow, pillow-heif, MCP SDK), so the dependencies are available for
3.14.

Intended outcome:

1. The macOS image-proc wheel installs on macOS 14 and later, with HEIC and RAW,
   on any supported Python version. No user builds image-proc from the sdist.
2. Python 3.14 is the version all packages build, test and ship with.

---

## Changes

### 1. image-proc: version-independent wheel tag

**File:** `ouestcharlie-imageproc/hatch_build.py`

Replace the inferred tag with an explicit `py3-none-<platform>` tag, since the
wheel contains no CPython extension:

```python
# Before
build_data["infer_tag"] = True

# After
build_data["pure_python"] = False
build_data["tag"] = f"py3-none-{_platform_tag()}"
```

`_platform_tag()` derives the platform from `sysconfig.get_platform()`
(normalised: `-` and `.` become `_`). On macOS it honours
`MACOSX_DEPLOYMENT_TARGET` when set. The Linux wheel is still retagged to
`manylinux_*` by `auditwheel repair`, and `delocate-wheel` still rewrites the
macOS platform tag to match the bundled libraries.

The Python version then only matters for `requires-python`.

### 2. image-proc: build the macOS wheel for macOS 14

**File:** `ouestcharlie-imageproc/.github/workflows/_build.yml`

- Change the macOS matrix entry from `macos-latest` to `macos-14` (arm64). The
  Homebrew bottles installed there (`libheif`, `libde265`, `x265`, `aom`, …) are
  built for macOS 14, so the bundled libraries have a minimum OS version of 14.
- Set `MACOSX_DEPLOYMENT_TARGET: "14.0"` for the cargo test and `hatch build`
  steps, so the Rust binary targets 14.0 as well.
- Make `delocate-wheel` fail on a mismatch instead of silently raising the tag:
  `delocate-wheel --require-target-macos-version 14.0 -w dist/ -v dist/*.whl`.
- Add a check after the macOS build that no Mach-O file in the wheel has a
  `minos` above 14.0: `otool -l` on the binary and every bundled dylib, reading
  `LC_BUILD_VERSION`.

Risk: GitHub retires older macOS runners over time. When `macos-14` goes away,
a later runner still works, provided libheif and its codecs are built from
source with `MACOSX_DEPLOYMENT_TARGET=14.0` (the same approach as the Linux
job) instead of coming from Homebrew.

### 3. Python 3.14 in every package

**Files:** `pyproject.toml` and `.github/workflows/_build.yml` in
`ouestcharlie-py-toolkit`, `ouestcharlie-imageproc`,
`ouestcharlie-whitebeard`, `ouestcharlie-wally` and `ouestcharlie-woof`;
also `ouestcharlie-woof/.github/workflows/build.yml`.

- `requires-python = ">=3.14"`.
- Add the `Programming Language :: Python :: 3.14` classifier.
- ruff `target-version = "py314"`, mypy `python_version = "3.14"`. Fix any new
  lint or type findings.
- `actions/setup-python` `python-version: "3.14"` in every build, sdist and
  integration-test job.
- Regenerate each `uv.lock`.

Release order follows the dependency chain: py-toolkit and image-proc first,
then whitebeard and wally, then woof.

### 4. Woof bundle and launch configuration

**Files:** `ouestcharlie-woof/manifest.json`,
`ouestcharlie-woof/pyproject_packaging.toml`

- `manifest.json`: `uv tool run --python 3.14 …` and `"python": "3.14"`.
- `pyproject_packaging.toml`: `requires-python = "==3.14.*"`.

### 5. Tests

**File:** `ouestcharlie-imageproc/tests_integration/test_binary_health.py`

- Assert that the installed wheel's tag starts with `py3-none-`.
- On macOS, assert that the binary's `minos` is at most 14.0.
- Assert that HEIC is supported by the installed binary. `_heic_supported()` in
  `test_image_proc_integration.py` already probes this; in CI a missing HEIC
  feature must fail the run, not skip the HEIC tests.

**File:** `ouestcharlie-woof/.github/workflows/build.yml`

- Install image-proc from the wheel built in the same pipeline, or from PyPI,
  and fail if pip falls back to the sdist (`pip install --only-binary
  ouestcharlie-imageproc …`). This is the check that would have caught the
  macOS 26 tag.

### 6. Documentation

- `ouestcharlie-py-toolkit/README.md`: `uv venv --python 3.14`.
- `ouestcharlie-woof/README.md`: the three client configuration examples use
  `--python 3.14`.
- `ouestcharlie-imageproc/imageproc_LLD.md`: document the `py3-none` tag, the
  macOS 14 minimum, and that an sdist build has no HEIC/RAW unless the feature
  variables are set.
- Python 3.13 notes in `py_toolkit_LLD.md`, `.claude/CLAUDE.md` and code
  comments ("3.13+") stay valid and need no change.

---

## Verification

1. image-proc CI: the macOS artifact is named
   `ouestcharlie_imageproc-<v>-py3-none-macosx_14_0_arm64.whl`, and the
   `minos` check passes.
2. On a macOS 14 or 15 machine, in a fresh Python 3.14 venv:
   `uv pip install --only-binary :all: ouestcharlie-imageproc` succeeds, and the
   HEIC integration tests pass.
3. In an existing Woof venv that holds a locally built image-proc:
   `uv sync --reinstall-package ouestcharlie-imageproc` replaces it with the
   PyPI wheel. The installed `.dist-info/WHEEL` shows `py3-none-macosx_14_0_arm64`.
4. All five packages pass CI on Python 3.14.
5. Install the Woof bundle in Claude Desktop, run `index_library` on a library
   with HEIC photos: no "HEIC/HEIF format not supported" error, and the HEIC
   photos have thumbnails.

---

## Open points

- Keep `requires-python = ">=3.13"` and test both 3.13 and 3.14 instead? That's
  gentler for users on a 3.13 system Python, but doubles the CI matrix. The
  Woof bundle picks its Python through uv, so bundle users are not affected
  either way.
- Should an sdist build fail, or at least warn, when HEIC is not enabled, rather
  than silently producing a binary without it? Failing would break builds on
  machines without libheif. A warning at build time plus a startup log line from
  Woof ("image-proc built without HEIC") may be enough.
- macOS x86_64 (Intel) has no wheel today. Out of scope here, but `macos-13`
  (the last Intel runner) is already scheduled for retirement.
