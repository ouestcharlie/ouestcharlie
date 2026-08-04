# OEC#37 Runtime partition summaries (replace root summary.json aggregation)

#status:done

## Context

Partition/library summary statistics currently live in a single root-level file, `.ouestcharlie/summary.json`, written by Whitebeard's indexer (`compute_partition_summary` in `ouestcharlie-py-toolkit/src/ouestcharlie_toolkit/partition_summary.py`, `ManifestStore.upsert_partition_in_summary` in `manifest.py`) after **every** partition indexing pass. Wally exposes it as-is via the `get_partition_summaries` MCP tool (`ouestcharlie-wally/src/wally/agent.py:115-128`).

This has two problems:

1. **Concurrency**: every partition index run does a read-modify-write of the *same* root file (`ManifestStore.upsert_partition_in_summary`, `manifest.py:74-131`), guarded only by optimistic concurrency + a retry loop (`max_retries=5`) and a `partition_lock("")`. Concurrent indexing of multiple partitions (normal during a bulk index) causes repeated `VersionConflictError` retries and serializes all partition-summary writes on one file.
2. **Large flat JSON**: `summary.json` holds every partition's stats in one blob (HLD.md describes it as ~50-100KB and growing with partition count), which is awkward for the host agent to consume, and it's an all-or-nothing view — no way to ask "just these date ranges" or "just this directory."

## Design

**Stop precomputing and storing a global partition-by-partition summary.** Instead, compute summary statistics at query time in Wally, scoped by the same filter predicates already used by `search_photos`.

This mirrors an existing working pattern: `search_photos` already computes `tag_facets` (aggregate tag counts) at query time over the filtered-but-unpaginated result set (`LanceIndex.search_where`, `ouestcharlie-wally/src/wally/lance_index.py:428-471`, surfaced via `searcher.py:258-271` and `agent.py:240`). The new summary feature follows the same shape, but returns numeric MIN/MAX/COUNT aggregates instead of tag tallies.

### `summary.json` becomes a thin marker, not a migration

`summary.json` keeps its file name and path, but its shape shrinks to just `{schema_version, last_indexed_at}` — the `partitions: list[ManifestSummary]` field is dropped entirely. No migration/rewrite happens as a one-time step: existing bulky `summary.json` files are left as-is on disk and continue to satisfy the schema-version read (the `schemaVersion` field stays at the same location/key) until the library is next indexed. No schema-version bump is needed — the Lance index format itself is unchanged. The next full indexing session naturally overwrites `summary.json` with the new thin shape (written once per session, not per partition), which is when old libraries transition and any stale bulky content is purged.

### Whitebeard cleanup

Remove the per-partition `summary.json` read-modify-write path entirely: `compute_partition_summary`'s root-aggregation use and `ManifestStore.upsert_partition_in_summary` (and its retry loop) go away, along with the indexer call sites (`indexer.py:291-296`, pruning at `~479-515`). `summary.json` itself is kept, but only written once per full indexing session in its new thin shape — no dual-path/deprecated per-partition coexistence, since that's what caused the concurrency bug.

### Dependencies

No new dependency for Wally. `duckdb` is currently a `py-toolkit` dependency only; Wally does not depend on it directly today. The generalized DuckDB aggregation stays in `py-toolkit` (`partition_summary.py`), reused by Wally through its existing `ouestcharlie-py-toolkit` path dependency — no `duckdb` entry needs to be added to Wally's `pyproject.toml`. Bump the `ouestcharlie-py-toolkit` version pin in Wally's `pyproject.toml` once the new helper + thin-`RootSummary` shape land in py-toolkit.

## Changes to make

### `ouestcharlie-py-toolkit`
- Shrink `RootSummary` to `{schema_version, last_indexed_at}`, dropping `partitions: list[ManifestSummary]`. Keep the name `RootSummary` and the `summary.json` file path/key (`schemaVersion`) unchanged so old bulky files remain readable by `deserialize_summary`.
- Remove `ManifestStore.upsert_partition_in_summary` (`manifest.py:74-131`) and its retry loop. `read_summary`/`write_summary`/`create_summary` stay, now operating on the thin shape — one plain write per full indexing session.
- Generalize `partition_summary.py`'s `_AGG_SQL`/DuckDB logic into a reusable `aggregate_where(arrow_tbl, where_clause: str | None) -> AggregateStats`-style helper in the same module. `compute_partition_summary` can become a thin wrapper over it for the single-partition case if Whitebeard still needs per-partition stats in each partition's `manifest.json` (confirm during implementation).
- `SCHEMA_VERSION` (`schema.py:16`) is unchanged — no bump.

### `ouestcharlie-whitebeard`
- `indexer.py`: remove the per-partition `compute_partition_summary` + `upsert_partition_in_summary` calls after partition upsert (`~283-296`) and the stale-partition pruning rewrite of the `partitions` list (`~479-515`).
- Write `summary.json` (thin shape) once per full indexing session via `ManifestStore.write_summary`/`create_summary`, not per partition.

