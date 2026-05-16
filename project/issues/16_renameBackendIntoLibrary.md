# Plan: Rename "backend" → "library" in Woof

#status:done

## Context

"Backend" is used throughout Woof's config, MCP tools, and Python API to mean both "a storage location" and "a photo collection". Users who interact with these MCP tools (via Claude Desktop or other assistants) encounter `add_backend`, `list_backends`, `backend_name` — technical storage jargon that conflicts with the user-facing concept of a "library" already established in HLR.md. This refactoring renames all user-visible and internal uses of "backend" → "library" while ensuring existing `config.json` files are auto-migrated on first load.

---

## Scope

### In-scope (ouestcharlie-woof)
- `config.py`: class renames, JSON key migration
- `server.py`: MCP tool renames and parameter renames
- `agent_client.py`: internal parameter renames
- `tests/`: update all references

### Cross-repo (deferred — separate issue)
`WOOF_BACKEND_CONFIG` (passed from Woof to Wally/Whitebeard subprocesses) is **not renamed** in this refactoring. It is an internal implementation detail invisible to users, and renaming it requires coordinated changes in `ouestcharlie-wally` and `ouestcharlie-whitebeard`.

---

## Implementation

### 1. `src/woof/config.py`

**Class renames:**
- `BackendConfig` → `LibraryConfig`
- `WoofConfig.backends: list[BackendConfig]` → `WoofConfig.libraries: list[LibraryConfig]`
- `WoofConfig.get_backend(name)` → `WoofConfig.get_library(name)`
- `WoofConfig.add_backend(backend)` → `WoofConfig.add_library(library)`

**JSON load migration** — in `load()`, read from `"backends"` key if `"libraries"` is absent:
```python
raw = json.loads(config_file.read_text())
library_data = raw.get("libraries") or raw.get("backends", [])
libraries = [LibraryConfig(**b) for b in library_data]
config = cls(libraries=libraries, config_dir=config_dir)
if "backends" in raw and "libraries" not in raw:
    config.save()  # re-save with "libraries" key
config._migrate()
return config
```

**`save()`** — write `"libraries"` key:
```python
data: dict = {"libraries": [asdict(b) for b in self.libraries]}
```

**`to_agent_env()`** — keep `WOOF_BACKEND_CONFIG` name (env var rename deferred).

---

### 2. `src/woof/server.py`

| Old tool name | New tool name |
|----------|----------|
| `add_backend(name, path, backend_type)` | `add_library(name, path, library_type)` |
| `list_backends()` | `list_libraries()` |
| `index_backend(backend_name, ...)` | `index_library(library_name, ...)` |
| `search_photos(backend_name, ...)` | `search_photos(library_name, ...)` |
| `list_search_fields(backend_name)` | `list_search_fields(library_name)` |

Internal: `_backend_fields` → `_library_fields`, `_require_backend` → `_require_library`, `_get_fields(backend)` → `_get_fields(library)`.

All `config.get_backend()` → `config.get_library()`, `config.add_backend()` → `config.add_library()`, `config.backends` → `config.libraries`.

Return payloads: any `"backends"` key → `"libraries"`.

---

### 3. `src/woof/agent_client.py`

Rename parameters `backend` → `library`, `backend_name` → `library_name` throughout. Keep `WOOF_BACKEND_CONFIG` string unchanged.

---

### 4. `tests/test_config.py`

- Import `LibraryConfig` instead of `BackendConfig`
- Rename test functions accordingly
- Add migration test for `"backends"` → `"libraries"` key
- Update fixture JSON to use `"libraries"` key where appropriate

---

### 5. `tests/test_server.py`

Update references to old tool names and parameter names.

---

## Migration Safety

| Scenario | Outcome |
|----------|---------|
| Fresh install (no config.json) | Works as before — starts empty |
| Existing config with `"backends"` key | Auto-migrated to `"libraries"` on first load; persisted immediately |
| Existing config already with `"libraries"` key | No migration needed |
| Existing config with `"local"` type | Existing `_migrate()` still runs after key migration |

---

## Verification

1. Run test suite: `.venv/Scripts/python -m pytest tests/ -v`
2. Manually test config migration: write a `config.json` with `"backends"` key, start Woof, verify `config.json` now has `"libraries"` key
3. Verify MCP tool names: `add_library`, `list_libraries`, `index_library`, `search_photos`, `list_search_fields`
4. End-to-end: register a library, index it, search photos
