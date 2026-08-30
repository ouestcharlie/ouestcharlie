# OEC-23c: Full-text search total count undercounts matches

#status:done

Status flow: draft (write spec) -> open (review spec) -> todo (spec validated) -> ongoing (implementation started) -> done (merged)

## Context

OEC-23 (`23_tagsAndFTS.md`) added full-text search on `dc:description` via
LanceDB's `nearest_to_text`. Reported bug: searching the "Antoine" library for
`Fontanabran` in the description returns 15 rows in the page, but the reported
`totalCount` is 10.

Root cause: `LanceIndex.search_where()`
(`ouestcharlie-py-toolkit/src/ouestcharlie_toolkit/lance_index.py:423-501`) runs
two separate queries off the same `_base_query()`:

1. **Count query** (line 468): `_base_query().select(["content_hash"]).to_arrow()`
   — no `.limit()` call.
2. **Page query** (lines 472-473, FTS branch): `_base_query().offset(...).limit(page_size)`
   — explicit `.limit(page_size)` (`PAGE_SIZE = 500`).

When `fts_filter` is set, `_base_query()` calls `q.nearest_to_text(...)`
(line 464). LanceDB applies an implicit default row cap (~10) to
`nearest_to_text` queries that don't chain an explicit `.limit()`. The count
query hits this default cap and silently truncates to ~10 rows regardless of
the true match count; the page query avoids it only because it happens to
chain `.limit(page_size)` for pagination purposes, incidentally overriding the
default. Non-FTS queries (the `else` branch, native `order_by`) aren't affected
— an ordinary `.where()` scan has no such implicit cap.

Net effect: any full-text search matching more than ~10 rows reports a
`totalCount` capped at ~10, while the actual page can (and did) return more
rows than the reported total — a visibly wrong, and specifically
under-counted, result.

---

## Changes

### 1. Split the count path: native `count_rows` for SQL filters, capped FTS scan for text search

**File:** `ouestcharlie-py-toolkit/src/ouestcharlie_toolkit/lance_index.py`
(`search_where`, ~line 467)

LanceDB has no native count for `nearest_to_text` (ranking) queries — the
table's `count_rows(filter)` only accepts a plain SQL filter string, not an
FTS query object — so the two count paths need genuinely different
implementations rather than one shared query with a conditional `.limit()`:

- **`fts_filter` set**: no native count exists, so counting means
  materializing matches via `select(["content_hash"]).to_arrow()` — and
  `nearest_to_text` applies an implicit default row cap (~10) when no
  `.limit()` is chained, which would silently truncate this count for any FTS
  search matching more rows than that default. Add an explicit
  `.limit(DEFAULT_LIMIT)` (reusing the existing `DEFAULT_LIMIT = 10_000`
  constant, already used elsewhere in this module as an effectively-unbounded
  scan cap, comfortably above any realistic library size per `CLAUDE.md`'s
  10K-photo target) so the count reflects the true match count instead of the
  implicit cap.
- **No `fts_filter`**: use `self._table.count_rows(where_clause)` directly —
  a native LanceDB count that doesn't materialize any rows at all, strictly
  cheaper than the previous `select().to_arrow()` + `len()` approach for this
  path.

```python
# Before
count_table: pa.Table = await _base_query().select(["content_hash"]).to_arrow()
total_count = len(count_table)

# After
if fts_filter:
    count_table: pa.Table = (
        await _base_query().select(["content_hash"]).limit(DEFAULT_LIMIT).to_arrow()
    )
    total_count = len(count_table)
else:
    total_count = await self._table.count_rows(where_clause)
```

### 2. Tests

**File:** `ouestcharlie-py-toolkit/tests/test_lance_index.py` (or wherever
`search_where`'s FTS path is currently tested — see OEC-23's test additions)

- Index a fixture library with >10 photos sharing a common description
  substring (e.g. 15, matching the reported repro). Full-text search for that
  substring. Assert `total_count == 15` and `len(page_rows) == 15` (single
  page, `page_size` default comfortably above 15) — the two must agree.
- Regression guard: assert `total_count >= len(page_rows)` for FTS searches in
  general (the count must never be smaller than an actually-returned page).
- Non-FTS path: existing `search_where` tests (e.g.
  `test_search_where_results_sorted_descending`,
  `test_search_where_invalid_order_by_does_not_raise`) already assert correct
  `total_count` values for plain SQL-filtered/unfiltered searches, so they
  double as regression coverage for the switch to `count_rows(where_clause)`.
- FTS count coverage rounded out beyond the single repro-shaped test: zero
  matches (`test_fts_total_count_zero_when_no_matches` — must report 0, not
  fall through to some default), stability across pages
  (`test_fts_total_count_stable_across_pages`, mirroring the non-FTS
  equivalent), and FTS+SQL-filter combined count
  (`test_fts_combined_with_sql_filter` now also asserts `total`, previously
  only checked row content).

### 3. Documentation

No HLD/LLD change needed — this is a bugfix to an existing documented
behavior (OEC-23's two-query count/page split), not a design change.

---

## Verification

- Reproduce the original report: search "Antoine" library for `Fontanabran` in
  description, confirm `totalCount` now matches the actual number of results
  (15).
- Run the new/updated test in `test_lance_index.py`.
- Spot-check a non-FTS filtered search still returns a correct count (confirm
  the fix doesn't regress the unaffected `else` branch).
