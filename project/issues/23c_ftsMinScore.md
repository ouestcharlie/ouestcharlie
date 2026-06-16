# OEC-23c — FTS min_score filter + score stats in pageStats

#status:done - partially

- min_score filter discarded
- min and max score statistics kept

## Context

OEC-23b added `full_text_filter` to `search_photos` using LanceDB's `nearest_to_text()`. Without a lower bound on score, every indexed photo is returned ordered by BM25 relevance — including very weak tail matches that are essentially noise. Adding `min_score` to `FtsFilter` lets callers prune weak results. Separately, `pageStats` currently shows date/rating ranges but nothing about score distribution, so the AI assistant has no basis for suggesting a useful threshold. Adding `score: {min, max}` to pageStats closes that gap.

## Approach for min_score filtering

LanceDB 0.33 `AsyncFTSQuery` inherits `.where(str)`. Attempt to chain `.where(f"_score >= {min_score}")` directly on the FTS query (server-side, cheapest). If LanceDB raises because `_score` is not filterable before materialization, fall back to Python post-filter: filter `page_rows` in Python after `to_list()`.

> **Implementation note**: Try `.where()` first. If it errors at runtime, switch to the Python fallback and leave a comment explaining why.

## Default value

`DEFAULT_FTS_MIN_SCORE = 1.0` — conservative threshold that filters near-zero BM25 noise while keeping meaningful matches. BM25 scores in LanceDB are typically in the 0–15 range.

## Propagation

The default is enforced in Wally's `_build_fts_filter`, not inside `FtsFilter.__init__`. Woof forwards `full_text_filter` verbatim and needs no changes. Wally fills in the default from `DEFAULT_FTS_MIN_SCORE` (imported from py-toolkit) when `min_score` is absent from the dict — single source of truth.

## Changes

### `ouestcharlie-py-toolkit/src/ouestcharlie_toolkit/lance_index.py`

Add `DEFAULT_FTS_MIN_SCORE` constant and `min_score` field to `FtsFilter`:
```python
DEFAULT_FTS_MIN_SCORE: float = 1.0

@dataclass(frozen=True)
class FtsFilter:
    query: str
    columns: list[str]
    min_score: float = DEFAULT_FTS_MIN_SCORE
```

In `search_where` FTS branch, chain `.where()` when `min_score` is set:
```python
if fts_filter:
    q = _base_query().nearest_to_text(fts_filter.query, columns=fts_filter.columns)
    if fts_filter.min_score is not None:
        q = q.where(f"_score >= {fts_filter.min_score}")
    page_rows = await q.offset(page * page_size).limit(page_size).to_list()
```

### `ouestcharlie-wally/src/wally/agent.py`

In `_build_fts_filter`, read and validate `min_score`; apply `DEFAULT_FTS_MIN_SCORE` when absent:
```python
min_score_raw = full_text_filter.get("min_score")
if min_score_raw is not None and not isinstance(min_score_raw, (int, float)):
    raise ValueError("full_text_filter.min_score must be a number")
min_score = float(min_score_raw) if min_score_raw is not None else DEFAULT_FTS_MIN_SCORE
return FtsFilter(query=fts_query, columns=fts_columns, min_score=min_score)
```

Also import `DEFAULT_FTS_MIN_SCORE` alongside `FtsFilter`, and update the `_search_photos_tool` docstring:
```
full_text_filter: {"query": "Canyon", "columns": ["description"], "min_score": 1.0}
```
`min_score` is optional; default is `DEFAULT_FTS_MIN_SCORE`.

### `ouestcharlie-woof/src/woof/server.py`

In `_search_stats`, add score min/max when any match has a `score` key:
```python
scores = [m["score"] for m in matches if m.get("score") is not None]
if scores:
    stats["score"] = {"min": min(scores), "max": max(scores)}
```

No change to `search_photos` tool signature — `min_score` travels inside `full_text_filter`, already forwarded verbatim.

## Tests to add

**`ouestcharlie-wally/tests/test_full_text_filter.py`**:
- `test_valid_min_score_accepted` — `{"query": "Canyon", "columns": ["description"], "min_score": 1.5}` → `FtsFilter(min_score=1.5)`
- `test_min_score_defaults_when_absent` — omitting `min_score` → `FtsFilter(min_score=DEFAULT_FTS_MIN_SCORE)`
- `test_non_numeric_min_score_raises` — `{"min_score": "high"}` raises ValueError
- `test_integer_min_score_accepted` — `min_score: 2` (int) → `FtsFilter(min_score=2.0)`

**`ouestcharlie-woof/tests/test_server.py`**:
- `test_search_stats_includes_score_when_present` — matches with `score` field → `pageStats["score"] == {"min": X, "max": Y}`
- `test_search_stats_no_score_key_when_absent` — matches without `score` → no `"score"` key in pageStats

## Verification

```bash
cd ouestcharlie-py-toolkit && .venv/bin/pytest tests/ -v
cd ouestcharlie-wally && .venv/bin/pytest tests/ -v
cd ouestcharlie-woof && .venv/bin/pytest tests/ -v
```

Via MCP:
1. `search_photos(full_text_filter={"query": "Canyon", "columns": ["description"]})` — verify `pageStats.score` shows `{min, max}` and weak matches are absent.
2. Re-run with `min_score` set to the observed max — verify only the single top match is returned.
3. Re-run with `min_score: 0` — verify all matches returned (same as no threshold).
