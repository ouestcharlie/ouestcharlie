# OEC-31: Fix LanceDB connection failure on Windows UNC (Samba) paths

## Context

A tester running on Windows with a NAS mounted via Samba (UNC path `\\server\share`) hits this
error when the app tries to open or create the LanceDB index:

> Unable to convert URL "file:///nas/photos/.ouestcharlie/index.lance" to file system path.
> Error is in lancedb's object_store.rs:786

**Root cause:** `lance_index.py` builds the LanceDB URI as:

```python
uri = str(await backend.local_path(lance_index_path()))
```

On Windows with a UNC root, `backend.local_path()` returns a `Path` whose `str()` is
`\\server\share\.ouestcharlie\index.lance`. LanceDB's Rust internals convert this to a `file://`
URI internally, but produce `file:///server/share/...` (three slashes, server name treated as a
path component) instead of the RFC-correct `file://server/share/...` (two slashes, server name as
URI authority). The `object_store` crate rejects the malformed URI.

**Fix:** Use `Path.as_uri()` instead of `str()`. Python's `pathlib` generates the correct URI on
every platform:
- POSIX absolute path `/foo/bar` → `file:///foo/bar`
- Windows absolute path `C:\foo\bar` → `file:///C:/foo/bar`
- Windows UNC path `\\server\share\foo` → `file://server/share/foo` ✓

This bypasses LanceDB's internal (buggy) path-to-URI conversion entirely.

---

## Changes

### 1. URI construction in `lance_index.py`

**File:** `ouestcharlie-py-toolkit/src/ouestcharlie_toolkit/lance_index.py` (lines 224 and 248)

```python
# Before
uri = str(await backend.local_path(lance_index_path()))

# After
uri = (await backend.local_path(lance_index_path())).as_uri()
```

Both `open_or_create()` and `open()` have the same pattern; both must be updated.
`backend.local_path()` always returns a fully resolved absolute `Path`, so `.as_uri()` will never
raise `ValueError`.

### 2. Tests

**File:** `ouestcharlie-py-toolkit/tests/test_lance_index.py`

Add a new section **"URI construction"** with one test that patches `lancedb.connect_async` to
capture the URI argument and assert it is a proper `file://` URI:

```python
from unittest.mock import patch

@pytest.mark.asyncio
async def test_open_or_create_passes_file_uri_to_lancedb(tmp_path: Path):
    captured = {}
    real_connect = lancedb.connect_async

    async def fake_connect(uri, **kw):
        captured["uri"] = uri
        return await real_connect(uri, **kw)

    with patch("ouestcharlie_toolkit.lance_index.lancedb.connect_async", side_effect=fake_connect):
        await LanceIndex.open_or_create(LocalBackend(root=tmp_path), PHOTO_TABLE_NAME)

    assert captured["uri"].startswith("file://"), f"Expected file:// URI, got: {captured['uri']!r}"
```

---

## Verification

- Run tests: `.venv/bin/pytest tests/ -v` in `ouestcharlie-py-toolkit/` — all pass including the
  new test
- On a Windows machine with a Samba-mounted share, confirm the index opens/creates without the
  `object_store.rs` error
- On macOS/Linux, confirm no regression (POSIX paths produce `file:///…` either way)