### `ouestcharlie-wally`
- `lance_index.py`: add `LanceIndex.to_arrow_where(where_clause: str | None) -> pa.Table` — same query-building path as `search_where` (`_base_query()...where(where_clause)`) but without pagination/limit, returning the raw Arrow table. No DuckDB in Wally itself.
- `searcher.py`: add `get_summary(predicate: SearchPredicate) -> SummaryStats` — builds the WHERE clause via the existing `_build_where_clause`/`_build_group` machinery (reused as-is), fetches the Arrow table via `to_arrow_where`, and calls py-toolkit's `aggregate_where` helper.
- `searcher.py`: the existing `summary.schema_version != SCHEMA_VERSION` check (`~234-248`) keeps working unchanged, now against the thin `summary.json`. "Unindexed" is still "`summary.json` missing."
- `agent.py`: replace the `get_partition_summaries` tool (`115-128`) with a `get_summary` tool accepting the same `filters`/`full_text_filter` shape as `search_photos` (reuse `_parse_filter_node`, `agent.py:250-333`), returning aggregate stats instead of paginated matches.
- Avoid duplicating filter-syntax docs: factor the `all`/`any`/leaf filter syntax explanation (currently inline in `search_photos`'s docstring per OEC#28) into one shared constant (e.g. `_FILTER_SYNTAX_DOC` in `agent.py`), embedded by both `search_photos` and `get_summary` docstrings.
- Remove references to the old `partitions`-bearing `RootSummary`/`summary.json` shape from Wally's `CLAUDE.md`/LLD.

### `ouestcharlie-woof`
- `server.py`: update tool-routing guidance that currently tells the host agent to call `get_partition_summaries` before an unscoped search (`agent.py:141-144`'s existing guidance) to reference `get_summary` and its filter capability instead — point at the tool's own docstring rather than re-explaining filter syntax inline.

### Documentation — reuse, don't duplicate, filter-syntax docs

Filter syntax (`all`/`any`/leaf, field types, FTS) is currently documented in at least three places: `search_photos`'s MCP tool docstring, `wally_LLD.md`'s parameter table, and `woof/server.py`'s tool routing description. Adding `get_summary` must not create a fourth/fifth copy.

- `wally_LLD.md`: describe filter syntax once in a dedicated "Filter Predicate" section (promote/consolidate the existing description currently under `search_photos`); have both `search_photos` and `get_summary` sections link back to it instead of repeating field/operator tables. Also document the new `get_summary` tool itself (parameters, response shape, aggregation semantics).
- `HLD.md:100-220`: update the `summary.json` description from "flat index of all partitions" to "thin schema-version marker, `{schema_version, last_indexed_at}`, written once per indexing session," and add the runtime-computed-summary model (Wally aggregates over the Lance index at query time, scoped by filters). Update schema-version migration text (`218-220`) to note old bulky `summary.json` files remain readable until the next reindex naturally replaces them — no forced migration. Do not re-describe filter syntax here.

## Verification

- `ouestcharlie-py-toolkit`, `ouestcharlie-whitebeard`, `ouestcharlie-wally`: `.venv/bin/pytest tests/ -v` in each after changes.
- Manually reindex a small test library, confirm `summary.json` is written once (not per partition) and is now the thin `{schema_version, last_indexed_at}` shape, no `partitions` list.
- Via MCP inspector on Wally: call `get_summary` with no filters (whole-library stats), then with a `filters`/`full_text_filter` payload matching an existing `search_photos` test case, and confirm the aggregate narrows accordingly (e.g. COUNT drops, date min/max narrows).
- Confirm concurrent indexing of multiple partitions no longer touches any shared root file — no `VersionConflictError` retries, since that code path is deleted.

## Documentation to update

- `HLD.md` (folder structure / summary.json section)
- `wally_LLD.md` (new Filter Predicate section, `get_summary` tool docs)
- `ouestcharlie-wally/CLAUDE.md` if it references the old `RootSummary` shape

## Amendment: move tag facets from search_photos to get_summary

Once `get_summary` landed, it made `search_photos`'s existing tag-facet computation (`tagFacets`, a `{tag: count}` map computed over the full unpaginated result set on **every** search call) redundant and wasteful — every page fetch paid for a full facet scan that most callers never used. Woof's `search_photos` tool never even forwarded it to its own caller; instead Woof computed its own separate `pageStats` (partition counts + per-page min/max, over just the current page of matches) — a second, inferior "attach a stats summary to a search call" mechanism, now also superseded.

Changes:

- **`ouestcharlie-py-toolkit`**: `LanceIndex.search_where` no longer computes tag facets — its lightweight count-scan now selects a single narrow column (`content_hash`) instead of `tags`, and its return type drops the third tuple element (`(page_rows, total_count)`, was `(page_rows, total_count, tag_facets)`). The extracted tag-counting logic becomes its own method, `LanceIndex.tag_facets_where(where_clause) -> dict[str, int]`, called only from `get_summary`.
- **`ouestcharlie-wally`**: `searcher.SearchResult` drops `tag_facets`; `search_photos` no longer returns `tagFacets` in its MCP response (docstring updated to point callers at `get_summary` instead). `searcher.get_summary` now returns `(ManifestSummary, tag_facets)` — it calls both `aggregate_where` (numeric stats) and `tag_facets_where` (tag counts) against the same `where_clause`. The `get_summary` MCP tool merges both into one response dict, adding `tagFacets` alongside the existing range stats.
- **`ouestcharlie-woof`**: removed `pageStats` from the `search_photos` tool response entirely, along with its now-dead-code support (`_search_stats` static method, the `_get_fields` wrapper, and the `Counter` import). `_get_fields_raw` (used by `list_search_fields`) is unaffected. `get_summary`'s docstring updated to note it's now the only tool returning a tag-facet breakdown.

No new dependency, no schema/wire-format change beyond the two response shapes above. See test coverage: `ouestcharlie-py-toolkit/tests/test_lance_index.py` (`tag_facets_where` section), `ouestcharlie-wally/tests/test_get_summary.py` (`get_summary — tag facets` section), `ouestcharlie-woof/tests/test_mcp_server.py` (`_get_fields_raw` section, `test_search_photos_returns_total_count_and_token`).
