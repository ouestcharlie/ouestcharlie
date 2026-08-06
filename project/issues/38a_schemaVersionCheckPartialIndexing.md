# OEC-38a: schema-version handling for partial indexing

#status:done

## Context

OEC-38 (`38_indexLibraryPartitionScopeList.md`) added Whitebeard's
`index_partition_scope` tool. Its implementation unconditionally overwrites
`summary.json` with the current `SCHEMA_VERSION` at the end of every run
(`whitebeard/src/whitebeard/indexer.py:496-500`):

```python
await manifest_store.write_full_summary(
    RootSummary(schema_version=SCHEMA_VERSION, last_indexed_at=datetime.now(UTC))
)
```

This is wrong: `summary.json`'s `schema_version` is a whole-library invariant
— "was this library fully (re)indexed under schema N" (see `RootSummary`
docstring in `ouestcharlie-py-toolkit/src/ouestcharlie_toolkit/schema.py:190-203`
and Wally's LLD, `wally_LLD.md:148`). A partial/scoped indexing run only
touches a handful of leaf folders, not the whole tree, so it must not claim
"library is fully indexed under version N" by stamping the marker. If the
on-disk summary is stale (schema upgrade happened) or missing (library never
fully indexed), scoped indexing should refuse to run rather than silently
paper over it — same posture Wally already takes at query time
(`wally/src/wally/searcher.py:185-208`, `_verify_index_ready`).

`index_partition` (the single-partition primitive used by both `index_library`
and `index_partition_scope`) already never touches `summary.json` — no change
needed there.

## Changes

Two distinct mismatch cases must be told apart, for **both** entry points:

- **On-disk version `<` software's `SCHEMA_VERSION`** (library indexed by an
  older Whitebeard): the software can read it, so a full reindex can upgrade
  it. `index_library` already does this (forces `force_full_index = True`,
  lines 327-339) — this behavior is unchanged. `index_partition_scope` must
  instead **refuse** — it can't perform a partial "upgrade" — and tell the
  caller to run a full index.
- **On-disk version `>` software's `SCHEMA_VERSION`** (library was indexed by
  a newer Whitebeard than the one currently running — e.g. a downgrade or a
  mixed-version deployment): the running software does not understand this
  schema. Neither a full nor a partial index run may proceed — writing under
  an old schema over a newer one would corrupt the index. Today
  `index_library` does not handle this case at all; this must be added.

### 1. `whitebeard/src/whitebeard/indexer.py` — `index_library`

Add the `>` case alongside the existing `<` case (which keeps its current
auto-force-full-reindex behavior):

```python
try:
    existing_summary, _ = await manifest_store.read_summary()
    if existing_summary.schema_version > SCHEMA_VERSION:
        raise ValueError(
            f"Library index schema version {existing_summary.schema_version} is newer "
            f"than this software supports ({SCHEMA_VERSION}). Upgrade Whitebeard before "
            f"indexing this library."
        )
    if existing_summary.schema_version < SCHEMA_VERSION:
        _log.info(
            "index_library — schema version %d < %d, forcing full reindex",
            existing_summary.schema_version,
            SCHEMA_VERSION,
        )
        force_full_index = True
except FileNotFoundError:
    pass  # No existing index — first run, nothing to upgrade.
except Exception as exc:
    _log.warning("index_library — could not read summary.json for version check: %s", exc)
```

The `raise ValueError(...)` must **not** be swallowed by the trailing
`except Exception as exc: _log.warning(...)` clause.

### 2. `whitebeard/src/whitebeard/indexer.py` — `index_partition_scope`

Replace the tail write (lines 496-500) with a **check performed up front**,
before any partition work runs (fail fast — right after
`manifest_store = ManifestStore(backend)`, before opening `LanceIndex`):

```python
try:
    existing_summary, _ = await manifest_store.read_summary()
except FileNotFoundError as err:
    raise ValueError(
        "Library index not found. Run a full index before indexing a partition scope."
    ) from err

if existing_summary.schema_version > SCHEMA_VERSION:
    raise ValueError(
        f"Library index schema version {existing_summary.schema_version} is newer "
        f"than this software supports ({SCHEMA_VERSION}). Upgrade Whitebeard before "
        f"indexing a partition scope."
    )
if existing_summary.schema_version < SCHEMA_VERSION:
    raise ValueError(
        f"Library index schema version {existing_summary.schema_version} is older "
        f"than the current version ({SCHEMA_VERSION}). Run a full index to upgrade "
        f"before indexing a partition scope."
    )
```

Remove the tail `write_full_summary(...)` call entirely — `summary.json` is
left untouched by scoped indexing in all cases (match, too old, too new).

Update the docstring to state that `index_partition_scope` requires an
existing, current-schema `summary.json` (i.e. a prior full `index_library`
run) and does not itself update the version marker.

### 3. `whitebeard/src/whitebeard/agent.py`

No change needed — the `index_partition_scope` tool wrapper already logs and
re-raises any exception, so the new `ValueError` propagates to the MCP
caller with a clear message, same as `index_library`'s errors do today.

### 4. Tests — `whitebeard/tests/test_indexer.py`

For `index_partition_scope`:

- Update/replace `test_index_partition_scope_writes_thin_summary`: invert to
  assert `summary.json` is **unchanged** after a scoped-index run against a
  valid, current-schema summary.
- Add `test_index_partition_scope_raises_when_summary_missing`.
- Add `test_index_partition_scope_raises_when_schema_older`.
- Add `test_index_partition_scope_raises_when_schema_newer`.

For `index_library`:

- Add `test_index_library_raises_when_schema_newer`.
- Confirm `test_index_library_forces_full_reindex_on_schema_upgrade` and
  `test_index_library_no_forced_reindex_when_schema_current` still pass
  unchanged.

## Verification

- `.venv/bin/pytest tests/test_indexer.py -v` in `ouestcharlie-whitebeard`.
- `.venv/bin/pytest tests/ -v` in `ouestcharlie-whitebeard` — full suite green.
- Manual: on a backend with no prior `index_library` run, call
  `index_partition_scope` — confirm a clear "run a full index first" error
  and no `summary.json` created.
- Manual: hand-edit a valid `summary.json`'s `schemaVersion` to
  `SCHEMA_VERSION + 1` and confirm both `index_library` and
  `index_partition_scope` refuse to run, leaving the library untouched.
- Manual: on a backend with a current, valid `summary.json`, run a scoped
  index and confirm `summary.json` is byte-for-byte unchanged afterward.
