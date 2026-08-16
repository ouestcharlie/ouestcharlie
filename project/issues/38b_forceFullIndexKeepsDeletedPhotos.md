# OEC-38b: `force_full_index=True` leaves deleted photos in the index

#status:done

## Context

`index_partition()` in `whitebeard/src/whitebeard/indexer.py` is the
single-partition primitive shared by `index_library` and
`index_partition_scope` (both introduced in OEC-38) — both pass
`force_full_index` straight through. In the default incremental path
(`force_full_index=False`), it correctly diffs existing LanceDB rows against
files on disk and deletes stale rows.

That diff-and-delete logic sits entirely inside `if not force_full_index:`.
When `force_full_index=True`, the existing-rows lookup is skipped, so
`deleted_filenames` stays `None` and the deletion block at the end of the
function never runs. `LanceIndex.upsert_partition()` uses
`merge_insert(...).when_matched_update_all().when_not_matched_insert_all()`
with no delete-unmatched clause, so it only adds/updates rows and never
removes ones absent from the current run's `photo_entries`. Net effect: a
photo deleted from disk before a full reindex leaves a permanently stale row
in the index, forever, regardless of how many times `force_full_index=True`
is run afterward. Both `index_library` and `index_partition_scope` inherit
this bug identically.

This contradicts existing documentation (LLD, README, and the MCP-exposed
tool docstrings in both Whitebeard and Woof), which describes deletion of
stale photos as unconditional, without any full-index caveat.

## Changes

### 1. `whitebeard/src/whitebeard/indexer.py` — `index_partition`

Move the existing-rows lookup and `deleted_filenames` computation outside the
`if not force_full_index:` guard so it always runs — it's a cheap read,
independent of whether extraction is skipped or forced:

```python
# Before
existing_by_filename: dict[str, str] = {}
deleted_filenames: set[str] | None = None
if not force_full_index:
    existing_by_filename: dict[str, str] = {}
    async for row in lance_index.get_partition_rows(
        partition, columns=["filename", "content_hash"]
    ):
        existing_by_filename[row["filename"]] = row["content_hash"]
    deleted_filenames = existing_by_filename.keys() - disk_filenames
    result.photos_deleted = len(deleted_filenames)
    if deleted_filenames:
        _log.info(...)

# After
existing_by_filename: dict[str, str] = {}
async for row in lance_index.get_partition_rows(
    partition, columns=["filename", "content_hash"]
):
    existing_by_filename[row["filename"]] = row["content_hash"]
deleted_filenames = existing_by_filename.keys() - disk_filenames
result.photos_deleted = len(deleted_filenames)
if deleted_filenames:
    _log.info(...)
```

The carry-over/skip decision (`if force_full_index or filename not in
existing_by_filename:`) is unaffected — `force_full_index` still forces
reprocessing regardless of `existing_by_filename` contents. The deletion call
at the end of the function needs no change — it already just checks
truthiness of `deleted_filenames`, now populated in both modes.

Update the function's docstring to state that deleted-photo detection and
removal happens unconditionally, not only in incremental mode.

### 2. Tests

**File:** `whitebeard/tests/test_indexer.py`

Add, adjacent to `test_incremental_removes_deleted_photos_from_manifest` and
`test_force_full_index_reprocesses_all_photos`:

```python
@pytest.mark.asyncio
async def test_force_full_index_removes_deleted_photos_from_index(tmpdir: Path) -> None:
    """force_full_index=True must also remove photos deleted from disk from the index."""
    (tmpdir / "keep.jpg").write_bytes(_unique_jpeg(0))
    (tmpdir / "delete.jpg").write_bytes(_unique_jpeg(1))
    backend = LocalBackend(root=tmpdir)

    await index_partition(backend, "")  # first run, both indexed

    (tmpdir / "delete.jpg").unlink()

    result = await index_partition(backend, "", force_full_index=True)

    assert result.photos_deleted == 1

    lance_index_obj = await LanceIndex.open(backend, PHOTO_TABLE_NAME)
    rows = [r async for r in lance_index_obj.get_partition_rows("")]
    filenames = {r["filename"] for r in rows}
    assert "keep.jpg" in filenames
    assert "delete.jpg" not in filenames
```

This test fails against current code (stale row survives) and passes after
the fix. Existing tests
(`test_incremental_removes_deleted_photos_from_manifest`,
`test_force_full_index_reprocesses_all_photos`, and the rest of the
incremental/full-index suite) must still pass unchanged.

### 3. Documentation

- `whitebeard/whitebeard_LLD.md` — remove the implicit incremental-only
  framing around deleted-photo detection; state it applies to both
  incremental and full-reindex runs.
- `whitebeard/README.md` — same clarification.
- `whitebeard/src/whitebeard/agent.py` — MCP-exposed docstrings for
  `index_library_tool` and `index_partition_scope_tool`: reword the paired
  sentence "By default runs in incremental mode: ... deleted photos removed.
  Use `force_full_index=True` to re-process all photos..." so that deletion
  of stale photos is stated as unconditional, decoupled from the
  incremental/full-index distinction (which only affects whether
  already-indexed photos get re-processed).
- `ouestcharlie-woof/src/woof/mcp_server.py` — `index_library` proxy tool
  docstring: same rewording (this text was propagated from Whitebeard's
  docstring).

## Verification

- `.venv/bin/pytest tests/test_indexer.py -v` in `ouestcharlie-whitebeard` —
  new test passes; full incremental/full-index suite still green.
- `.venv/bin/pytest tests/ -v` in `ouestcharlie-whitebeard` — full suite
  green, confirming nothing else implicitly depended on `deleted_filenames`
  being `None` in full-index mode.
- Manual: create a partition with two photos, run `index_partition_scope` (or
  `index_library`) once, delete one photo from disk, run again with
  `force_full_index=True`, confirm the deleted photo's row is gone from the
  LanceDB index.
