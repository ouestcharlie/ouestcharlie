# OEC-31c: `lancedb_index_path` config override for UNC / mounted drives

#status:done

## Context

OEC-31 and OEC-31b address UNC path failures in `lance_index.py` at the URI-construction level.
OEC-31c adds a **config-level escape hatch**: an optional `lancedb_index_path` field on
`LibraryConfig` that redirects the LanceDB index to a user-specified local path. This is needed
when the upstream `object_store` bugs make the index unreliable on a network share regardless of
URI encoding.

On Windows, when a new library is registered whose root resolves to a UNC path (either an explicit
`\\server\share\` or a mapped drive letter such as `Z:\` backed by a network share), Woof
automatically sets `lancedb_index_path` to `%LOCALAPPDATA%\ouestcharlie\indexes\<library_name>`,
keeping the index on local NTFS where `object_store` operates reliably.

Existing libraries whose root resolves to UNC are backfilled on the next Woof startup via
`_migrate()`.

---

## Changes

### 1. `ouestcharlie-woof/src/woof/config.py`

#### a) New field on `LibraryConfig`

```python
@dataclass
class LibraryConfig:
    name: str
    type: str
    path: str
    lancedb_index_path: str | None = None
```

`WoofConfig.load()` already does `LibraryConfig(**b)`, so JSON round-trips are free — the
`dataclass` default handles absent keys. `save()` uses `asdict()` which includes `None`; that
is acceptable.

Update `to_agent_env()` to propagate the field when set:

```python
def to_agent_env(self) -> dict[str, str]:
    env = {"name": self.name, "type": self.type, "root": self.path}
    if self.lancedb_index_path is not None:
        env["lancedb_index_path"] = self.lancedb_index_path
    return env
```

#### b) `_resolve_to_unc(path)` helper

```python
def _resolve_to_unc(path: str) -> str | None:
    """On Windows, return the UNC path if *path* is or resolves to a UNC share; else None.

    Handles both explicit UNC paths (\\\\server\\share\\...) and mapped drive
    letters (Z:\\...) backed by a network share.
    Uses Path.resolve() — same pattern as LocalBackend — to expand drive letters
    to their real UNC target before checking.
    """
    if sys.platform != "win32":
        return None
    _log.debug("_resolve_to_unc: incoming path %r", path)
    try:
        resolved = Path(path).resolve()
    except OSError:
        return None
    _log.debug("_resolve_to_unc: resolved to %r", resolved)
    if resolved.anchor.startswith("\\\\"):
        return str(resolved)
    # Mapped drive: ask Windows for the universal name via WNetGetUniversalNameW
    import ctypes

    UNIVERSAL_NAME_INFO_LEVEL = 1
    DRIVE_REMOTE = 4
    drive_root = resolved.anchor  # e.g. "Z:\\"
    if not drive_root:
        return None
    drive_type = ctypes.windll.kernel32.GetDriveTypeW(drive_root)
    _log.debug("_resolve_to_unc: drive %r has type %d (REMOTE=4)", drive_root, drive_type)
    if drive_type != DRIVE_REMOTE:
        return None
    buf = ctypes.create_unicode_buffer(1024)
    buf_size = ctypes.c_ulong(ctypes.sizeof(buf))
    if ctypes.windll.mpr.WNetGetUniversalNameW(
        drive_root, UNIVERSAL_NAME_INFO_LEVEL, buf, ctypes.byref(buf_size)
    ) != 0:
        return None

    class _UniversalNameInfo(ctypes.Structure):
        _fields_ = [("lpUniversalName", ctypes.c_wchar_p)]

    unc_root = _UniversalNameInfo.from_buffer(buf).lpUniversalName
    rel = str(resolved)[len(drive_root):]
    return f"{unc_root}\\{rel}" if rel else unc_root
```

#### c) `get_local_lance_index_path(library_name)` helper

```python
def get_local_lance_index_path(library_name: str) -> str | None:
    """Return a local NTFS index path for a library on Windows, else None.

    Falls back to ~/AppData/Local if LOCALAPPDATA is unset.
    """
    if sys.platform != "win32":
        return None
    local_app_data = os.environ.get("LOCALAPPDATA") or str(
        Path.home() / "AppData" / "Local"
    )
    safe_name = "".join(c if c.isalnum() or c in "-_" else "_" for c in library_name)
    return str(Path(local_app_data) / "ouestcharlie" / "indexes" / safe_name)
```

#### d) `_migrate()` backfill

```python
def _migrate(self) -> bool:
    migrated = False
    for b in self.libraries:
        if b.type == "local":
            b.type = "filesystem"
            migrated = True
        if b.lancedb_index_path is None and _resolve_to_unc(b.path) is not None:
            b.lancedb_index_path = get_local_lance_index_path(b.name)
            if b.lancedb_index_path:
                migrated = True
    return migrated
```

### 2. `ouestcharlie-woof/src/woof/server.py` — `add_library` tool

```python
lance_path = None
if _resolve_to_unc(path) is not None:
    lance_path = get_local_lance_index_path(name)
library = LibraryConfig(name=name, type=library_type, path=path,
                        lancedb_index_path=lance_path)
self.config.add_library(library)
result = {"name": name, "path": path, "type": library_type, "status": "added"}
if lance_path:
    result["lancedb_index_path"] = lance_path
return result
```

Import `_resolve_to_unc` and `get_local_lance_index_path` from `config`.

### 3. `ouestcharlie-py-toolkit` — `lance_index.py`

Merge `open_or_create` into `open` by adding `create_if_missing: bool = False` and
`index_path: Path | None = None`. Remove `open_or_create` entirely.

```python
@classmethod
async def open(
    cls,
    backend: Backend,
    table_name: str,
    *,
    create_if_missing: bool = False,
    index_path: Path | None = None,
) -> LanceIndex:
    uri = str(index_path) if index_path is not None else str(await backend.local_path(lance_index_path()))
    db = await lancedb.connect_async(uri)
    if table_name in (await db.list_tables()).tables:
        table = await db.open_table(table_name)
        await _migrate_table(table)
    elif create_if_missing:
        table = await db.create_table(table_name, schema=PHOTO_SCHEMA)
        try:
            schema = await table.schema()
            desc_type = schema.field("description").type if "description" in schema.names else None
            if desc_type is not None and desc_type != pa.null():
                await table.create_index("description", config=FTS(), replace=True)
        except Exception as exc:
            _log.debug("FTS index creation skipped: %s", exc)
    else:
        raise FileNotFoundError(f"LanceDB index not found at {uri!r}")
    return cls(table)
```

### 4. `ouestcharlie-py-toolkit` — `server.py` (`AgentBase`)

```python
@property
def lance_index_path_override(self) -> Path | None:
    raw = self.backend_config.get("lancedb_index_path")
    return Path(raw) if raw else None
```

### 5. Callers

**`ouestcharlie-whitebeard/src/whitebeard/indexer.py`**:

```python
lance_index = await LanceIndex.open(
    backend, PHOTO_TABLE_NAME,
    create_if_missing=True,
    index_path=self.lance_index_path_override,
)
```

**`ouestcharlie-wally/src/wally/searcher.py`**:

```python
lance_index = await LanceIndex.open(
    backend, PHOTO_TABLE_NAME,
    index_path=agent.lance_index_path_override,
)
```

---

## Tests

### py-toolkit — `tests/test_lance_index.py`

- `test_open_with_index_path_override`: pass `index_path=tmp_path / "custom"`,
  `create_if_missing=True`; assert index created there.
- `test_open_missing_raises_without_create`: call `open()` on absent index without
  `create_if_missing`; assert `FileNotFoundError`.

### Woof — `tests/test_config.py`

- `test_resolve_to_unc_explicit`: patch `sys.platform` to `"win32"` and `Path.resolve` to return
  a UNC path; assert result starts with `\\`.
- `test_resolve_to_unc_mapped_drive`: patch `sys.platform`, `GetDriveTypeW` → 4,
  `WNetGetUniversalNameW` fills buffer; assert correct UNC path returned.
- `test_resolve_to_unc_local_drive`: patch `sys.platform`, `GetDriveTypeW` → 3; assert `None`.
- `test_resolve_to_unc_non_windows`: `sys.platform = "darwin"`; assert `None` with no ctypes call.

---

## Verification

1. Run `.venv/bin/pytest tests/ -v` in both `ouestcharlie-py-toolkit` and `ouestcharlie-woof`.
2. On Windows: add a library with a UNC path; confirm `config.json` contains `lancedb_index_path`
   and the index is created locally without `object_store.rs` errors.
3. On macOS/Linux: add a library with a local path; confirm `lancedb_index_path` is absent and the
   index lands in `.ouestcharlie/index.lance/` inside the library root.
