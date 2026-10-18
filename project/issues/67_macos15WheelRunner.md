# OEC-67: build the macOS image-proc wheel on macos-15

#status:draft

Status flow: draft (write spec) -> open (review spec) -> todo (spec validated) -> ongoing (implementation started) -> done (merged)

## Context

GitHub retires the `macos-14` hosted runner image (labels `macos-14`,
`macos-14-large`, `macos-14-xlarge`) on **2 November 2026**
([changelog](https://github.blog/changelog/2026-10-01-github-actions-macos-14-runner-image-retirement)).
Before that, jobs on it fail during scheduled brownouts. One is on
19 October 2026, 14:00 to 20 October 00:00 UTC. Queue times may also grow as
GitHub reduces capacity.

The macOS job in `ouestcharlie-imageproc/.github/workflows/_build.yml` is
pinned to `macos-14`. Once the image is gone, the job no longer starts, and no
macOS arm64 wheel can be released. A release during a brownout fails the same
way.

### Timing

Nothing breaks for users on 2 November: the wheels already on PyPI stay
installable. The retirement only blocks building a new release. There is no
image-proc change pending, so this is done together with the next image-proc
code change, as its first commit, rather than as a standalone release.

No other repository depends on `macos-14`. Woof's integration tests use
`macos-latest`, and every other job runs on Ubuntu or Windows.

### Why the pin matters

The pin is what makes the wheel's minimum macOS version 14:

- The job installs `libheif` and its codecs (`libde265`, `x265`, `aom`, …) with
  `brew install`. Homebrew bottles are built for the runner's OS, so on
  `macos-14` the bundled dylibs have a `minos` of 14.0.
- `MACOS_MIN_VERSION: "14.0"` becomes `MACOSX_DEPLOYMENT_TARGET`, which sets the
  Rust binary's `minos` and, through `hatch_build.py`, the wheel tag
  `py3-none-macosx_14_0_arm64`.
- Two guards fail the build when any Mach-O file in the wheel needs a newer
  macOS: `delocate-wheel --require-target-macos-version` and the `otool`
  `LC_BUILD_VERSION` check.

So changing the runner name alone to `macos-15` fails the build: the Homebrew
libraries come out with `minos` 15.0, and both guards reject them. That is
intended. Without the guards, the wheel would silently become
`macosx_15_0_arm64`.

### Options

1. **Raise the minimum to macOS 15.** Run on `macos-15`, set
   `MACOS_MIN_VERSION: "15.0"`. Small change, and Homebrew stays the source of
   libheif. On macOS 14, pip finds no matching wheel and falls back to the
   sdist, which builds without HEIC or RAW.
2. **Keep macOS 14 by building libheif from source.** Run on `macos-15`, but
   build libheif and its codecs with `MACOSX_DEPLOYMENT_TARGET=14.0` into their
   own prefix and cache it, as the Linux job already does. This keeps
   `macosx_14_0_arm64`, but adds a source build of several codec libraries to
   maintain on macOS.

Proposed: option 1. Apple stops shipping security updates for the oldest
supported macOS about once a year, and macOS 14 is the oldest one now. Option 2
stays possible later if macOS 14 users show up.

Intended outcome: the macOS arm64 wheel builds on a supported runner, with HEIC
and RAW, and installs on macOS 15 and later.

---

## Changes

### 1. CI: macOS runner and minimum version

**File:** `ouestcharlie-imageproc/.github/workflows/_build.yml`

- Matrix entry: `macos-14` → `macos-15`. Keep the pin (not `macos-latest`): the
  runner OS still sets the minimum macOS of the Homebrew libraries.
- `MACOS_MIN_VERSION: "14.0"` → `"15.0"`.
- No change to the `delocate-wheel` and `otool` guards, which read
  `MACOS_MIN_VERSION`.

### 2. Documentation

**File:** `ouestcharlie-imageproc/imageproc_LLD.md`

- Platform table: `macosx_15_0_arm64`, `macos-15` runner,
  `MACOSX_DEPLOYMENT_TARGET=15.0`.
- State that macOS 14 is no longer supported by the prebuilt wheel, and that an
  sdist build has no HEIC/RAW unless the feature variables are set.

Also check the user-facing install docs (README files for Woof and image-proc)
for a stated minimum macOS version.

### 3. Release

Ship with the next image-proc release (see Timing). Then bump the dependency in Woof and
regenerate its `uv.lock`, so the lock file lists the `macosx_15_0_arm64` wheel.

---

## Verification

1. image-proc CI: the macOS job runs on `macos-15`, both minimum-version guards
   pass, and the artifact is named
   `ouestcharlie_imageproc-<v>-py3-none-macosx_15_0_arm64.whl`.
2. On a macOS 15 or later machine, in a fresh Python 3.14 venv:
   `uv pip install --only-binary :all: ouestcharlie-imageproc` succeeds, and the
   HEIC integration tests pass.
3. Woof CI (`macos-latest`) installs the new wheel and passes.

---

## Open points

- Option 1 or 2: is macOS 14 support worth a from-source libheif build on macOS?
- Should the old `macosx_14_0_arm64` wheels stay on PyPI for macOS 14 users?
  They do by default (nothing is deleted), so macOS 14 users get the last
  version built on `macos-14` if they pin it. With an unpinned install, they
  fall back to the sdist of the newest version instead.
- `macos-15` will be retired too. Each bump raises the minimum macOS again
  under option 1. Moving to option 2 at some point removes that coupling.
