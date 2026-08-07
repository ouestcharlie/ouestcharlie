# OEC#40 Precise time-of-day search ranges

#status:done

## Context

Wally's `dateTaken` search filter currently supports only whole-day granularity: `min`/`max` accept ISO date strings (`"YYYY"`, `"YYYY-MM"`, `"YYYY-MM-DD"`) and are expanded to midnight / end-of-day before being applied as an absolute `[lo, hi]` timestamp interval. There is no way to filter by a precise time of day (e.g. "photos between 18:00–20:00").

The underlying plumbing already supports full timestamp precision — this is purely an MCP-adapter parsing gap:

- Storage (`date_taken` in LanceDB) and `RangeFilter.lo`/`.hi` (`ouestcharlie-wally/src/wally/searcher.py:35-44`) are already typed/stored as full `datetime`, not just dates.
- The day-only limitation is imposed entirely in `ouestcharlie-wally/src/wally/agent.py`: `_parse_date_min`/`_parse_date_max` (`agent.py:423-467`) only parse `"YYYY"`, `"YYYY-MM"`, `"YYYY-MM-DD"` and always expand to midnight/end-of-day.
- The tool description advertising this format lives at `agent.py:114-117`.
- `wally_LLD.md:184-186` documents this day-vs-timestamp split as a deliberate MCP-adapter concern (searcher itself is agnostic to granularity).

See also [OEC#41](41_recurringSeasonalTimeFilters.md), which covers the separate (and more open-ended) question of recurring day-of-year / time-of-day range filters.

## Proposed change

- Extend `_parse_date_min`/`_parse_date_max` to accept full or partial ISO 8601 datetime strings (`"2024-07-14T15:30:00"`, `"2024-07-14T15:30"`), falling back to today's date-only behavior (whole-day expansion) when no time component is given.
- Update the tool description in `agent.py` to document the new accepted formats.
- Update `wally_LLD.md` date field documentation accordingly.

No changes needed to `searcher.py` or the storage layer for this part.

## Verification

- `.venv/bin/pytest tests/ -v` from `ouestcharlie-wally`, with new/updated cases for `_parse_date_min`/`_parse_date_max` covering full-timestamp and partial-timestamp inputs alongside existing date-only inputs.
- Manual MCP check: query with `{"dateTaken": {"min": "2024-07-14T18:00:00", "max": "2024-07-14T20:00:00"}}` and confirm only photos in that window are returned.
