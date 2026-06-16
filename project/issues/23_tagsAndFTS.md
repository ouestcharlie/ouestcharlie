# OEC-23: Tags in Results + Full-Text Search on Description

#status:done

## Context

Issue 23 adds two related features:

1. **Aggregated tag facets** — search results already include per-photo `tags` arrays, but there is no summary of which tags appear across the entire result set. Adding a `tagFacets` map (`{tag: count}`) lets the UI show a tag cloud or filter chips without a second round-trip.

2. **Full-text search on `dc:description`** — photos can carry a human-readable caption in the `dc:description` XMP field, but OuEstCharlie never reads, indexes, or searches it. This adds end-to-end support: XMP parsing → LanceDB column → FTS index → Wally search parameter.

---

## Part 1 — Aggregated Tag Facets

### Where the change lands

**`ouestcharlie-wally` — `src/wally/searcher.py`**

`search_photos()` already fetches the full matching Arrow table before slicing. After the WHERE-clause fetch and before the page slice, compute tag facets from the full result set:

```python
# collect tags from all matching rows (full arrow_table, not page_table)
from collections import Counter
tag_counter: Counter[str] = Counter()
for row_tags in arrow_table.column("tags").to_pylist():
    if row_tags:
        tag_counter.update(row_tags)
tag_facets = dict(tag_counter.most_common())
```

Pass `tag_facets` through `SearchResult` and `_result_to_dict()`.

**`src/wally/agent.py`** — add `tagFacets` to the JSON response dict.

### Schema change

`SearchResult` dataclass gains:
```python
tag_facets: dict[str, int] = field(default_factory=dict)
```

---

## Part 2 — Full-Text Search on `dc:description`

### 2a. XMP parsing — `ouestcharlie-py-toolkit`

**`src/ouestcharlie_toolkit/schema.py`** — `XmpSidecar`:
```python
description: str | None = None  # dc:description (plain text, any language)
```

**`src/ouestcharlie_toolkit/xmp.py`** — `_KNOWN_CHILDREN` and parsing:

`dc:description` is a LangAlt structure:
```xml
<dc:description><rdf:Alt><rdf:li xml:lang="x-default">caption text</rdf:li></rdf:Alt></dc:description>
```

Add to `_KNOWN_CHILDREN` so it is not captured in `_extra`. Parse after the tags block:
```python
desc_elem = desc.find(f"{dc}description")
description: str | None = None
if desc_elem is not None:
    alt = desc_elem.find(f"{rdf}Alt")
    if alt is not None:
        li = alt.find(f"{rdf}li")
        description = li.text if li is not None else None
    else:
        description = desc_elem.text  # plain string fallback
```

Add to the `XmpSidecar(...)` constructor call.

**Serialization** (`_serialize_xmp`) — write `description` back:
```python
if sidecar.description:
    desc_el = ET.SubElement(desc, f"{dc_ns}description")
    alt_el = ET.SubElement(desc_el, f"{rdf_ns}Alt")
    li_el = ET.SubElement(alt_el, f"{rdf_ns}li")
    li_el.set(f"{{{_NS_XML}}}lang", "x-default")
    li_el.text = sidecar.description
```

### 2b. LanceDB schema — `ouestcharlie-py-toolkit`

**`src/ouestcharlie_toolkit/lance_index.py`** — `PHOTO_SCHEMA`:
```python
pa.field("description", pa.string(), nullable=True),
```

Row-building helper — add:
```python
"description": entry.description or None,
```

**FTS index creation** — after `create_table()` call:
```python
await table.create_fts_index("description", replace=True)
```

