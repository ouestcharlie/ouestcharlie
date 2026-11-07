# OEC-70: Windows wheel depends on the Microsoft C++ runtime being installed

#status:done

> **2026-10-24:** PR merged; CI passed on all platforms, including the new Windows
> import-table test. Still pending: the manual test on a fresh Windows machine with
> only Python installed (see Verification).

## Context

The Windows wheel of `ouestcharlie-imageproc` ships `image-proc.exe` alone. libheif and
its codecs are linked into the exe (vcpkg triplet `x64-windows-static-md`), so no libheif
DLL is needed. But the exe still imports the Microsoft C++ runtime dynamically: that is
what the `-md` in the triplet means, and libheif is built against it.

Import table of `image-proc.exe` in the published 2.4.1 wheel (read from the PE header):

- Windows system DLLs: `KERNEL32`, `ntdll`, `ADVAPI32`, `bcryptprimitives`,
  `api-ms-win-*` (Universal CRT, part of Windows 10 and later)
- **Microsoft C++ runtime:** `MSVCP140.dll`, `VCRUNTIME140.dll`, `VCRUNTIME140_1.dll`

The python.org installer ships `vcruntime140.dll` and `vcruntime140_1.dll` next to
`python.exe`, but **not `MSVCP140.dll`**. That one comes from the Visual C++
Redistributable. Most Windows PCs have it (many applications install it), but a clean
Windows install does not. On such a machine `image-proc.exe` fails to start, so Woof
cannot build thumbnails or previews, and the error a user sees is a Windows loader error
("MSVCP140.dll was not found"), not a message from Woof.

CI does not catch this: GitHub's `windows-latest` runners have the redistributable
preinstalled, so the integration tests pass.

The exe is also started from Python's directory tree, not next to `python.exe`, so even
the `vcruntime140*.dll` that Python ships are not guaranteed to be found by the loader.

Intended outcome: the Windows wheel runs on a clean Windows 10/11 machine with only
Python installed.

---

## Analysis

| Option | How | Verdict |
|---|---|---|
| Static C++ runtime | Rust `+crt-static` and vcpkg `x64-windows-static` triplet | Rejected for now: the static triplet is not the one `libheif-sys`' build script picks on MSVC (it reports the library as "not installed"), and mixing a static Rust runtime with a dynamic-runtime libheif is unsafe. Worth a time-boxed try only if the options below fail. |
| `delvewheel` | Post-build step `delvewheel repair` on the wheel, the Windows counterpart of `delocate` (macOS) and `auditwheel` (Linux) | **Rejected after checking its source (1.13):** it puts DLLs in a separate `<package>.libs` folder and patches `__init__.py` to call `os.add_dll_directory`, which only affects the Python process. `image-proc.exe` runs as a subprocess and only searches its own folder, System32 and `PATH`. It also skips `vcruntime140*.dll`, assuming Python's copies are found, which is not true for a separate exe. |
| Copy the runtime DLLs next to the exe | `hatch_build.py` copies `msvcp140.dll` and `vcruntime140*.dll` from Visual Studio's redistributable folder (found with `vswhere`, or `VCToolsRedistDir` in a developer prompt) into `bin/` | **Chosen.** Microsoft's documented "app-local deployment"; Windows searches the exe's folder first. About 15 lines in the build hook, no new build tool. |
| Document the redistributable as a requirement | README / Woof install notes | Fallback only: users rarely read it, and the failure message does not point at Woof. |

The Microsoft C++ runtime DLLs may be redistributed with an application (Visual Studio
redistributable license). The files in Visual Studio's `VC\Redist\MSVC` folder are the ones
the terms list as redistributable.

---

## Changes

### 1. Build hook: bundle the runtime next to the exe (done)

**File:** `ouestcharlie-imageproc/hatch_build.py`

On Windows, after copying `image-proc.exe`, copy the three runtime DLLs it imports
from the newest MSVC redist version of the latest Visual Studio with C++ tools. If the
folder is not found (no Visual Studio), print a warning; the test below then fails in
CI. Covers editable installs on Windows too.

### 2. Tests (done)

**File:** `ouestcharlie-imageproc/tests_integration/test_binary_health.py`

- New Windows-only test: read the exe's import table and assert that every
  non-system DLL it imports (anything outside `KERNEL32`, `ntdll`, `ADVAPI32`,
  `bcryptprimitives`, `api-ms-win-*`) is present in the installed wheel. This catches a
  missing runtime on CI even though the runner has it installed globally.
- The existing launch test keeps covering "the exe starts".

### 3. Documentation

- `imageproc_LLD.md`, Build section: on Windows the wheel bundles the Microsoft C++
  runtime next to the exe, and why not `delvewheel` (done).

---

## Verification

- CI: the new import-table test passes on the Windows leg.
- Wheel contents: `unzip -l` shows `msvcp140.dll`, `vcruntime140.dll` and
  `vcruntime140_1.dll` next to `image-proc.exe` in the Windows wheel.
- Clean machine: on a Windows 10 or 11 VM with only Python from python.org installed and
  no Visual C++ Redistributable (Windows Sandbox works for this), `pip install` the wheel
  and run `python -c "from ouestcharlie_imageproc import OneTimeImageProc"` followed by a
  `jpeg_preview` on a HEIC and a DNG sample. Before the fix this should fail with
  "MSVCP140.dll was not found"; after it, it should succeed.
