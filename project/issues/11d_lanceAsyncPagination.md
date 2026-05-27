# OEC#11d — LanceDB async API, sort, and pagination

#status:done

## Context

Every LanceDB operation in `lance_index.py` is currently wrapped in
`asyncio.to_thread(_lance_worker)` because only the sync `lancedb.Table` API was used.
LanceDB now ships `AsyncTable` (via `connect_async()`) with native coroutines for queries,
deletes, and optimize — removing the thread-pool boilerplate and avoiding potential event-loop
contention.

Separately, `search_where()` returns results in LanceDB insertion order with no page boundary,
forcing callers to receive up to 10 000 rows at once. Adding DB-level sort and 500-photo pages
makes the MCP interface practical for large libraries.

## lancedb Version Note

`AsyncQuery.order_by()` is documented but **not present in lancedb 0.30.2** (installed
version). Sort is implemented via **PyArrow `pa.Table.sort_by()`** as a workaround:
`search_where()` fetches all matching rows with `to_arrow()`, sorts the resulting `pa.Table`
in memory, then slices the page with `pa.Table.slice()`. This also eliminates the separate
`count_rows()` round-trip — `total_count = len(arrow_table)` is free.

When `AsyncQuery.order_by()` becomes available in a stable lancedb release, the in-memory
sort can be replaced with a DB-level `ORDER BY … LIMIT … OFFSET` for larger-scale use.

**`merge_insert().execute()` finding:** When `_table` is `AsyncTable`, `execute()` returns
`AsyncTable._do_merge()` — a coroutine — not a sync return value. The `asyncio.to_thread`
wrapper would have silently discarded this unawaited coroutine, leaving all upserts as no-ops.
Fix: `await` the chain directly (no `to_thread` needed).

## Changes

### `ouestcharlie-py-toolkit/src/ouestcharlie_toolkit/lance_index.py`

**New constant:**
```python
PAGE_SIZE = 500
```

**New imports:** `from collections.abc import AsyncIterable, AsyncIterator, Iterable`

**`LanceIndex._table` type:** `lancedb.table.Table` → `lancedb.table.AsyncTable`

**`open_or_create` / `open`** — drop `asyncio.to_thread`; use native async:
```python
db = await lancedb.connect_async(uri)
table = await db.create_table(table_name, schema=PHOTO_SCHEMA, exist_ok=True)  # open_or_create
# or:
table_names = await db.list_tables()
if table_name not in table_names:
    raise FileNotFoundError(...)
table = await db.open_table(table_name)                                         # open
```

**`upsert_partition`** — split into two steps:
1. Thumbnail fetch: native async (`await table.query().where(…).select(…).to_list()`)
2. `merge_insert().execute()`: stays in `asyncio.to_thread` — sync-only API

**`delete` / `delete_partition`** — drop `to_thread`; `await self._table.delete(query)`.

**`maintain`** — drop `to_thread`; `await self._table.optimize(cleanup_older_than=…)`.

**`get_partition_rows`** — drop `to_thread`; native async query. Return type:
`list[dict[str, Any]]` → `Iterable[dict[str, Any]]`.

**`search_where` — new signature:**
```python
async def search_where(
    self,
    where_clause: str | None,
    root: str = "",
    order_by: str = "date_taken",
    order_desc: bool = True,
    page: int = 0,        # 0-indexed
    page_size: int = PAGE_SIZE,
) -> tuple[AsyncIterable[dict[str, Any]], int]:   # (page_rows, total_count)
```

Implementation (PyArrow in-memory sort — see lancedb version note above):
1. Build `combined` filter (root prefix + where clause) as before.
2. Fetch all matching rows into a `pa.Table` — single DB round-trip:
   ```python
   query = self._table.query()
   if combined:
       query = query.where(combined)
   arrow_table: pa.Table = await query.to_arrow()
   ```
3. Sort with guard against unknown column name:
   ```python
   sort_order_str = "descending" if order_desc else "ascending"
   try:
       arrow_table = arrow_table.sort_by([(order_by, sort_order_str)])
   except Exception as exc:
       _log.warning("sort_by(%r) failed, returning unsorted: %s", order_by, exc)
   ```
4. Compute total and slice (zero-copy):
   ```python
   total_count = len(arrow_table)
   page_table = arrow_table.slice(page * page_size, page_size)
   ```
5. Return an async generator wrapping the page:
   ```python
   async def _rows() -> AsyncIterator[dict[str, Any]]:
       for row in page_table.to_pylist():
           yield row
   return _rows(), total_count
   ```

Callers update from `for row in rows` → `async for row in rows`.

---

### `ouestcharlie-wally/src/wally/searcher.py`

`SearchResult` dataclass — add:
```python
total_count: int = 0
page: int = 1
page_size: int = PAGE_SIZE
has_more: bool = False
```

`search_photos()` signature — add:
```python
sort_by: str = "date_taken",
sort_order: str = "desc",   # "asc" | "desc"
page: int = 1,              # 1-indexed
```

Pass to `lance_index.search_where(…, order_by=sort_by, order_desc=(sort_order=="desc"), page=page-1)`.
Unpack `(rows_iter, total_count)`.  Replace `for row in rows` with `async for row in rows_iter`.
Set result fields: `total_count`, `page`, `page_size = PAGE_SIZE`, `has_more = (page * PAGE_SIZE) < total_count`.

---

### `ouestcharlie-wally/src/wally/agent.py`

`search_photos` MCP tool — add parameters with defaults:
```python
sort_by: str = "date_taken",
sort_order: str = "desc",
page: int = 1,
```
Forward to `search_photos()`. Return shape additions:
```
"totalCount", "page", "pageSize", "hasMore"
```

---

### `ouestcharlie-woof/src/woof/server.py`

`search_photos` MCP tool — add same three parameters, include in the `args` dict forwarded
to the Wally agent. Forward `totalCount`, `page`, `pageSize`, `hasMore` from the Wally
response to the caller.

---

### `ouestcharlie-woof/src/woof/gallery_session_manager.py`

Remove `_sort_by_date()` and the `_NO_DATE` sentinel. Matches arrive already sorted at the
DB level; store them in arrival order.
- `create()`: `_sort_by_date(stamped)` → `stamped`
- `merge()`: `_sort_by_date(merged_matches)` → `merged_matches`

Multi-library merge retains per-library insertion order. A global merge-sort across libraries
is deferred to a future issue.

## Verification

1. `ouestcharlie-py-toolkit/.venv/bin/python -m pytest tests/test_lance_index.py -v`
2. `ouestcharlie-wally/.venv/bin/python -m pytest tests/ -v`
3. Via Wally MCP: `search_photos(filters={…}, page=1, sort_by="date_taken")` → 500 rows,
   descending date, `hasMore=true` when library > 500 photos.
4. Call with `page=2` → next 500, no overlap.
5. Via Whitebeard MCP: `index_library` completes without regression.
