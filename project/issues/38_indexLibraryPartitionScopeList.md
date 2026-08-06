# OEC-38: `index_library` — multi-folder `partition_scope` (list)

#status:done

## Context

Woof's `index_library` MCP tool currently accepts a single optional
`partition: str = ""` argument. When set, it delegates to Whitebeard's
`index_partition` tool, which indexes only the **direct children** of that
one folder (subdirectories are explicitly not walked — see
`test_index_ignores_subdirectory_photos` in whitebeard). When empty, it
delegates to Whitebeard's `index_library`, which BFS-walks the *entire*
library tree from the root.

Users often want to (re)index a handful of specific leaf folders in one call
(e.g. after importing photos into several date folders) without triggering a
full-library walk. Today that requires one `index_library` call per folder.

This issue extends the argument to a list and renames it to
`partition_scope` to remove ambiguity with Whitebeard's own `partition`
naming (a single folder) and to make the list semantics explicit at the
call site. The list is forwarded to Whitebeard in a single MCP call — no
looping at the Woof layer — via a new Whitebeard tool that indexes the
whole scope server-side.

**Scope note:** `partition_scope` entries are leaf folders — same
non-recursive semantics as today's `partition` arg (direct children only).
No new recursive subtree-walk mode is introduced by this change; the
existing full-tree `index_library` path (used when `partition_scope` is
empty) is unaffected.

---

## Changes

### 1. Whitebeard: new `index_partition_scope` tool, `index_partition` tool removed

**Files:** `whitebeard/src/whitebeard/indexer.py`,
`whitebeard/src/whitebeard/agent.py`

Add `index_partition_scope(backend, partition_scope: list[str], ...) ->
LibraryIndexResult` to `indexer.py`, modeled on `index_library`'s
concurrent-fan-out loop but iterating over the given `partition_scope`
list instead of a BFS directory walk, using a single shared `LanceIndex`
(same MVCC-conflict-avoidance rationale as `index_library`). Unlike
`index_library`, it does **not** prune stale partitions — only the given
entries are touched, so folders outside the scope are left alone.

Register it as a new MCP tool `index_partition_scope` in `agent.py`,
mirroring `index_library_tool`'s progress-reporting and result-shaping
pattern. Writes the thin `summary.json` marker itself when done, same as
the tool it replaces.

Remove the standalone `index_partition` MCP tool — `index_partition_scope`
with a single-element list covers the same case. The underlying
`indexer.index_partition()` function is unaffected and stays in use
internally (by `index_library`'s per-leaf fan-out and by
`index_partition_scope`).

### 2. `index_library` MCP tool (Woof)

**File:** `woof/src/woof/mcp_server.py`

Rename `partition: str = ""` to `partition_scope: list[str] | None = None`.

- Empty/None → unchanged behavior: delegate to Whitebeard's `index_library`
  (full-tree walk), single call as today.
- Non-empty → delegate to Whitebeard's new `index_partition_scope` tool in
  one call, passing the whole list through as the `partition_scope` arg.
- Update the docstring to describe the list semantics and that each entry
  is indexed independently (direct children only, no descendants).
- Update the returned dict: replace `"partition": partition` with
  `"partition_scope": partition_scope`.

### 3. Indexing session manager

**File:** `woof/src/woof/indexing_session_manager.py`

`start(library_name: str, partition: str)` → `start(library_name: str,
partition_scope: list[str])`. Update the stored session dict key from
`"partition"` to `"partition_scope"`.

### 4. Gallery frontend

**Files:** `woof/gallery/src/components/IndexingProgress.svelte`,
`woof/gallery/src/lib/api.svelte.js`

Update references to the session's `partition` field to `partition_scope`.
Display logic:
- Empty list → "Indexing full library" (today's full-library wording).
- Non-empty list → "Indexing N partitions in `<library_name>`" (count, not
  the full folder list, to stay readable for larger scopes).

### 5. Tests

**File:** `whitebeard/tests/test_indexer.py`

Add coverage for `index_partition_scope`: indexes only the listed
partitions, leaves out-of-scope partitions untouched (no pruning), and
aggregates per-partition results like `index_library` does.

**File:** `woof/tests/test_mcp_server.py`

- Update `test_index_library_with_partition` (and related) to pass/assert
  `partition_scope` as a list.
- Add a case covering a non-empty list: verify Whitebeard's
  `index_partition_scope` is called once with the full list forwarded.
- Add a case for an empty list falling back to the full-tree
  `index_library` call, unchanged from current behavior.

**File:** `woof/tests/test_indexing_session_manager.py`

Update `start()` calls/assertions for the renamed `partition_scope` list
field.

**Files:** `woof/gallery/src/components/IndexingProgress.test.js`,
`woof/gallery/src/App.test.js`

Update fixtures using `partition` to `partitionScope`.

### 6. Documentation

`controller_api.json` does not exist in this repo and no HLD/LLD section
documents `index_library`'s signature — nothing to update there.

---

## Verification

- `.venv/bin/pytest tests/ -v` in `ouestcharlie-woof` — all `index_library`
  and session-manager tests pass with the new `partition_scope` list arg.
- `cd gallery && npm test` — updated component/API tests pass.
- Manual: call `index_library` with `partition_scope: ["2024/2024-07",
  "2024/2024-08"]` via MCP inspector or Claude Desktop; confirm both
  folders are indexed and the gallery progress view reflects the scope.
- Manual: call `index_library` with `partition_scope: []` (or omitted);
  confirm behavior is unchanged (full-library walk).
