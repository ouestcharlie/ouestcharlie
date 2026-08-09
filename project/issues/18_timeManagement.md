# OEC#18 — Time management in the Lance index

#status:ongoing

## Context

Photos carry two distinct time concepts that serve different use cases:

- **Wall-clock (local) time** — the date as the photographer experienced it ("May 3rd 2020"). Stored in EXIF `DateTimeOriginal` as a naive local datetime. Correct for calendar queries.
- **Absolute moment** — when the photo was taken in global time. Requires UTC, derived from local time + UTC offset (`OffsetTimeOriginal`).

### Current state

`_parse_exif_datetime()` in `photo.py` already produces a timezone-aware datetime when `OffsetTimeOriginal` is present. However, `photo_entry_to_row()` in `lance_index.py` strips the timezone with `dt.replace(tzinfo=None)` and hardcodes `utc_offset_minutes = None  # not yet extracted`.

The result: the UTC offset is parsed but silently discarded. `date_taken` is stored as local naive time (correct), but there is no way to do accurate chronological ordering across time zones.

### Video time is UTC, not local

Video ingestion (see OEC-39e) surfaces a new wrinkle. Photo `date_taken` derives
from EXIF `DateTimeOriginal`, a **naive local** datetime. Video containers instead
carry `creation_time` (MP4/MOV `mvhd`), which is **defined as UTC** (ISO 8601 with a
`Z` suffix). Mapping `creation_time` straight into `date_taken` — as the initial
OEC-39 plan does — writes a UTC instant into a column the rest of the system reads as
local wall-clock. A clip shot at 20:00 local in France lands in the index as 18:00 or
19:00, so it groups under the wrong calendar day and interleaves incorrectly against
photos from the same evening.

The convention in this issue (`date_taken` = local wall-clock, `date_taken_utc` =
UTC) resolves it cleanly, provided video ingestion **converts to local before writing
`date_taken`**. The offset precedence is documented in OEC-39e; the schema and query
conventions below apply unchanged to both media types.

### Sorting

Sorting is pushed down into the Lance index: `LanceIndex.search()` takes an `order_by`
column (default `date_taken`) and sorts natively via `ColumnOrdering`. Woof only
forwards a `sort_by`/`sort_order` pair from the MCP tool to that call — it no longer
sorts rows itself. Because `date_taken` is local naive time, ordering is correct within
a single time zone but becomes inaccurate when merging photos taken in different zones.

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

### Index / Woof

4. **Keep sorting on `date_taken`** — sorting is native in the index (`LanceIndex.search(order_by=...)`), not a Python comparison in Woof. This issue keeps the default `order_by="date_taken"` (local naive time). It is correct within a single time zone and the ordering error across zones is small (bounded by the offset), which is acceptable for now. `date_taken_utc` is still populated (step 2) so the data is available for the further work below.

### HLD

5. **Document the tradeoff** — update the query cost example and the Lance index schema section to make explicit:
   - `date_taken` = local naive time, for calendar queries
   - `date_taken_utc` = UTC, nullable, for chronological ordering
   - `utc_offset_minutes` = signed integer minutes, nullable

## Further work

**Sort on a coalesced UTC column** — to make cross-timezone ordering exact, sort on `date_taken_utc` falling back to `date_taken` when null (rows without an offset). This needs the coalesce to be expressible in the index `order_by` (LanceDB `ColumnOrdering` sorts a single column, so this likely means writing a non-null coalesced column at index time rather than coalescing in the query), plus exposing the UTC ordering as a `sort_by` choice in Woof. Deferred until cross-timezone ordering is a real pain point.
