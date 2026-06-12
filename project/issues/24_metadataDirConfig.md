# OEC-24: Configurable Metadata Directory for Local and Cloud-Mounted Backends

#status:open

---

## Context

Both `LocalBackend` and `CloudMountedBackend` always store metadata (`.ouestcharlie/` directory: `summary.json`, `index.lance/`, partition locks, previews) inside the backend root.

This is problematic for cloud-mounted volumes (kDrive, OneDrive, Google Drive, Dropbox via FUSE / Windows Cloud Files API):

- The LanceDB index, lock files, and thumbnails get synced to the cloud, wasting bandwidth and quota.
- Some providers reject or corrupt specific file types (memory-mapped files, lock files).
- Writes to cloud-synced paths trigger upload jobs even for ephemeral data.
- Read-only mounts cause silent or confusing failures on any metadata write.

The fix has two parts:

**1. `ouestcharlie-py-toolkit`** — Add an optional `metadata_dir` parameter to `LocalBackend` (inherited by `CloudMountedBackend`). When set, all metadata is resolved under that directory instead of `.ouestcharlie/` at the root. Default behaviour is unchanged (`.ouestcharlie/` at root).

**2. `ouestcharlie-woof`** — When `add_library` registers a `cloud_mount` backend, automatically default `metadata_dir` to the platform app-support directory. The user can override it. The computed path is stored in `config.json` and forwarded to agents via `WOOF_BACKEND_CONFIG`.

Platform defaults computed by Woof using `platformdirs`:

| Platform | Default metadata path |
|----------|-----------------------|
| macOS    | `~/Library/Application Support/ouestcharlie/metadata/{mount_hash}/` |
| Windows  | `%LOCALAPPDATA%\ouestcharlie\metadata\{mount_hash}\` |
| Linux    | `$XDG_DATA_HOME/ouestcharlie/metadata/{mount_hash}/` (fallback `~/.local/share/`) |

`{mount_hash}` is a short BLAKE2b hash of the mount root path, isolating each cloud drive.

---

## Approach

1. Add `metadata_path(relative: str) -> Path` to the `Backend` protocol — the canonical API for resolving absolute metadata paths regardless of backend type.
2. Update `LocalBackend.__init__` to accept `metadata_dir: Path | None`. Implement `metadata_path()` to resolve under `metadata_dir` when set, or under `self._root / METADATA_DIR` otherwise.
3. `CloudMountedBackend` inherits both `__init__` parameter and `metadata_path()` from `LocalBackend` — no override needed.
4. Remove path-assembly helpers from `schema.py`; keep only constants. Migrate call sites to `backend.metadata_path(SUMMARY_FILENAME)` etc.
5. Extend `LibraryConfig` in Woof to carry an optional `metadata_dir` field. In `add_library`, compute the platform default for `cloud_mount` backends using `platformdirs.user_data_dir()`.
6. Forward `metadata_dir` to agents via `LibraryConfig.to_agent_env()`.
7. Update docs and tests.

---

## Implementation

### `ouestcharlie-py-toolkit`

#### `src/ouestcharlie_toolkit/backend.py`

Add to the `Backend` Protocol:

```python
def metadata_path(self, relative: str) -> Path:
    """Absolute local path for a metadata artifact (e.g. SUMMARY_FILENAME).
    Always local — never inside a cloud-synced volume."""
    ...
```

#### `src/ouestcharlie_toolkit/backends/local.py`

```python
class LocalBackend:
    def __init__(self, root: Path, metadata_dir: Path | None = None) -> None:
        self._root = root
        self._metadata_dir = metadata_dir

    def metadata_path(self, relative: str) -> Path:
        base = self._metadata_dir if self._metadata_dir else self._root / METADATA_DIR
        return base / relative
```

Update `backend_from_config()` (both `"local"` and `"filesystem"` type keys):

```python
metadata_dir = Path(cfg["metadata_dir"]) if "metadata_dir" in cfg else None
return LocalBackend(Path(cfg["root"]), metadata_dir=metadata_dir)
```

`CloudMountedBackend` picks up both changes via inheritance — no changes needed in `cloud_mount.py` beyond the same `backend_from_config()` entry.

#### `src/ouestcharlie_toolkit/schema.py`

Remove `summary_path()`, `lance_index_path()`, `preview_jpeg_path()`. Keep constants only:

```python
METADATA_DIR = ".ouestcharlie"
SUMMARY_FILENAME = "summary.json"
LANCE_INDEX_SUBDIR = "index.lance"
PREVIEW_JPEG_SUBDIR = "previews"
```

Migrate all internal call sites to `backend.metadata_path(SUMMARY_FILENAME)` etc.

---

### `ouestcharlie-woof`

#### `src/woof/config.py`

Extend `LibraryConfig` with the new optional field:

```python
@dataclass
class LibraryConfig:
    name: str
    type: str
    path: str
    metadata_dir: str | None = None   # NEW: absolute path; None → default (.ouestcharlie at root)

    def to_agent_env(self) -> dict[str, str]:
        cfg: dict[str, str] = {"name": self.name, "type": self.type, "root": self.path}
        if self.metadata_dir:
            cfg["metadata_dir"] = self.metadata_dir
        return cfg
```

Add a helper for computing the platform default (uses the already-imported `platformdirs`):

```python
import hashlib
from platformdirs import user_data_dir

def _cloud_mount_metadata_dir(root: str) -> str:
    mount_hash = hashlib.blake2b(root.encode(), digest_size=6).hexdigest()
    base = Path(user_data_dir("ouestcharlie"))
    return str(base / "metadata" / mount_hash)
