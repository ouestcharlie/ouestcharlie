# OEC-23b — Full-Text Search via `full_text_filter`

#status:done

## Context

The `description` field now has a LanceDB FTS index (introduced in OEC-23). The current `filters` dict in `search_photos` doesn't distinguish FTS from SQL LIKE — it treated description as `STRING_MATCH`. This issue replaces that with a dedicated `full_text_filter` parameter that maps directly to LanceDB's `nearest_to_text(query, columns=[...])`, returns a `_score` relevance value per match, and can span multiple TEXT-typed columns.

**State after partial work (already applied, keep):**
- `fields.py`: `FieldType.TEXT = auto()` added; `description` field changed to `TEXT` type
- `searcher.py`: `PhotoMatch` has `score: float | None = None`; `_build_where_clause` partially updated (needs cleanup below)

## Design

### New field type: `TEXT`

`FieldType.TEXT` marks columns that have a LanceDB FTS index and are searched via `nearest_to_text` rather than a SQL LIKE clause. Currently only `description` uses it.

### `full_text_filter` parameter

Added to `search_photos` MCP tool:
```json
{"query": "Canyon", "columns": ["description"]}
```
- `query`: single search string applied across all listed columns
- `columns`: entry_attr names of TEXT-typed fields (validated)
- Results are relevance-ranked; each match includes `_score`
- Compatible with other `filters` (SQL predicates applied on top of FTS)

### `list_search_fields` response

Returns `full_text_search` as a separate top-level key alongside `fields`:
```json
{
  "fields": [...non-TEXT fields...],
  "full_text_search": {
    "description": "Search across one or more text fields with a single query string. Results are relevance-ranked and include a _score per match. Pass via full_text_filter={\"query\": \"...\", \"columns\": [...]}.",
    "fields": [
      {"name": "description", "column": "description", "label": "Description"}
    ]
  }
}
```

## Implementation

### `ouestcharlie-py-toolkit/src/ouestcharlie_toolkit/lance_index.py`

- Define `FtsFilter` dataclass: `query: str`, `columns: list[str]`
- Add `fts_filter: FtsFilter | None = None` to `search_where`
- When set: page query uses `.nearest_to_text(fts_filter.query, columns=fts_filter.columns)` (no `order_by` — ranked by relevance); `_score` included automatically
- When None: existing `order_by` + `offset` + `limit` path unchanged

### `ouestcharlie-wally/src/wally/searcher.py`

- Import `FtsFilter` from `lance_index`
- Add `fts_filter: FtsFilter | None = None` to `search_photos`; pass through to `search_where`
- `_build_where_clause` reverts to returning `str | None` only; silently skips `FieldType.TEXT` fields
- Row loop: `score=float(row["_score"]) if "_score" in row else None`

### `ouestcharlie-wally/src/wally/agent.py`

- `_search_photos_tool`: add `full_text_filter: dict | None = None`; validate columns are TEXT-typed; build `FtsFilter`; add `"score"` to match response
- `list_search_fields`: add `"TEXT"` to `_FORMAT`; return `full_text_search` block

### `ouestcharlie-woof/src/woof/server.py`

Two changes:

1. **`_get_fields` dropped `full_text_search`**: the method extracted only `result.get("fields", [])` from Wally's `list_search_fields` response, silently discarding the `full_text_search` block. Fixed by caching the full response dict in `_library_fields` and exposing it via `_get_fields_raw`. `_get_fields` now delegates to `_get_fields_raw().get("fields", [])` for `_search_stats` (which only needs SQL fields). `list_search_fields` uses `**raw` to pass the full dict through.

2. **`search_photos` had no `full_text_filter` parameter**: the tool signature didn't accept or forward FTS queries to Wally. Added `full_text_filter: dict | None = None`, forwarded in `args` when non-None.

## Verification

```bash
cd ouestcharlie-py-toolkit && .venv/bin/pytest tests/ -v
cd ouestcharlie-wally && .venv/bin/pytest tests/ -v
cd ouestcharlie-woof && .venv/bin/pytest tests/ -v
```
Via MCP: call `list_search_fields` — verify `full_text_search` key appears alongside `fields`. Call `search_photos(full_text_filter={"query": "Canyon", "columns": ["description"]})` — verify `score` in each match.
