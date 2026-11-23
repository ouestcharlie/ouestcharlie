# OuEstCharlie — Agent Working Rules

Rules for AI coding agents working in this repo. Claude Code reads them through the root
`CLAUDE.md`, which imports this file.

## Project Context

OuEstCharlie is a decentralized, storage-agnostic photo management system with:
- **Woof**: Central controller (UI backend + MCP client coordinator), in the `ouestcharlie-woof` repo
- **Agents**: Stateless workers (MCP servers) for housekeeping, enrichment, ingestion
- **No central database**: Metadata in XMP sidecars + hierarchical manifests

This repo holds the design docs and the Python agents as one uv workspace:

| Package | Folder | Role |
|---|---|---|
| `ouestcharlie-py-toolkit` | `packages/py-toolkit` | Shared library for agents |
| `ouestcharlie-whitebeard` | `packages/whitebeard` | Indexing agent |
| `ouestcharlie-wally` | `packages/wally` | Search / consumption agent |

## Architecture Understanding Required

Before making changes, ALWAYS:
1. Check relevant design documents, all in [design/](design/):
   - [HLR.md](design/HLR.md) — High-level requirements
   - [HLD.md](design/HLD.md) — System design & data model
   - [HLD_rationale.md](design/HLD_rationale.md) — Design decisions & alternatives
   - Component LLDs: [py_toolkit_LLD.md](design/py_toolkit_LLD.md), [whitebeard_LLD.md](design/whitebeard_LLD.md), [wally_LLD.md](design/wally_LLD.md); Woof's are in the Woof repo
2. Understand the MCP interface: tool schemas are defined in each agent's tool registrations and discoverable at runtime via `tools/list`
3. Review [Version1_vision.md](project/Version1_vision.md) for V1 scope boundaries

## Code Guidelines

### General
- **Respect the documentation hierarchy**: Requirements → Design → Implementation
- **Don't bypass existing architecture**: Changes should align with HLD/LLD
- **Keep agents stateless**: No persistent state in agent code
- **Storage-agnostic**: Never hardcode assumptions about storage backend
- Write all documentation, comments, and user-facing text in American English (e.g., "color" not "colour", "organize" not "organise")

### Python workspace

One `uv.lock` and one `.venv` at the repo root; each package keeps its own `pyproject.toml`.

- **Setup**: `uv sync --all-packages` at the root.
- **Tests**: per package, from its folder. Never from the repo root: the three `tests/`
  packages share a name and can't be collected in one session. Never use `python`,
  `python3`, or `uv run pytest`: use the workspace venv.
  ```bash
  cd packages/<name> && ../../.venv/bin/pytest tests/ -v
  make test REPOS=100         # all three packages
  ```
- **Type check**: from the root, with the package's config (mypy reads the config of the
  folder it runs in):
  ```bash
  .venv/bin/mypy --config-file packages/<name>/pyproject.toml packages/<name>/src
  ```
- **Lint**: ruff is a dev dependency of the workspace, pinned in the root `pyproject.toml`
  (locked in `uv.lock`) — the same version the pre-commit hook runs. Use the venv's copy,
  never `uvx ruff` or a global `ruff` (unpinned version, results may differ from the hook):
  ```bash
  .venv/bin/ruff check .
  .venv/bin/ruff format --check .
  ```
  Shared ruff settings are in the root `pyproject.toml`; each package's `[tool.ruff]`
  extends them. To move ruff to a new minor version, change the range in the root dev group
  and reformat in the same PR.

### Python code style
- Use the `AgentBase` wrapper around FastMCP
- Implement optimistic concurrency for manifest/XMP writes
- **All imports at the top of the file** — never use lazy imports inside functions or methods.
- **Absolute imports only** (ruff `TID`): no relative imports.
- **SIM117 — always group `with` / `async with` statements** (ruff enforced). This applies
  to `with`, `async with`, and `patch()` context managers in tests:
  ```python
  # bad
  with foo() as a:
      with bar() as b:
          ...

  # good
  with (
      foo() as a,
      bar() as b,
  ):
      ...
  ```

### MCP tool handlers (agents)
- **Always log exceptions** in MCP tool handlers — FastMCP swallows unhandled errors silently, so without explicit logging they are invisible.
- Wrap `ctx.report_progress()` calls in `try/except` and log failures at DEBUG level. The MCP client may disconnect or time out while the tool is still running; a failed progress notification must never abort the operation.
- For long-running tools, the MCP Inspector timeout must be increased in its settings (the default is too low for full-library indexing or heavy queries).
- Keep the logic **pure async with no MCP dependency** (Whitebeard's `indexer.py`, Wally's `searcher.py`), easy to unit test; `agent.py` wraps it in `AgentBase` and registers it as MCP tools.

