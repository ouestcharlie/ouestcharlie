# OEC#18 — Time management in the Lance index

#status:analysis

## Context

Photos carry two distinct time concepts that serve different use cases:

- **Wall-clock (local) time** — the date as the photographer experienced it ("May 3rd 2020"). Stored in EXIF `DateTimeOriginal` as a naive local datetime. Correct for calendar queries.
- **Absolute moment** — when the photo was taken in global time. Requires UTC, derived from local time + UTC offset (`OffsetTimeOriginal`).

### Current state

`_parse_exif_datetime()` in `photo.py` already produces a timezone-aware datetime when `OffsetTimeOriginal` is present. However, `photo_entry_to_row()` in `lance_index.py` strips the timezone with `dt.replace(tzinfo=None)` and hardcodes `utc_offset_minutes = None  # not yet extracted`.

The result: the UTC offset is parsed but silently discarded. `date_taken` is stored as local naive time (correct), but there is no way to do accurate chronological ordering across time zones.

### Sorting in Woof

`gallery_session_manager.py` sorts results by `dateTaken` using a plain string comparison on the ISO datetime returned by the index. Because `date_taken` is local naive time, this sort is correct within a single time zone but becomes inaccurate when merging results from photos taken in different time zones.

### HLD gap

`HLD.md` shows a query example:

```sql
date_taken >= TIMESTAMP '2024-07-01 00:00:00' AND date_taken <= TIMESTAMP '2024-07-31 23:59:59'
```

This is correct for local-time calendar queries. The HLD does not document the tradeoff: `date_taken` is local time (not UTC), and no UTC equivalent is stored. The design decision is implicit.

## Tradeoff to document in HLD

`date_taken` is intentionally stored as **local naive time** (wall-clock, no timezone). This makes calendar queries ("show me May 3rd photos") accurate without any offset arithmetic. Cross-timezone chronological ordering requires a separate UTC column, which is a deliberate omission at this stage: most cameras do not embed `OffsetTimeOriginal`, and the ordering error is small (at most a few hours within a day boundary).

## Plan

### Lance index (`ouestcharlie-py-toolkit`)

1. **Populate `utc_offset_minutes`** — in `photo_entry_to_row()`, extract `int(dt.utcoffset().total_seconds() / 60)` before stripping `tzinfo`. No schema change needed; the column already exists.

2. **Add `date_taken_utc` column** — nullable `pa.timestamp("us")`, computed at write time from the timezone-aware datetime before `tzinfo` is stripped. Null when no EXIF offset is available.
   - Add to `PHOTO_SCHEMA`
   - Populate in `photo_entry_to_row()`
   - Convention: date/calendar queries use `date_taken`; chronological ordering uses `date_taken_utc` (fall back to `date_taken` when null)
   - `utc_offset_minutes` becomes redundant: the offset can be recovered as `(date_taken - date_taken_utc).total_seconds() / 60` when both are non-null. Keep the column for display purposes (showing the original EXIF offset in the UI) but do not use it in queries or sort logic.

3. **Partition summary** — `partition_summary.py` keeps using `date_taken` for `date_min`/`date_max`. The summary is a calendar concept; local time is correct there. No change needed.

### Woof (`ouestcharlie-woof`)

4. **Sort by UTC when available** — `_sort_by_date()` in `gallery_session_manager.py` currently sorts on `dateTaken` (local ISO string). Update to prefer `dateTakenUtc` when present, falling back to `dateTaken`. This makes multi-library merges chronologically accurate for cameras that embed the offset.

### HLD

5. **Document the tradeoff** — update the query cost example and the Lance index schema section to make explicit:
   - `date_taken` = local naive time, for calendar queries
   - `date_taken_utc` = UTC, nullable, for chronological ordering
   - `utc_offset_minutes` = signed integer minutes, nullable
