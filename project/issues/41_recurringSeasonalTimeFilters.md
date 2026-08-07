# OEC#41 Recurring day-of-year / time-of-day search filters

#status:open

## Context

Wally has no concept of a *recurring* calendar-position range: a day-of-year band that repeats every year (e.g. "spring", March–June) or a time-of-day band that repeats every day (e.g. "evening", 18:00–06:00). All existing filters are strictly absolute `[lo, hi]` datetime intervals (per `RangeFilter`, `ouestcharlie-wally/src/wally/searcher.py:35-44`), composed via the `all`/`any` filter-group DSL introduced in [OEC#28](28_filterGroups.md). No recurring/seasonal concept exists anywhere in the codebase today (confirmed by search across `ouestcharlie-wally/src/wally/` and `wally_LLD.md`).

This matters because an AI-assistant host driving Woof/Wally via MCP will often need to translate natural-language time expressions into filter DSL calls — e.g. "spring time bike ride" (a day-of-year band repeating across years) or "what happened on this day in past years" (same day-of-year, recurring across years). Those are only illustrative examples of the kind of query the filter DSL should be able to satisfy; **translating natural language into filter DSL calls is entirely out of scope for OuEstCharlie** — that's the responsibility of whatever AI-assistant host is driving Woof/Wally. This issue only needs to make the DSL itself expressive enough to be targeted by such a translation.

This is a design/open-questions issue, not a fully specced implementation — the exact DSL/FieldType shape needs discussion before implementation. Related but separate: [OEC#40](40_preciseTimeRanges.md) covers precise (non-recurring) time-of-day ranges.

## Design sketch (open for discussion)

- New filter value shapes, e.g.:
  - `{"dayOfYear": {"min": "03-15", "max": "06-15"}}` — day-of-year band, matches every year, wraps around New Year's when `min > max`.
  - `{"timeOfDay": {"min": "18:00", "max": "06:00"}}` — time-of-day band, matches every day, wraps around midnight when `min > max`.
- These would need SQL generation using `EXTRACT`/`strftime` on `date_taken` (DuckDB) rather than a straight `>=`/`<=` timestamp comparison — the query dispatch point is `_build_leaf()` in `searcher.py:350-408` (current `DATE_RANGE` handling), which would need a new branch (or a new `FieldType` variant) alongside the existing one. Composition with `_build_group` (`searcher.py:412`) and `_build_where_clause` (`searcher.py:443`) should fall out naturally since both operate on leaf SQL fragments.
- Corresponding parsing would be added to `agent.py`'s `_parse_filter_node` (~`agent.py:359-367`), alongside a new tool-description entry.
- These new filters would compose with existing `dateTaken` filters and the `all`/`any` group DSL from OEC#28 (e.g. "spring AND evening" = `{"all": [{"dayOfYear": {...}}, {"timeOfDay": {...}}]}`).

## Open questions

- Should day-of-year/time-of-day be new standalone fields (`dayOfYear`, `timeOfDay`) or modifiers on the existing `dateTaken` field? Standalone fields are simpler to implement but duplicate the "this is about `date_taken`" relationship; a modifier avoids that but complicates `FieldDef`/`FilterValue` typing.
- Wrap-around ranges (`min > max` meaning "spans the year/day boundary") need clear semantics and test coverage for edge cases (leap years, DST if ever relevant, exact boundary values).
- Should there be a combined "recurring datetime range" primitive instead of two separate field types, to reduce DSL surface area?

## Verification

Not yet applicable — this is a design-only issue. Once a design is agreed and implemented, verification should follow existing conventions: unit tests for `_build_leaf`/`_parse_filter_node` (see `ouestcharlie-wally/tests/test_where_clause.py`, `test_search_validation.py` for patterns from OEC#28), run via `.venv/bin/pytest tests/ -v` from `ouestcharlie-wally`.
