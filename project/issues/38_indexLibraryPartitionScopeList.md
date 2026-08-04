# OEC-38: `index_library` — multi-folder `partition_scope` (list)

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
call site.

**Scope note:** `partition_scope` entries are leaf folders — same
non-recursive semantics as today's `partition` arg (direct children only,
via Whitebeard's `index_partition`). No new recursive subtree-walk mode is
introduced by this change; the existing full-tree `index_library` path
(used when `partition_scope` is empty) is unaffected.

---

## Changes

### 1. `index_library` MCP tool

**File:** `woof/src/woof/mcp_server.py` (~lines 167–242)

Rename `partition: str = ""` to `partition_scope: list[str] = []`.

- Empty list → unchanged behavior: delegate to Whitebeard's `index_library`
  (full-tree walk).
- Non-empty list → call Whitebeard's `index_partition` once per entry
  (sequentially, within the existing background task), aggregating results
  into a single response instead of the current single-partition dict.
- Update the docstring to describe the list semantics and that each entry
  is indexed independently (direct children only, no descendants).
- Update the returned dict: replace `"partition": partition` with
  `"partition_scope": partition_scope`.

### 2. Indexing session manager

**File:** `woof/src/woof/indexing_session_manager.py`

`start(library_name: str, partition: str)` → `start(library_name: str,
partition_scope: list[str])`. Update the stored session dict key from
`"partition"` to `"partition_scope"`.

### 3. Gallery frontend

**Files:** `woof/gallery/src/components/IndexingProgress.svelte`,
`woof/gallery/src/lib/api.svelte.js`

Update references to the session's `partition` field to `partition_scope`.
Display logic:
- Empty list → "Indexing full library" (today's full-library wording).
- Non-empty list → "Indexing N partitions in `<library_name>`" (count, not
  the full folder list, to stay readable for larger scopes).

### 4. Tests

**File:** `woof/tests/test_mcp_server.py`

- Update `test_index_library_with_partition` (and related) to pass/assert
  `partition_scope` as a list.
- Add a case covering multiple entries: verify Whitebeard's
  `index_partition` is invoked once per scope entry and results are
  aggregated.
- Add a case for an empty list falling back to the full-tree
  `index_library` call, unchanged from current behavior.

**File:** `woof/tests/test_indexing_session_manager.py`

Update `start()` calls/assertions for the renamed `partition_scope` list
field.

**Files:** `woof/gallery/src/components/IndexingProgress.test.js`,
`woof/gallery/src/lib/api.svelte.test.js`

Update fixtures using `partition` to `partition_scope`.

### 5. Documentation

Update `controller_api.json` and any HLD/LLD sections documenting the
`index_library` MCP tool signature to reflect `partition_scope: list[str]`.

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
