# Python Toolkit Skeleton — Complete ✅

The Python toolkit code skeleton has been successfully created. All modules, classes, type signatures, and interfaces are in place.

## Created Files

### Package Configuration
- ✅ [pyproject.toml](pyproject.toml) — Package metadata, dependencies, build config

### Core Modules
- ✅ [src/ouestcharlie/__init__.py](src/ouestcharlie/__init__.py) — Package exports
- ✅ [src/ouestcharlie/schema.py](src/ouestcharlie/schema.py) — Data models, serialization, constants
- ✅ [src/ouestcharlie/backend.py](src/ouestcharlie/backend.py) — Backend protocol
- ✅ [src/ouestcharlie/backends/local.py](src/ouestcharlie/backends/local.py) — Local filesystem backend
- ✅ [src/ouestcharlie/manifest.py](src/ouestcharlie/manifest.py) — ManifestStore
- ✅ [src/ouestcharlie/xmp.py](src/ouestcharlie/xmp.py) — XmpStore
- ✅ [src/ouestcharlie/progress.py](src/ouestcharlie/progress.py) — ProgressReporter
- ✅ [src/ouestcharlie/server.py](src/ouestcharlie/server.py) — AgentBase

### Documentation
- ✅ [README.md](README.md) — Usage guide and examples
- ✅ [py_toolkit_LLD.md](py_toolkit_LLD.md) — Low-level design document

## What's Implemented

### Fully Functional

**Data Models** ([schema.py](src/ouestcharlie/schema.py)):
- `PhotoEntry`, `PartitionSummary`, `LeafManifest`, `ParentManifest`, `XmpSidecar`
- Serialization/deserialization with unknown field preservation
- `VersionToken`, `FileInfo`, exceptions

**Local Backend** ([backends/local.py](src/ouestcharlie/backends/local.py)):
- Async file I/O using `pathlib` and `asyncio.run_in_executor`
- Atomic write-then-rename for `write_conditional`
- Version token based on `st_mtime_ns`
- File listing with glob patterns

**ManifestStore** ([manifest.py](src/ouestcharlie/manifest.py)):
- `read_leaf`, `write_leaf`, `create_leaf` with version tokens
- `read_modify_write_leaf` with retry logic
- Same for parent manifests
- `rebuild_parent` stub (needs bloom filter merging)

**XmpStore** ([xmp.py](src/ouestcharlie/xmp.py)):
- `read`, `write`, `create` with version tokens
- `read_modify_write` with retry logic
- `compute_content_hash` (SHA-256) — fully functional
- `xmp_path_for` helper

**ProgressReporter** ([progress.py](src/ouestcharlie/progress.py)):
- Rate-limited progress notifications (500ms min interval)
- `advance(n, message)` and `finish(message)` methods
- Wraps MCP `Context.report_progress`

**AgentBase** ([server.py](src/ouestcharlie/server.py)):
- Parses `WOOF_BACKEND_CONFIG` and `WOOF_AGENT_TOKEN` from environment
- Initializes backend, manifest store, and XMP store
- Provides `progress(total)` factory
- Provides `check_cancelled()` for cooperative cancellation
- Provides `per_photo(photo, partition)` error isolation context manager
- Wraps `FastMCP` for MCP server lifecycle

### Stub Implementations (TODO)

These functions have correct signatures and docstrings but raise `NotImplementedError`:

1. **XMP Parsing** ([xmp.py](src/ouestcharlie/xmp.py)):
   - `parse_xmp(xml: str) -> XmpSidecar` — needs pyexiv2
   - `serialize_xmp(sidecar: XmpSidecar) -> str` — needs pyexiv2
   - `extract_exif(backend, photo_path) -> XmpSidecar` — needs pyexiv2

2. **Bloom Filters** ([manifest.py](src/ouestcharlie/manifest.py)):
   - `rebuild_parent` — needs bloom filter merging logic
   - `_recompute_summary` — needs bloom filter computation

## How to Complete the Stubs

### XMP Operations

Use `pyexiv2` library (wraps Exiv2):

```python
import pyexiv2

def parse_xmp(xml: str) -> XmpSidecar:
    # Use pyexiv2.ImageMetadata.from_buffer() to parse XMP
    # Extract fields: ouestcharlie:*, exif:*, dc:subject
    # Preserve _raw_xml for round-tripping
    ...

def serialize_xmp(sidecar: XmpSidecar) -> str:
    # Parse _raw_xml as baseline
    # Update known fields using pyexiv2
    # Return serialized XML
    ...
```

### Bloom Filters

Use a simple bloom filter library or implement manually:

```python
from pybloom_live import BloomFilter

def _compute_bloom(items: list[str]) -> bytes:
    bf = BloomFilter(capacity=1000, error_rate=0.01)
    for item in items:
        bf.add(item)
    return bf.bitarray.tobytes()

def _merge_blooms(blooms: list[bytes]) -> bytes:
    # Union of bloom filters = bitwise OR
    ...
```

## Installation & Testing

### Install Dependencies

```bash
cd agent/py_toolkit
pip install -e .
```

**Note:** This requires the `mcp`, `pyexiv2`, `Pillow`, and `rawpy` packages to be available.

### Run Tests

```bash
# Unit tests (once pytest is set up)
pytest

# Type checking
mypy src/
```

## Next Steps

1. **Implement XMP stubs** — Use pyexiv2 for `parse_xmp`, `serialize_xmp`, `extract_exif`
2. **Implement bloom filters** — Add bloom filter library and implement merging logic
3. **Add unit tests** — Test each module in isolation
4. **Build first agent** — Create a housekeeping agent using this toolkit
5. **Add cloud backends** — Implement S3, GCS, ADLS Gen2 backends

## Usage Example

Once dependencies are installed, agents can be built like this:

```python
from ouestcharlie import AgentBase

class HousekeepingAgent(AgentBase):
    def __init__(self):
        super().__init__(name="ouestcharlie-housekeeping", version="1.0.0")

        @self.mcp.tool()
        async def rebuild_partition(backend: str, partition: str):
            progress = self.progress(total=100)
            # Use self.manifest_store, self.xmp_store, self.backend
            await progress.advance(message="Processing...")
            return {"photosProcessed": 100, "errors": 0}

if __name__ == "__main__":
    agent = HousekeepingAgent()
    agent.run()  # Runs on stdio
```

## Summary

✅ **Skeleton is complete and ready for implementation**

All interfaces, protocols, type signatures, and data models are in place. The toolkit provides a clean, type-safe foundation for building OuEstCharlie agents. Agents can now be developed against this API, with stub functions filled in as needed.

---

**Created:** 2026-02-20
**Status:** Skeleton complete, stubs documented, ready for implementation
