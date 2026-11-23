# Whitebeard: Photo library indexer

Whitebeard is the **indexing agent** for OuEstCharlie. It operates in **index mode**:
scan an existing local photo library in place (no files moved), create XMP sidecars
with `ouestcharlie:` fields, and write leaf manifests.

> **More about OuEstCharlie on the [OuEstCharlie Blog](https://ouestcharlie.github.io)**

MCP tools: `index_library` and `index_partition_scope`, both incremental by default (`force_full_index=False`).

## Project Layout

```
src/whitebeard/
  indexer.py    — core logic (no MCP dependency, independently testable)
  agent.py      — WhitebeardAgent(AgentBase) registering MCP tools
  __main__.py   — entry point: python -m whitebeard
tests/
  test_indexer.py
```

## Installation

### From PyPI (recommended)

```bash
pip install ouestcharlie-whitebeard
```

System prerequisites:
- **macOS**: `brew install inih brotli gettext` (required by pyexiv2 at runtime)
- **Linux/Windows**: no extra steps

### From source (development)

This package is part of the [ouestcharlie uv workspace](https://github.com/ouestcharlie/ouestcharlie): py-toolkit, Whitebeard and Wally share one `uv.lock` and one `.venv` at the repo root.

```bash
git clone https://github.com/ouestcharlie/ouestcharlie.git
cd ouestcharlie
uv sync --all-packages   # the three packages (editable) and the dev tools
```


## Running Tests

From this package folder (`packages/whitebeard`), with the workspace venv. Not from the repo root: the workspace's three `tests/` packages share a name.

```bash
../../.venv/bin/python -m pytest tests/ -v
```

## Incremental vs Force Indexing

By default, both `index_partition_scope` and `index_library` run in **incremental mode**: photos already present in the index are carried over without re-processing. Only photos missing from the manifest are indexed.

To re-process all photos regardless of their manifest state, pass `force_full_index=True`. To also regenerate XMP sidecars specifically, add `force_extract_exif=True`.

Photos deleted from disk are automatically removed from the index on the next run, in both incremental and full-index mode.

## MCP Inspector

Use `mcp dev` from this package folder (`packages/whitebeard`) with a backend config pointing at a local photo folder:

```bash
WOOF_BACKEND_CONFIG='{"type":"filesystem","root":"/path/to/photos"}' \
    ../../.venv/bin/mcp dev src/whitebeard/__main__.py
```

> **Note:** The default MCP Inspector timeout is too low for full-library indexing runs. Increase it in the Inspector settings before calling `index_library` or `index_partition_scope`.

## Context

| Repository | Purpose |
|------------|---------|
| [ouestcharlie](https://github.com/ouestcharlie/ouestcharlie) | Architecture docs, HLR/HLD, and the agent packages below |
| [ouestcharlie/packages/py-toolkit](https://github.com/ouestcharlie/ouestcharlie/tree/master/packages/py-toolkit) | Python toolkit for agents |
| [**ouestcharlie/packages/whitebeard** *(this package)*](https://github.com/ouestcharlie/ouestcharlie/tree/master/packages/whitebeard) | Indexing agent |
| [ouestcharlie/packages/wally](https://github.com/ouestcharlie/ouestcharlie/tree/master/packages/wally) | Search/consumption agent |
| [ouestcharlie-woof](https://github.com/ouestcharlie/ouestcharlie-woof/) | Woof controller |