LanceDB ≥ 0.20 (the project's minimum) supports FTS via `create_fts_index`. The index is stored alongside the Lance files and persisted.

**Schema migration** — the existing `_ensure_table()` / `open_or_create()` logic checks `PHOTO_SCHEMA`. The new column must be added to `_add_missing_columns()` (or equivalent migration path already in `lance_index.py`) so existing indexes gain the column without a full rebuild.

### 2c. Fields registry — `ouestcharlie-py-toolkit`

**`src/ouestcharlie_toolkit/fields.py`** — add a new `FieldDef`:
```python
FieldDef(
    name="description",
    type=FieldType.STRING_MATCH,   # reuse substring match for now
    entry_attr="description",
    sidecar_attr="description",
    lance_column="description",
    label="Description",
)
```

Add to `PHOTO_FIELDS`.

### 2d. Wally search — `ouestcharlie-wally`

**`src/wally/searcher.py` — `_build_where_clause()`**

For `description`, the standard `STRING_MATCH` path already generates `lower(column) LIKE '%value%'`. That works for substring match but bypasses the FTS index.

Add a dedicated FTS branch that uses LanceDB's FTS SQL syntax when the field is `description`:

```python
# FTS on description using LanceDB full-text search
# LanceDB SQL: match('description', 'term') — uses the FTS index
if field.name == "description":
    clauses.append(f"match(description, '{_esc(value)}')")
```

If `match()` SQL is not available in the deployed LanceDB version, fall back to `lower(description) LIKE '%value%'` with a TODO comment.

**`src/wally/agent.py`** — accept `description` as a search parameter (already flows through the generic field dispatch if it is in `PHOTO_FIELDS`). Verify.

### 2e. Search result — include `description`

`description` is already in `PhotoMatch.searchable` if `entry_attr="description"` is set in the `FieldDef`. Verify that `_match_to_dict()` serializes it into the result JSON.

---

---

## Part 3 — Partition Set Filter (replaces `root`)

### Motivation

The current `root` string restricts the search to a single subtree prefix via `starts_with(partition, 'root/')`. This is too coarse when the caller wants to target a specific set of partitions that don't share a common prefix (e.g. `["2023/summer/italy", "2024/winter/alps"]`).

The `root` parameter is replaced by `partitions: list[str]` — an explicit set of partition paths to include. An empty list means no partition filter (all partitions).

### Where the change lands

**`src/ouestcharlie_toolkit/lance_index.py` — `search_where()`**

Replace the `root: str = ""` parameter with `partitions: list[str] | None = None`:

```python
async def search_where(
    self,
    where_clause: str | None,
    partitions: list[str] | None = None,
    ...
) -> tuple[AsyncIterable[dict[str, Any]], int]:
```

New partition clause builder:
```python
if partitions:
    quoted = ", ".join(f"'{_esc(p)}'" for p in partitions)
    clauses.append(f"partition IN ({quoted})")
```

**`src/wally/searcher.py`** — `search_photos()`:
- Replace `root: str = ""` parameter with `partitions: list[str] | None = None`.
- Pass `partitions` down to `lance_index.search_where()`.

**`src/wally/agent.py`** — `_search_photos_tool()`:
- Remove `root: str = ""`, add `partitions: list[str] | None = None`.
- Update the guard that required `root` or filters: require `filters` or non-empty `partitions`.
- Update docstring accordingly.

No backward-compat shim — hard removal. Any existing client passing `root=` will receive an "unknown parameter" error, which is the desired signal to upgrade.

---

## Files to Modify

| Repo | File | Change |
|---|---|---|
| py-toolkit | `schema.py` | Add `description` to `XmpSidecar` |
| py-toolkit | `xmp.py` | Parse + serialize `dc:description` |
| py-toolkit | `lance_index.py` | Add `description` column, FTS index, migration |
| py-toolkit | `fields.py` | Add `description` `FieldDef` |
| wally | `searcher.py` | Tag facets computation; FTS WHERE clause for description |
| wally | `agent.py` | Expose `tagFacets` in result JSON |

---

## Part 4 — Camera Settings Fields (EXIF shoot metadata)

### Motivation

Several useful search queries ("show me photos shot at ISO > 3200", "wide-angle shots", "everything taken with the 85mm lens") are impossible today because shoot settings are not indexed. Adding a small set of numeric and string EXIF fields to the schema enables range filters and keyword filters on these dimensions without requiring any AI enrichment.

### Fields to add

| Field name | XMP / EXIF source | Lance type | Search type |
|---|---|---|---|
| `iso_speed` | `exif:ISOSpeedRatings` | `pa.int32()` | numeric range |
| `aperture` | `exif:FNumber` (rational) | `pa.float32()` | numeric range |
| `exposure_time` | `exif:ExposureTime` (rational, stored as seconds) | `pa.float32()` | numeric range |
| `focal_length` | `exif:FocalLength` (rational, mm) | `pa.float32()` | numeric range |
| `focal_length_35mm` | `exif:FocalLengthIn35mmFilm` | `pa.int32()` | numeric range |
| `lens_model` | `aux:Lens` (Adobe) or `exifEX:LensModel` | `pa.string()` | string match |

Lower-priority (add later if needed): `exposure_bias` (`exif:ExposureBiasValue`, float EV), `flash_fired` (bit 0 of `exif:Flash`, bool), `white_balance` (`exif:WhiteBalance`, int 0=auto/1=manual), `metering_mode` (`exif:MeteringMode`, int enum).

### Where the change lands

**`ouestcharlie-py-toolkit` — `schema.py`** — add to `XmpSidecar`:
```python
iso_speed: int | None = None            # exif:ISOSpeedRatings
aperture: float | None = None           # exif:FNumber (e.g. 2.8)
exposure_time: float | None = None      # exif:ExposureTime in seconds (e.g. 0.004 = 1/250)
focal_length: float | None = None       # exif:FocalLength in mm
focal_length_35mm: int | None = None    # exif:FocalLengthIn35mmFilm
lens_model: str | None = None           # aux:Lens or exifEX:LensModel
```

**`xmp.py`** — parsing notes:
- `exif:ISOSpeedRatings` is a `rdf:Seq` of integers; take the first element.
- `exif:FNumber`, `exif:ExposureTime`, `exif:FocalLength` are EXIF rationals (`"numerator/denominator"`); parse with the existing `_exif_rational_to_float()` helper or equivalent.
- `exif:FocalLengthIn35mmFilm` is a plain integer.
- `aux:Lens` is a plain string (Adobe namespace `http://ns.adobe.com/exif/1.0/aux/`). `exifEX:LensModel` (`http://cipa.jp/exif/1.0/`) is the CIPA standard; check both, prefer `exifEX:LensModel` if present.

**`lance_index.py`** — add columns to `PHOTO_SCHEMA` and row builder. No FTS index needed (numeric range and string LIKE are sufficient). Add to `_add_missing_columns()` migration.

**`fields.py`** — add `FieldDef` entries:
```python
FieldDef(name="iso_speed",         type=FieldType.INT_RANGE,     entry_attr="iso_speed",         label="ISO"),
FieldDef(name="aperture",          type=FieldType.FLOAT_RANGE,   entry_attr="aperture",          label="Aperture (f-number)"),
FieldDef(name="exposure_time",     type=FieldType.FLOAT_RANGE,   entry_attr="exposure_time",     label="Exposure time (s)"),
FieldDef(name="focal_length",      type=FieldType.FLOAT_RANGE,   entry_attr="focal_length",      label="Focal length (mm)"),
FieldDef(name="focal_length_35mm", type=FieldType.INT_RANGE,     entry_attr="focal_length_35mm", label="Focal length 35mm equiv."),
FieldDef(name="lens_model",        type=FieldType.STRING_MATCH,  entry_attr="lens_model",        label="Lens"),
```

If `FLOAT_RANGE` is not yet a `FieldType`, add it alongside `INT_RANGE` — the WHERE-clause builder for both is the same pattern (`column >= min AND column <= max`).

**`wally/agent.py`** — no change needed if the fields flow through the generic dispatch.

### Verification

- Parse a raw file or sidecar known to have EXIF shoot data; assert `iso_speed`, `aperture`, `exposure_time`, `focal_length` are non-None and have expected values.
- Run the indexer; query `select iso_speed, aperture, focal_length, lens_model from photos limit 10` in LanceDB.
- Search with `iso_speed_min=3200` returns only high-ISO shots; search with `lens_model="85mm"` returns the expected subset.

---

# Misc

Remove obselete fields since we introduced LanceDB
- prunable in all packages
- summary_bloom_attr, never implemented
- summary_gps_bbox

---

## Verification

1. **Unit tests** (py-toolkit):
   - Add test: XMP with `dc:description` round-trips correctly (parse → serialize → parse).
   - Add test: XMP without `dc:description` yields `description=None`, no regression on existing fields.

2. **Index rebuild test**:
   - Run whitebeard indexer on a test library; confirm `description` column appears in the Lance table.
   - Query `select description from photos limit 5` via LanceDB Python to verify values.

3. **Search test** (Wally):
   - Search with `description="sunset"` returns only photos whose XMP description contains "sunset".
   - Search with no description filter returns all photos (no regression).
   - Result JSON includes `tagFacets` with correct counts.

4. **Run existing test suite**:
   ```
   /Users/antoinehue/Code/charlie/ouestcharlie-py-toolkit/.venv/bin/python -m pytest tests/ -v
   ```
