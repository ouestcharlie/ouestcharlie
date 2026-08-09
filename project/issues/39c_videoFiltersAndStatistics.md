# OEC-39c: Filters and statistics for video fields and media type

#status:done

## Context

#39 added the video schema fields (`media_type`, `duration_seconds`,
`video_codec`, `has_audio`): they are extracted by `video.py`, serialized to XMP
by `xmp.py`, and carried on `XmpSidecar`/`ManifestSummary`. #39a/#39b wired the
streaming and gallery UI. What is still missing is the **search and aggregation
surface**: letting a user (or the model, via Wally's MCP tools) *filter on* and
*get statistics about* these fields — "show me videos", "clips longer than
30 s", "how many HEVC files do I have", "how many videos have audio".

The current state is uneven:

- **`mediaType`, `durationSeconds`, `videoCodec` already filter.** They have
  `FieldDef` entries in `PHOTO_FIELDS`
  (`ouestcharlie-py-toolkit/src/ouestcharlie_toolkit/fields.py`, video block) and
  backing LanceDB columns (`lance_index.py` schema), so `_build_leaf`
  (`ouestcharlie-wally/src/wally/searcher.py`) already emits WHERE fragments for
  them generically (STRING_MATCH for `mediaType`/`videoCodec`, FLOAT_RANGE for
  `durationSeconds`). No new filter code is needed for these three — this issue
  confirms and *tests* that path.
- **`has_audio` cannot be filtered at all.** It has no `FieldDef`, no LanceDB
  column, and there is no `FieldType.BOOL` — it lives only in the sidecar/summary
  dataclasses. Making it searchable is net-new work.
- **`get_summary` surfaces none of the video fields.** `compute_summary`
  (`ouestcharlie-py-toolkit/src/ouestcharlie_toolkit/partition_summary.py`) is
  *not* field-driven despite `fields.py`'s module docstring claiming summary
  serialisation needs no changes per field — `_AGG_COLUMNS` and `_AGG_SQL` are a
  hardcoded list (`date_taken`, `rating`, `width`, `height`, `gps_*`, `tags`).
  Duration ranges, media-type counts, codec counts, and audio counts never
  appear in the summary, and the summary (de)serializers in `schema.py`
  (`_summary_to_dict`/`_summary_from_dict`) only know `date_range`, `int_range`,
  and `tag_facets`.

This is a **backend-only** change (py-toolkit + Wally). It does not touch the
gallery — #39b already renders per-item video fields from the `match` payload;
this issue is about *querying across the collection*, not per-item display.

---

## Changes

### 1. Make `has_audio` a searchable boolean field

**File:** `ouestcharlie-py-toolkit/src/ouestcharlie_toolkit/fields.py`

- Add a `BOOL` member to `FieldType`:

  ```python
  BOOL = auto()  # bool; exact true/false match, presence-aware
  ```

- Add a `FieldDef` in the video block of `PHOTO_FIELDS`:

  ```python
  FieldDef(
      name="hasAudio",
      type=FieldType.BOOL,
      entry_attr="has_audio",
      sidecar_attr="has_audio",
      label="Has audio",
  ),
  ```

**File:** `ouestcharlie-py-toolkit/src/ouestcharlie_toolkit/lance_index.py`

- Add the column to the Arrow schema alongside the other video fields:
  `pa.field("has_audio", pa.bool_(), nullable=True)` (null for photos, matching
  the `media_type` default behavior).
- Emit it in `photo_entry_to_row` (`"has_audio": s.get("has_audio")`) and add
  `"has_audio"` to `PHOTO_ENTRY_COLUMNS`.
- `row_to_photo_entry` reconstructs it generically once `FieldType.BOOL` is
  handled in the field loop (single scalar `row.get(fdef.entry_attr)`, same as
  STRING_MATCH) — verify no special-casing is needed.

**File:** `ouestcharlie-wally/src/wally/searcher.py`

- Add a `BOOL` branch to `_build_leaf`. The filter value is a boolean (extend the
  filter-value parsing in `agent.py` / the predicate model to accept a bare bool
  for BOOL fields, mirroring how STRING_MATCH takes a `StringFilter`):

  ```python
  if fdef.type is FieldType.BOOL and isinstance(fv, bool):
      return [f"{fdef.entry_attr} = {'TRUE' if fv else 'FALSE'}"]
  ```

  A missing/null `has_audio` (all photos) is correctly excluded by an explicit
  `= TRUE`/`= FALSE` test, which is the desired semantics ("videos with audio",
  not "everything that isn't silent").

### 1b. Reject non-conformant filter input

**File:** `ouestcharlie-wally/src/wally/agent.py`

While adding the BOOL value path, harden `_parse_filter_node`/`_parse_filter_value`
against malformed input that was previously misparsed or silently dropped —
surfaced by clients passing filters as a JSON-encoded **string** rather than an
object, e.g. `filters='{"tags": "Alpinism"}'`:

- `_parse_filter_node` raises a clear `ValueError` when `raw` is a `str` (or any
  non-dict), instead of letting `"all" in raw` run a substring check on a string.
- `_parse_filter_value` raises (rather than returning `None`, which means "ignore")
  when a leaf value has the wrong shape for its field type: a bare string for a
  `STRING_COLLECTION` (`tags: "Alpinism"` → must be a list), a non-string
  `STRING_MATCH` `.value`, or a non-boolean for a `BOOL` field. Genuinely empty
  values (`None`, `[]`, `""`, empty range dict) still resolve to "no filter".

**Schema note:** `XmpSidecar.has_audio`, `video.py` extraction, and `xmp.py`
(de)serialization already exist on the (unmerged) video branch (#39) — no change
there. Because the video branch is not yet merged, the `has_audio` column lands
alongside the other video columns in the same schema addition — **no separate
schema-version bump or migration is needed**; it is folded into #39's index
schema change.

### 2. Video statistics in `get_summary`

**File:** `ouestcharlie-py-toolkit/src/ouestcharlie_toolkit/partition_summary.py`

Extend `compute_summary` so the video fields aggregate:

- **`durationSeconds`** — treated as a **FLOAT_RANGE** stat. Add
  `duration_seconds` to `_AGG_COLUMNS` and MIN/MAX/COUNT to `_AGG_SQL`; emit a
  `{"type": "float_range", "min", "max", "missing"}` stat under `durationSeconds`
  when any matching row has a duration. Add a distinct `float_range` type rather
  than overloading `int_range`, since duration is fractional.
- **`mediaType`** — treated as **categorical**: emit a `string_facets` stat.
  Add a small facet query mirroring
  `_TAG_FACETS_SQL` but on the scalar column:

  ```sql
  SELECT media_type, COUNT(*) AS cnt FROM photos
  WHERE media_type IS NOT NULL GROUP BY media_type ORDER BY cnt DESC
  ```

  Emit `{"type": "string_facets", "counts": {"photo": N, "video": M}}` under
  `mediaType`. This is the headline stat — "how much of the library is video".
- **`videoCodec`** — also **categorical**: same `string_facets` shape, keyed on
  `video_codec` (present only for videos, so it naturally counts only the video
  subset).
- **`hasAudio`** — emit `{"type": "bool_counts", "true": N, "false": M}` from a
  `GROUP BY has_audio` (nulls excluded). Simple and directly answers "how many
  clips are silent".

Prefer making this **field-driven** rather than adding four more hardcoded
blocks: iterate `PHOTO_FIELDS` and select aggregation by `FieldType`
(FLOAT_RANGE/INT_RANGE → range, STRING_MATCH-with-facets → `string_facets`, BOOL
→ `bool_counts`). To avoid faceting high-cardinality string columns
(`make`, `model`, `lens_model`, `directory`, `description`), gate string faceting
on an explicit `FieldDef` opt-in flag (e.g. a new `summary_facet: bool = False`,
set True only on `mediaType`/`videoCodec`) — this keeps `make`/`model` out of the
summary and realizes the "no per-field summary edits" promise `fields.py` already
advertises. This refactor is optional but strongly preferred over four bespoke
SQL blocks; if deferred, note it in the open points.

**File:** `ouestcharlie-py-toolkit/src/ouestcharlie_toolkit/schema.py`

- `_summary_to_dict`: extend the `type` switch to pass through `float_range`,
  `string_facets`, and `bool_counts` stats (they are already JSON-native — like
  `tag_facets`, no datetime/bytes conversion needed).
- `_summary_from_dict`: reconstruct the same three types so persisted partition
  summaries round-trip (previously only `date_range`/`int_range` summary_range
  fields and `tags`/`hashes` were rebuilt). `durationSeconds` uses
  `summary_range=True` — `summary_range`'s literal contract is "contributes range
  stats to the summary" (broadened to include FLOAT_RANGE). It is **not** wired to
  partition pruning (no pruning consumer exists today; when built, pruning is
  scoped to DATE_RANGE/INT_RANGE explicitly). Filtering on duration works via the
  WHERE clause regardless.

**Rename `photoCount` → `mediaCount`.** The summary count now spans photos *and*
videos, so `ManifestSummary.photo_count` becomes `media_count` and the serialized
key `photoCount` becomes `mediaCount` (`schema.py`, propagated through
`partition_summary.py`, `searcher.py`, and `agent.py`'s `get_summary` docstring).
The gallery's `photoCountLabel` in `App.svelte` is unrelated (it counts search
results, not the summary) and is left as-is.

**File:** `ouestcharlie-wally/src/wally/agent.py`

- Update the `get_summary` tool docstring (currently: "count, per-field ranges
  (date, rating, width/height, GPS bounding box), and tag facets") to document
  the new returns: `mediaType`/`videoCodec` facets, `durationSeconds` range,
  `hasAudio` counts — so the model knows it can ask "how many videos" without a
  full search. `list_search_fields` already exposes `hasAudio` automatically once
  its `FieldDef` is added, so no separate change there beyond the field addition.

### 3. Tests

**File:** `ouestcharlie-py-toolkit/tests/` (partition summary / lance index tests)

- Index a mixed set (photos + a couple of videos with known
  `duration`/`codec`/`has_audio`) and assert `compute_summary` returns:
  `mediaType` facets `{"photo": …, "video": …}`, a `durationSeconds`
  float_range with the right min/max, `videoCodec` facets, and `hasAudio` counts.
- A photo-only collection yields **no** video stats (fields absent, not
  zero-filled) — the presence-check pattern, matching how `rating`/`gps` are
  omitted when unset.
- Summary dict round-trip: `_summary_to_dict` → `_summary_from_dict` preserves
  `float_range`, `string_facets`, and `bool_counts`.

**File:** `ouestcharlie-wally/tests/` (searcher / filter tests)

- Filter `mediaType = "video"` returns only videos; `durationSeconds` range
  `{lo: 30}` returns only clips ≥ 30 s; `videoCodec = "hevc"` matches;
  `hasAudio = true` / `false` partitions correctly and excludes photos (null).
- Confirm existing photo filters/summary are unchanged (no regression from the
  field-driven refactor).

### 4. Documentation

- Update the `get_summary` description in `controller_api.json` if it enumerates
  returned stats (keep it in sync with the agent docstring).
- If HLD's data-model/summary section enumerates summary stat types, add
  `float_range`, `string_facets`, `bool_counts`. Do **not** enumerate individual
  video fields in prose — reference `PHOTO_FIELDS` per the project doc rule.
- The `fields.py` module docstring claims summary serialisation is field-driven;
  once §2's refactor lands that becomes true — leave the claim, or soften it if
  the refactor is deferred.

---

## Open points

- [ ] **Field-driven vs. hardcoded summary.** §2 proposes generalizing
  `compute_summary` to iterate `PHOTO_FIELDS` with a `summary_facet` opt-in. This
  is cleaner and matches the module docstring, but touches the hot aggregation
  path — decide whether to do the full refactor now or add the four video stats
  as targeted blocks and refactor later.
- [ ] **`videoCodec` normalization for facets.** ffmpeg names (`h264`, `hevc`)
  are raw; #39b maps them to friendly labels in the UI. Keep facet keys as the
  raw codec names (stable, machine-friendly) and let the UI label them, rather
  than faceting on display strings.
- [ ] **BOOL filter value shape.** Confirm the predicate/filter model and
  `_parse_filter_node` accept a bare `true`/`false` for BOOL fields; if the
  existing leaf model only carries string/range/collection values, a small
  `BoolFilter` (or reusing `StringFilter` with `"true"/"false"`) is needed —
  pick the least-invasive option consistent with the other `*Filter` types.

---

## Dependencies

- **#39 / #39a** — video schema fields, extraction, and index columns; not yet
  merged. `has_audio`'s LanceDB column is folded into #39's schema addition
  (no separate migration), and this issue adds the filter/summary surface on top.

---

## Verification

- `cd ouestcharlie-py-toolkit && .venv/bin/pytest tests/ -v` — new summary and
  round-trip cases pass; existing photo summary tests unchanged.
- `cd ouestcharlie-wally && .venv/bin/pytest tests/ -v` — video filter cases pass
  (mediaType, durationSeconds range, videoCodec, hasAudio); photo filters
  unchanged.
- Manual via an MCP client on a mixed library:
  - `get_summary` with empty filters returns `mediaType` facets, a
    `durationSeconds` range, `videoCodec` facets, and `hasAudio` counts.
  - `search_photos` filtered on `mediaType = "video"` returns only videos;
    `durationSeconds ≥ 30`, `videoCodec = "hevc"`, and `hasAudio = true` all
    scope correctly.
  - A photo-only partition's summary shows no video stats.
