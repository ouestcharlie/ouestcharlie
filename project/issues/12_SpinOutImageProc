# Spin out image-proc from py-toolkit and improvements to the CI

#status:done

## Context

The Rust `image-proc` binary and its Python subprocess wrapper live inside `ouestcharlie-py-toolkit`. The Rust toolchain is a heavy build dependency that complicates toolkit development and CI. Moving it to a standalone package lets the toolkit become pure Python again.

The CI of all other ouestcharlie packages is modified to load ouestcharlie dependencies in edit mode, with imageproc as the exception

**Natural cut line:** `image_proc.py` has zero imports from `ouestcharlie_toolkit` (pure stdlib only). Moving it + the Rust source to a new package creates a clean one-way dependency with no cross-dependency:

```
ouestcharlie-imageproc   ← stdlib only, no Python package deps
        ↑
ouestcharlie-py-toolkit  ← gains imageproc as dep; thumbnail_builder + preview_builder stay here
        ↑
agents (whitebeard, wally, woof)  ← CI updated to checkout toolkit editable; no pyproject changes
```

`thumbnail_builder.py` and `preview_builder.py` stay in the toolkit — only their single `image_proc` import line changes.

---

## Part 1 — New Package: `outestcharlie-imageproc`

**Package name:** `ouestcharlie-imageproc`
**Python namespace:** `ouestcharlie_imageproc`
**Version:** `1.0.0` (aligns with `image-proc/Cargo.toml` current version)

### Files to create

| File | Source / Action |
|------|----------------|
| `pyproject.toml` | New — no ouestcharlie deps; same shape as toolkit's |
| `hatch_build.py` | Copy toolkit's; change `ouestcharlie_toolkit` → `ouestcharlie_imageproc` in `bin_dir` |
| `src/ouestcharlie_imageproc/__init__.py` | New — export `OneTimeImageProc`, `PersistentImageProc`, `IMAGE_PROC_PROTOCOL_MAJOR_VERSION` |
| `src/ouestcharlie_imageproc/image_proc.py` | Move from toolkit; update error message path |
| `src/ouestcharlie_imageproc/bin/.gitkeep` | New (populated at build time) |
| `image-proc/` (entire dir) | Move from toolkit |
| `tests/test_image_proc.py` | Move from toolkit |
| `tests/sample-images/` | Copy fixtures used by image_proc tests |
| `tests_integration/test_image_proc_integration.py` | Move from toolkit |
| `.pre-commit-config.yaml` | Copy from toolkit |
| `README.md` | Update with proper package description |
| `imageproc_LLD.md` | New — extracted from `py_toolkit_LLD.md` § Image Processing |
| `.github/workflows/_build.yml` | New — mirrors toolkit's multi-platform Rust CI |
| `.github/workflows/build.yml` | New — calls `_build.yml` on PRs |
| `.github/workflows/publish.yml` | New — publishes to PyPI on version tags |

**`pyproject.toml` shape:**
```toml
[project]
name = "ouestcharlie-imageproc"
version = "1.0.0"
requires-python = ">=3.12"
dependencies = []   # stdlib only

[tool.hatch.build.hooks.custom]
path = "hatch_build.py"

[tool.hatch.build.targets.wheel]
packages = ["src/ouestcharlie_imageproc"]
artifacts = ["src/ouestcharlie_imageproc/bin/*"]
```

**`hatch_build.py` change (one line):**
```python
# Before (toolkit):
bin_dir = Path(__file__).parent / "src" / "ouestcharlie_toolkit" / "bin"
# After (imageproc):
bin_dir = Path(__file__).parent / "src" / "ouestcharlie_imageproc" / "bin"
```

---

## Part 2 — Changes to `ouestcharlie-py-toolkit`

### Delete
- `src/ouestcharlie_toolkit/image_proc.py`
- `image-proc/` (entire directory)
- `hatch_build.py`
- `tests/test_image_proc.py`
- `tests_integration/test_image_proc_integration.py`

### Update