```

#### `src/woof/server.py` — `add_library` tool

When `library_type == "cloud_mount"` and `metadata_dir` is not supplied, set the platform default:

```python
async def add_library(
    name: str,
    path: str,
    library_type: str = "filesystem",
    metadata_dir: str | None = None,
) -> dict[str, Any]:
    if library_type == "cloud_mount" and metadata_dir is None:
        metadata_dir = _cloud_mount_metadata_dir(path)
    library = LibraryConfig(name=name, type=library_type, path=path, metadata_dir=metadata_dir)
    self.config.add_library(library)
```

---

### Documentation

#### `ouestcharlie/HLD.md`

In the **Metadata files** section and **Backend comparison summary** table, add:

> `metadata_dir` is an optional config key for both `filesystem` and `cloud_mount` backends. When set, all metadata is stored at that local path instead of inside the backend root. For `cloud_mount` backends, Woof defaults `metadata_dir` to the platform app-support directory (via `platformdirs.user_data_dir()`), keeping operational data out of the synced volume. Callers resolve metadata paths via `backend.metadata_path(relative)`.

#### `agent/py_toolkit/py_toolkit_LLD.md`

In the **Backends** section, document:
- The `metadata_dir` config key (optional string, applies to both backend types).
- `LocalBackend` behaviour: co-located default vs. explicit redirect.
- `metadata_path()` method — the single API for metadata path resolution.
- Migration note: `schema.py` path helpers removed; use `backend.metadata_path()`.

#### `ouestcharlie-woof/doc/design/woof_LLD.md`

In the **add_library** tool description, document:
- The new optional `metadata_dir` parameter.
- Automatic platform default for `cloud_mount` backends.
- `_cloud_mount_metadata_dir()` helper and mount hash scheme.

---

## Unit Tests

### `ouestcharlie-py-toolkit` — `tests/test_backend_local.py` (extend)

| # | Test | What it verifies |
|---|------|-----------------|
| 1 | `test_metadata_path_default` | No `metadata_dir` → `metadata_path("summary.json")` == `root/.ouestcharlie/summary.json`. |
| 2 | `test_metadata_path_explicit` | Explicit `metadata_dir` → resolves there, not under root. |
| 3 | `test_config_metadata_dir_key` | `backend_from_config({…, "metadata_dir": "…"})` passes path through. |
| 4 | `test_config_no_metadata_dir_key` | Config without `metadata_dir` key → default behaviour preserved. |

### `ouestcharlie-py-toolkit` — `tests/test_backend_cloud_mount.py` (extend)

| # | Test | What it verifies |
|---|------|-----------------|
| 5 | `test_metadata_path_explicit_dir` | Explicit `metadata_dir` → resolves there, mount root untouched. |
| 6 | `test_metadata_path_no_dir` | No `metadata_dir` → resolves inside mount root (LocalBackend default). |
| 7 | `test_photo_path_not_remapped` | Non-metadata path still resolves inside mount root. |
| 8 | `test_config_metadata_dir_key` | `backend_from_config({…, "metadata_dir": "…"})` passes path through. |

### `ouestcharlie-py-toolkit` — `tests/test_schema.py` (extend)

| # | Test | What it verifies |
|---|------|-----------------|
| 9 | `test_path_helpers_removed` | `summary_path` etc. no longer importable from `schema`. |
| 10 | `test_constants_present` | `METADATA_DIR`, `SUMMARY_FILENAME`, etc. still importable. |

### `ouestcharlie-woof` — `tests/test_config.py` (extend)

| # | Test | What it verifies |
|---|------|-----------------|
| 11 | `test_library_config_serialises_metadata_dir` | `to_agent_env()` includes `metadata_dir` when set. |
| 12 | `test_library_config_omits_metadata_dir_when_none` | `to_agent_env()` omits `metadata_dir` key when `None`. |
| 13 | `test_add_library_cloud_mount_sets_default_metadata_dir` | `add_library` with `cloud_mount` type sets a non-None `metadata_dir`. |
| 14 | `test_add_library_cloud_mount_explicit_metadata_dir` | Explicit `metadata_dir` argument is not overridden. |
| 15 | `test_add_library_filesystem_no_metadata_dir` | `filesystem` type leaves `metadata_dir` as `None`. |
| 16 | `test_cloud_mount_metadata_dir_is_outside_root` | The computed default is not a sub-path of the mount root. |
| 17 | `test_cloud_mount_metadata_dir_distinct_per_root` | Two different mount roots get different default `metadata_dir` values. |

---

## Verification

1. Run py-toolkit tests:
   ```
   /Users/antoinehue/Code/charlie/ouestcharlie-py-toolkit/.venv/bin/python -m pytest tests/ -v
   ```
2. Run Woof tests:
   ```
   cd /Users/antoinehue/Code/charlie/ouestcharlie-woof && .venv/bin/python -m pytest tests/ -v
   ```
3. Instantiate `LocalBackend` with no `metadata_dir`; confirm `metadata_path("summary.json")` == `<root>/.ouestcharlie/summary.json`.
4. Instantiate `LocalBackend` with explicit `metadata_dir`; confirm path is outside root.
5. Call `add_library` via Woof MCP with `library_type="cloud_mount"` and no `metadata_dir`; confirm `config.json` contains a `metadata_dir` outside the mount root, in the platform app-support tree.
6. Grep for remaining `summary_path()` / `lance_index_path()` calls — confirm all migrated.
