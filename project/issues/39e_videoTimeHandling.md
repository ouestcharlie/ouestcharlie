# OEC-39e: Video time handling — UTC creation_time to local wall-clock

#status:done

## Context

Photo and video carry timestamps with **different semantics**, and the initial OEC-39
plan does not reconcile them:

- **Photo** `date_taken` comes from EXIF `DateTimeOriginal` — a **naive local**
  datetime (wall-clock, no timezone). This is what the whole system relies on:
  calendar queries in the Lance index and gallery grouping treat `date_taken` as the
  date the photographer experienced (see OEC-18).
- **Video** containers (MP4/MOV) carry `creation_time` in the `mvhd` atom, which is
  **defined as UTC** — PyAV exposes it via `container.metadata["creation_time"]` as an
  ISO 8601 string with a `Z` suffix.

OEC-39 maps `creation_time` directly into the shared `date_taken` field
(`39_videoSupport.md`, "Map overlapping fields into the same `XmpSidecar`-shaped
dict"). That writes a UTC instant into a column read everywhere as local wall-clock. A
clip shot at 20:00 local in France (UTC+2 in summer) lands as 18:00, so it groups
under the wrong calendar day and sorts incorrectly against photos from the same
evening. The bug is silent — the value looks plausible, just shifted by the offset.

This issue defines how video ingestion resolves local time, honoring the OEC-18
convention (`date_taken` = local wall-clock, `date_taken_utc` = UTC).

---

## Changes

### 1. Offset resolution in video metadata extraction

**File:** `ouestcharlie-py-toolkit/src/ouestcharlie_toolkit/video.py` (`extract_metadata()`)

`creation_time` alone is UTC with no offset, so it cannot by itself produce local
wall-clock. Resolve the offset with the following precedence and only then compute
`date_taken`:

1. **Apple `creationdate` tag** (preferred). iPhone/QuickTime MOVs embed
   `com.apple.quicktime.creationdate` (e.g. `2020-05-03T20:00:00+0200`) — this already
   carries local time **and** the offset. When present, use it directly:
   `date_taken` = its local wall-clock, `date_taken_utc` = the same instant in UTC,
   `utc_offset_minutes` = its offset. No further work needed.

2. **Vendor offset tag.** Android devices (e.g. Samsung) leave `creation_time` in UTC
   but record the capture offset in a vendor tag (`com.samsung.android.utc_offset`, e.g.
   `+0100`). When present, apply it to `creation_time`: `date_taken` = converted local,
   `date_taken_utc` = UTC, `utc_offset_minutes` = the tag's offset. This is preferred over
   GPS because it is the offset the device itself recorded.

3. **GPS-derived offset.** When only UTC `creation_time` is available but the container
   has a location (`com.apple.quicktime.location.ISO6709`, already parsed by OEC-39 for
   `gps`), resolve the timezone from the coordinates (`tzfpy`, see §2) and apply
   it to `creation_time`. `date_taken` = converted local, `date_taken_utc` = UTC,
   `utc_offset_minutes` = resolved offset.

4. **Filename-derived offset.** Many camera apps (AOSP Android and others) name clips
   with the **local** wall-clock (`YYYYMMDD_HHMMSS`) while `creation_time` stays UTC.
   Their difference is the capture offset. Trusted only when it rounds to a whole
   quarter-hour within a few minutes (real zone offsets are all multiples of 15 min; the
   name is the recording-start time, the container is finalized a few seconds later) and
   stays inside ±14h — otherwise (a renamed file, a name that isn't local time) fall
   through. Measured on a 606-clip library this alone resolved the offset for the ~136
   tagless Android files plus most timestamp-named exports, lifting coverage from ~8% to
   ~77%.

5. **Fallback — keep UTC.** When no offset tag, location, or usable filename is
   available, the local offset is unknown but `creation_time` is UTC *by spec* — that
   timezone is itself known, so keep it (tz-aware UTC) rather than discarding it. The
   UTC instant is exact, so `date_taken_utc` is populated (unlike the photo case, where
   EXIF `DateTimeOriginal` is genuinely naive local with no tz and `date_taken_utc`
   stays null). The naive-local `date_taken` derived downstream is the UTC wall-clock,
   which can be off by the true local offset — document that limitation.

6. **No `creation_time` at all + timestamped filename.** Re-encodes (e.g. Google Photos
   exports) can strip `creation_time` entirely while keeping the `YYYYMMDD_HHMMSS` local
   wall-clock in the name. With no UTC anchor there is no offset to derive, so expose the
   filename time as a **naive** local `date_taken` (offset unknown), mirroring the photo
   case with no EXIF offset. Only when neither a `creation_time` nor a parseable filename
   exists is `date_taken` left null.

`extract_metadata()` produces a single `date_taken` datetime — timezone-aware when the
offset is known (cases 1–4) or when only the UTC anchor is (case 5, tz-aware UTC), and
naive when only a filename timestamp is available (case 6). The UTC instant and
`utc_offset_minutes` are **not** computed in `video.py`: the shared
`photo_entry_to_row()` derives `date_taken_utc` and `utc_offset_minutes` from the
datetime at index time (OEC-18), so photo and video paths stay uniform. The key
correctness point is that `date_taken` must be local wall-clock, never the raw UTC
`creation_time`.

```python
# Wrong (OEC-39 initial plan): UTC written into a local-wall-clock column, then
# photo_entry_to_row strips tzinfo → the UTC value is mislabeled as local.
date_taken = _parse_creation_time(container.metadata["creation_time"])  # ...Z, UTC

# Right: resolve the offset and return local wall-clock (tz-aware when known).
date_taken = _resolve_video_time(container.metadata, gps, filename=...)
# cases 1–4 → tz-aware local (offset known); case 5 → tz-aware UTC (offset unknown,
# UTC instant exact); case 6 → naive local from filename (offset unknown).
# photo_entry_to_row derives date_taken (naive), date_taken_utc, utc_offset_minutes.
```

The filename parsing (`YYYYMMDD_HHMMSS` full datetime, and a date-only `YYYYMMDD`
fallback) lives in a shared helper reused by photo extraction — see §5.

### 2. Dependency

**File:** `ouestcharlie-py-toolkit/pyproject.toml`

Add `tzfpy` (offline coordinate→timezone lookup) for the GPS step (§1, step 3),
mirroring how `av`/`pillow-heif` were added. Gate that step on its availability; the
other steps need no extra dependency.

**Why `tzfpy` and not `timezonefinder`** (checked 2026-08-08): the mainstream
`timezonefinder` ships **Linux x86_64 wheels only** — on macOS (incl. Apple Silicon)
and Windows it builds from sdist and drags in `numpy>=2`, `h3`, `cffi`, `flatbuffers`,
which violates the cross-platform + minimal-dependency rules. `tzfpy` (Rust, `abi3`
wheels) covers macOS x86_64/arm64, Linux x86_64/aarch64 (glibc + musl), and Windows
amd64, with **no required runtime dependencies** and `requires_python >=3.10`. Same
`tz(lng, lat) -> "Europe/Paris"` lookup, resolved against `zoneinfo` for the offset.

### 3. Tests

**File:** `ouestcharlie-py-toolkit/tests/test_video.py`

- MOV with `com.apple.quicktime.creationdate` including a non-UTC offset → `date_taken`
  is local wall-clock, `date_taken_utc` is the correct UTC instant, `utc_offset_minutes`
  matches.
- MP4 (Android) with UTC `creation_time` + a vendor offset tag
  (`com.samsung.android.utc_offset`) → offset applied, `date_taken` is local
  wall-clock, `date_taken_utc` correct.
- MP4 with only UTC `creation_time` + ISO6709 location → offset resolved from GPS,
  `date_taken` converted to local.
- MP4 with only UTC `creation_time` + a `YYYYMMDD_HHMMSS` filename → offset derived
  from the local wall-clock in the name vs the UTC instant; untrustworthy names (no
  timestamp, off from any quarter-hour, out of ±14h range) are rejected. An explicit
  offset tag takes precedence over a disagreeing filename.
- MP4 with only UTC `creation_time`, no offset tag, no location → fallback: kept as
  tz-aware UTC, so `date_taken` == `date_taken_utc` and `utc_offset_minutes` is 0
  (the exact UTC instant is known; only the true local offset is not).
- MP4 with no `creation_time` but a `YYYYMMDD_HHMMSS` filename (re-encode) → naive
  local `date_taken`, offset unknown.
- MP4 with no `creation_time` and a date-only name (`VID-YYYYMMDD-WA…`) → midnight
  local `date_taken`; only names with neither a `creation_time` nor a parseable date
  are left null.
- Regression: a France-summer clip at 20:00 local must **not** land as 18:00 in
  `date_taken`.

Run with `.venv/bin/pytest tests/test_video.py -v`.

### 4. Documentation

- **OEC-18** — already cross-references this issue; keep the schema/query convention as
  the single source of truth for `date_taken` / `date_taken_utc` / `utc_offset_minutes`.
- **OEC-39 / 39a** — replace the "map `creation_time` into `date_taken`" wording with a
  pointer to this issue's offset-resolution precedence, so the LLD does not re-specify
  it inconsistently.
- **HLD.md** — no new schema; the `date_taken_utc` column and conventions are already
  covered by OEC-18. Only note that video is a second source feeding the same columns.

### 5. Shared filename fallback (photos + videos)

**Files:** a shared helper module in `ouestcharlie-py-toolkit/src/ouestcharlie_toolkit/`
(reused by `video.py` and `photo.py`).

The filename parsing is not video-specific, so it lives in one place:

- `datetime_from_filename(name)` — a `YYYYMMDD_HHMMSS` (separator optional) local
  wall-clock, or None.
- `date_from_filename(name)` — a date-only `YYYYMMDD` (with a negative lookahead so it
  never matches the date half of a full datetime), returned at **midnight** local, or
  None.

**Video** uses these in steps 4 (offset derivation vs the UTC anchor) and 6
(no-`creation_time` fallback), as above.

**Photo** applies the same last-resort fallback. Photo `date_taken` normally comes from
EXIF `DateTimeOriginal`; when that is absent (`_parse_exif_datetime` returns None) the
extractor falls back to `datetime_from_filename(self.path)`, then
`date_from_filename(self.path)`. Both yield a **naive** local `date_taken` (offset
unknown) — consistent with how EXIF without `OffsetTimeOriginal` is already treated.

Scope decision (measured on a ~27.9k-photo library, 2026-08-08): ~96.7% of photos carry
an EXIF datetime; of the remainder only ~0.4% expose a recoverable `YYYYMMDD` name, and
the rest are old camera/scanner sequence names (`DSCN0003.JPG`, `P1030891.JPG`) with no
date. The fallback intentionally **does not** parse ambiguous 2-digit-year European
formats (`28_10_96`, `3_01_97`): day-first vs month-first cannot be told apart in
general, and a wrong guess silently mis-dates the photo — not worth it for the tiny yield.

---

## Verification

- Ingest a mixed set: an iPhone MOV (with `creationdate`), a stripped MP4 with GPS, and
  an MP4 with neither. Confirm each `date_taken` in the Lance index is local wall-clock
  and matches the expected calendar day.
- In the gallery, confirm a video and a photo taken minutes apart in the same local
  evening group under the same day and interleave in the correct chronological order.
- Confirm the fallback case is visibly flagged (offset unknown) rather than silently
  shifted.