**`src/ouestcharlie_toolkit/thumbnail_builder.py`** — one line:
```python
# Before:
from ouestcharlie_toolkit.image_proc import OneTimeImageProc
# After:
from ouestcharlie_imageproc.image_proc import OneTimeImageProc
```

**`src/ouestcharlie_toolkit/preview_builder.py`** — one line:
```python
# Before:
from ouestcharlie_toolkit.image_proc import PersistentImageProc
# After:
from ouestcharlie_imageproc.image_proc import PersistentImageProc
```

**`pyproject.toml`:**
- Add `"ouestcharlie-imageproc>=1.0.0"` to `[project] dependencies`
- Remove `[tool.hatch.build.hooks.custom]` section
- Remove `artifacts = [...]` from wheel target (toolkit is pure Python again)

**`py_toolkit_LLD.md`:** remove § Image Processing; add pointer to `imageproc_LLD.md`

**`README.md`:** remove image-proc build instructions

`thumbnail_builder.py`, `preview_builder.py`, and their tests stay unchanged beyond the one-line import fix.

---

## Part 3 — CI Updates for Agent Repos

**Goal:** agent CIs checkout pure-Python `ouestcharlie-*` deps from GitHub HEAD and install them
editable, so PRs across repos can be merged without releasing packages to PyPI.

**Exception: `ouestcharlie-imageproc` is always installed from PyPI** — it's a compiled binary wheel
that evolves slowly and is expensive to build from source (Rust + nasm). Agent CIs never checkout or
compile it; pip resolves it from PyPI when installing the toolkit editable.

**Pattern to add to each agent's `_build.yml`** (before the existing `hatch build` step):

```yaml
# Check out pure-Python ouestcharlie-* deps at adjacent paths (mirrors uv.sources convention)
- uses: actions/checkout@v6
  with:
    repository: ouestcharlie/ouestcharlie-py-toolkit
    path: ../ouestcharlie-py-toolkit

# Install editable — imageproc pulled from PyPI transitively
- name: Install toolkit (editable)
  run: pip install -e ../ouestcharlie-py-toolkit
```

### `ouestcharlie-whitebeard/_build.yml`
Add the pattern above. No other changes.

### `ouestcharlie-wally/_build.yml`
Add the pattern above. No other changes.

### `ouestcharlie-woof/_build.yml`
Add the pattern above, **plus** checkout and editable install of whitebeard and wally:

```yaml
- uses: actions/checkout@v6
  with:
    repository: ouestcharlie/ouestcharlie-py-toolkit
    path: ../ouestcharlie-py-toolkit
- uses: actions/checkout@v6
  with:
    repository: ouestcharlie/ouestcharlie-whitebeard
    path: ../ouestcharlie-whitebeard
- uses: actions/checkout@v6
  with:
    repository: ouestcharlie/ouestcharlie-wally
    path: ../ouestcharlie-wally

# Install editable (toolkit first — imageproc pulled from PyPI; then agents)
- name: Install toolkit (editable)
  run: pip install -e ../ouestcharlie-py-toolkit
- name: Install whitebeard (editable)
  run: pip install -e ../ouestcharlie-whitebeard
- name: Install wally (editable)
  run: pip install -e ../ouestcharlie-wally
```

**No changes to any agent's `pyproject.toml`** — the editable installs are CI-only.

---

## Verification

1. **imageproc builds standalone:** `pip install -e . --no-build-isolation` in the new repo — compiles without toolkit installed.
2. **imageproc unit tests:** `.venv/bin/python -m pytest tests/ -v`
3. **imageproc integration tests:** `.venv/bin/python -m pytest tests_integration/ -v`
4. **Toolkit is pure Python:** after spinout, `pip install ouestcharlie_py_toolkit-*.whl` works without Rust.
5. **Toolkit tests still pass:** `.venv/bin/python -m pytest tests/ -v` in toolkit
6. **Agent CIs pass without PyPI releases:** push to a branch in each agent repo, confirm CI picks up GitHub HEAD of all pure-Python ouestcharlie-* deps.