### Documentation
- **Update docs when design changes**: If you modify architecture, update corresponding HLD/LLD
- **Use established patterns**: Follow the existing LLR/LLD/rationale structure
- **Mark open questions**: Add them to the relevant spec in [project/issues](project/issues/) if uncertain
- **Avoid listing individual code files**: Don't enumerate specific implementation files in documentation - it's not maintainable. Instead, describe patterns, directories, or link to generated documentation
- **Document only what is non-obvious**: Don't document APIs or what code already makes clear by reading it. Only document constraints, architectural decisions, non-obvious invariants, and cross-cutting behavior not visible from a single file.
- **Don't reference issue numbers in code or docs**: Issue numbers (e.g. "OEC-39") are only valid at the time of their implementation and become stale afterwards. Explain the rationale directly instead of pointing to an issue.
- **Links**: relative paths within this repo, full GitHub URLs to other repos.

## Package Rules

### py-toolkit

- **No caller name-dropping.** py-toolkit is a library with its own interface; it does not know about its callers (Woof, Wally, Whitebeard, ...). Never write docstrings/comments like "used by Wally's `get_summary` tool" — that's a dependency pointing the wrong way, and it silently rots when the caller changes. Describe what the function does and its contract (inputs, outputs, invariants), not who currently calls it.
- **Python 3.13 ET restriction**: `ET.register_namespace()` rejects prefixes matching `ns\d+` — use `ext{counter}` as fallback.
- **`Backend.local_path()` is the backend's responsibility.** Callers (photo and video readers, thumbnail and preview renditions) call `backend.local_path(path)` and use the returned `Path` directly — they must not contain any logic about *how* the path is obtained (no tmpfile staging, no download code, no `if local is not None` branching). It is the backend's job to return a usable local path, whether that means resolving it on the local filesystem, returning a FUSE mount path, or in the future downloading to a tmp location. Keep callers ignorant of backend strategy.
- **image-proc protocol**: the JSON protocol to the image-proc Rust binary, and its versioning rules, are in the `ouestcharlie-imageproc` repo (see its `AGENTS.md`). After a protocol change there, raise py-toolkit's `ouestcharlie-imageproc~=` pin if needed.
- **pyexiv2** (2.x, LeoHsiao1 binding):
  - `convert_exif_to_xmp()` does **not** exist — use `read_exif()`.
  - `read_exif()` returns `dict[str, str]` with pyexiv2 key format: `Exif.Image.Make`, `Exif.Photo.DateTimeOriginal`, etc.
  - GPS values are DMS rational strings: `"48/1 52/1 1234/100"` → parse each part with `exif_rational_to_float()`; `parse_exif_gps()` does the full conversion to decimal degrees.

### Whitebeard (indexer)

- Index mode: photos stay in place; `.ouestcharlie/` subdirs are created alongside them.
- Partition = a folder relative to the backend root (e.g., `""` for root, `"Vacations/Italy 2023/"` for a subfolder).
- Only **direct children** of a partition are indexed — subdirectories are separate partitions.
- Existing XMP sidecars are reused unless `force_extract_exif=True`, which re-extracts EXIF and overwrites them. It is independent of `force_full_index` (re-process every photo instead of the incremental mode).
- `ouestcharlie:contentHash` is the BLAKE3 content hash (128 bits, base64url, 22 characters). `extract_exif()` always writes it, and adds it to existing sidecars that lack it (e.g. written by another tool).

### Wally (search)

- Wally is **read-only** — it never writes XMP sidecars, `summary.json` or the index.
- All queryable metadata is in the backend's LanceDB index, written by Whitebeard. Wally never reads XMP sidecars.
- A search first reads `summary.json` to check the index schema version, then runs a single SQL query against the LanceDB table.
- A missing `summary.json` (or LanceDB table) means an unindexed library: raise a `ValueError` with a clear "run a full index" message, not an unexpected error. An incompatible schema version is reported the same way.
- `date_taken` is stored as a naive datetime: strip the timezone from date inputs and filters before comparing (`.replace(tzinfo=None)`).

## Testing & Validation

- Target: 10K photos on local or mounted cloud drives
- Test against both local filesystem and cloud storage backends
- Validate MCP communication between Woof and agents
- Check XMP sidecar consistency

## Current Phase: Implementation

See the [project/](project/) folder for current status and open points.

## Commit Conventions

- Keep commits focused and atomic
- Reference design docs in commit messages when implementing from specs
- Use Co-Authored-By for AI-assisted changes

## Communication & Documentation

- **OuEstCharlie is cross-platform**: runs on macOS, Windows, and Linux. Never write as if it's macOS-only.
- **Woof is AI-assistant-agnostic**: compatible with any MCP-capable assistant (Claude Desktop, ChatGPT, Goose, etc.). Never write as if Claude Desktop is the only supported client.

## What NOT to Do

- ❌ Don't add a central database or stateful storage in Woof
- ❌ Don't create tight coupling between agents and storage backends
- ❌ Don't implement features outside V1 scope (check Version1_vision.md)
- ❌ Don't modify XMP/manifest schemas without updating HLD
- ❌ Don't add dependencies without considering cross-platform compatibility

## Questions or Uncertainty?

1. Check if it's documented in HLD/LLD
2. Review rationale documents for context
3. Look at open specs in [project/issues](project/issues/) for known gaps
4. Ask before making architectural changes
