# OEC-48: Strengthen search argument validation (sort field + filter sub-keys)

#status:draft

Status flow: draft (write spec) -> open (review spec) -> todo (spec validated) -> ongoing (implementation started) -> done (merged)

## Context

The `sort_by` argument on `search_photos` is confusing and unsafe:

- **Naming mismatch on the same field.** `sort_by` defaults to `date_taken` — the snake_case
  LanceDB *column* (`FieldDef.entry_attr`) — while `filters` and `list_search_fields` use the
  camelCase field *name* (`dateTaken`). The same underlying field is spelled two different ways
  on the same tool, depending on which argument you use.

- **Unknown keys are silently accepted.** `sort_by` is passed straight through to LanceDB's
  `order_by`. An unknown column raises inside LanceDB and is caught in `lance_index.search_where`,
  which falls back to ordering by `filename`. The caller receives a normal, successfully-sorted-
  looking response. Observed: passing `sort_by="not_a_real_field_xyz"` returned a normal 15-result
  response. Two consequences follow: a typo'd sort silently returns arbitrary order, and a
  successful call is **not** evidence that a field exists.

- **No documented list of sortable fields.** There is no way for a caller to discover which fields
  can be sorted on.

Filters already do the right thing: an unknown filter field is rejected with a clear error in
`_parse_filter_node` ("Unknown filter field: '…'. Call list_search_fields to discover available
fields."). Sort should honor the same contract: accept `list_search_fields` names, reject unknown
or non-sortable keys, and advertise what is sortable.

**Intended outcome:** `sort_by` accepts the same field names as filters and `list_search_fields`,
rejects invalid keys instead of silently reordering, and `list_search_fields` tells callers which
fields are sortable.

### The same class of bug in filter sub-keys

`filters` validates the *top-level* field name (`_parse_filter_node` rejects unknown fields) but
**not the sub-keys** of a field's value. In `_parse_filter_value`, range types read only
`raw.get("min")`/`raw.get("max")`, `GPS_BOX` reads only the four `min/maxLat/Lon` keys, and the
`STRING_MATCH` dict form reads only `value`/`mode` — every other key is ignored. When both known
keys end up `None`, the leaf resolves to `None` and `_parse_filter_node` drops it, so the query
silently matches **everything**.

Observed: `{"dateTaken": {"from": "2024", "to": "2025"}}` (using `from`/`to` instead of
`min`/`max`) returns the whole library with no error — the filter was silently discarded. Same for
a misspelled GPS bound, an unknown `STRING_MATCH` key, or an invalid `mode` (which silently falls
back to `contains`).

**Intended outcome:** reject unknown/misspelled sub-keys, empty range/GPS objects, and invalid
`mode` values with a clear `ValueError`, mirroring the top-level field-name contract.

---

## Changes

### 1. Sortable-field taxonomy (py-toolkit)

**File:** `ouestcharlie-py-toolkit/src/ouestcharlie_toolkit/fields.py`

Add a single source of truth for which field *types* are sortable, so that adding a new field to
`PHOTO_FIELDS` needs no change in the sort-validation code (preserving the module's existing
"add a FieldDef entry only" invariant). Sortable = scalar single-value columns; collections, GPS,
text and descriptive fields are not.

```python
# Sortable field types: scalar single-value columns that map to a LanceDB
# column supporting ORDER BY. Collections (tags), GPS boxes, full-text and
# descriptive fields are excluded.
SORTABLE_FIELD_TYPES: frozenset[FieldType] = frozenset({
    FieldType.DATE_RANGE,
    FieldType.INT_RANGE,
    FieldType.FLOAT_RANGE,
    FieldType.STRING_MATCH,
    FieldType.BOOL,
})
```

Expose a small helper (module-level function or `FieldDef.sortable` property) so callers do not
re-derive the rule:

```python
def is_sortable(fdef: FieldDef) -> bool:
    return fdef.type in SORTABLE_FIELD_TYPES
```

### 2. Validate and translate `sort_by` in Wally

**File:** `ouestcharlie-wally/src/wally/agent.py` (search_photos tool, around lines 235–275)

Before calling `searcher.search_photos`, resolve `sort_by` from a `list_search_fields` *name* to its
LanceDB *column* (`entry_attr`). Reject the value when it is unknown or refers to a non-sortable
field, reusing the filter-error wording. Change the default from `date_taken` to `dateTaken`.

```python
# Before
sort_by: str = "date_taken",
...
sort_by=sort_by,

# After
sort_by: str = "dateTaken",
...
sort_by=_resolve_sort_column(sort_by, PHOTO_FIELDS),
```

`_resolve_sort_column` maps `name -> entry_attr` for sortable fields and raises on anything else,
mirroring `_parse_filter_node`:

```python
def _resolve_sort_column(name: str, field_config: list[FieldDef]) -> str:
    for fdef in field_config:
        if fdef.name == name and is_sortable(fdef):
            return fdef.entry_attr
    raise ValueError(
        f"Unknown or unsortable sort field: '{name}'. "
        "Call list_search_fields to discover sortable fields."
    )
```

Wrap the `ValueError` as `ToolError` at the tool boundary the same way `_get_summary_tool` and the
filter path already do.

### 3. Expose `sortable` in `list_search_fields`

**File:** `ouestcharlie-wally/src/wally/agent.py` (list_search_fields, around lines 128–166)

Add a `sortable` boolean to each descriptor in `sql_fields`, and note in the docstring/`filterFormat`
guidance that `sort_by` uses these `name` values.

```python
sql_fields = [
    {
        "name": fdef.name,
        "type": fdef.type.name,
        "filterFormat": _FIELD_FORMAT[fdef.type],
        "sortable": is_sortable(fdef),
    }
    for fdef in PHOTO_FIELDS
    if fdef.type is not FieldType.TEXT
]
```

### 4. Update the Woof tool default and docs

**File:** `ouestcharlie-woof/src/woof/mcp_server.py` (`_search_photos_tool`, around line 343)

Change the default to match the new contract and mention that `sort_by` uses `list_search_fields`
names:

```python
# Before
sort_by: str = "date_taken",

# After
sort_by: str = "dateTaken",
```

Update the tool docstring / `_FILTER_SYNTAX_DOC` to state that `sort_by` takes a `list_search_fields`
field name and that unknown or non-sortable names are rejected.

### 5. Keep the LanceDB fallback as defense-in-depth

**File:** `ouestcharlie-py-toolkit/src/ouestcharlie_toolkit/lance_index.py` (search_where, ~487–495)

Leave the try/except filename fallback in place — it still protects against internal misuse — but
note in a comment that, with Wally-side validation, the fallback is no longer reachable from caller
input. Consider raising the log level from `warning` since reaching it now indicates a bug, not bad
user input.

### 5b. Validate `sort_order` in Wally

**File:** `ouestcharlie-wally/src/wally/agent.py` (search_photos tool)

Same silent-fallback bug class as `sort_by`: `searcher.py` computes
`order_desc=(sort_order == "desc")`, so any value that is not exactly `"desc"` (a typo like
`"descending"`, `"DESC"`, or an empty string) silently sorts **ascending** and returns a
normal-looking result. Validate `sort_order ∈ {asc, desc}` at the tool boundary via
`_validate_sort_order`, raising `ValueError` (wrapped as `ToolError`) on anything else, mirroring
the `sort_by` contract.

```python
_VALID_SORT_ORDERS = frozenset({"asc", "desc"})

def _validate_sort_order(order: str) -> str:
    if order not in _VALID_SORT_ORDERS:
        raise ValueError(f"Invalid sort_order: '{order}'. Expected 'asc' or 'desc'.")
    return order
```

Tests: valid `asc`/`desc` pass through; `descending`/`ascending`/`DESC`/`""`/`up` are rejected.

### 6. Validate filter sub-keys in Wally

**File:** `ouestcharlie-wally/src/wally/agent.py` (`_parse_filter_value`)

Reject unrecognized sub-keys instead of silently ignoring them, mirroring the top-level
field-name contract. A shared helper `_reject_unknown_subkeys(fdef, raw, allowed)` raises a
`ValueError` listing the offending keys and the allowed set.

- **Range types** (`DATE_RANGE`, `INT_RANGE`, `FLOAT_RANGE`): require a dict; allow only
  `min`/`max`; reject a dict where both bounds are absent/`None` (empty object) with
  "expects at least one of 'min'/'max' with a value". A non-dict value (e.g. `{"rating": 5}`)
  is rejected too.
- **`GPS_BOX`**: require a dict; allow only `minLat`/`maxLat`/`minLon`/`maxLon`; reject when all
  four are absent.
- **`STRING_MATCH` dict form**: allow only `value`/`mode`; require `value` (missing/`None` now
  errors instead of dropping the leaf); validate `mode ∈ {contains, startswith, exact}` (an
  invalid mode previously fell back to `contains` silently).

### 7. Tests

**Files:** `ouestcharlie-wally/tests/` and `ouestcharlie-py-toolkit/tests/`

- Unknown `sort_by` (e.g. `not_a_real_field_xyz`) raises a clear error — parallels the existing
  unknown-filter-field test.
- Non-sortable field (e.g. `tags`, `gps`, `description`) is rejected.
- A camelCase name (`dateTaken`, `rating`) resolves to the correct column and sorts correctly.
- Default `sort_by` (`dateTaken`) sorts by date descending.
- `list_search_fields` output includes `sortable` per field, `True` for scalars and `False` for
  collections / GPS / text.
- Filter sub-keys: `from`/`to` on a date range rejected; empty range object rejected; non-dict
  range rejected; unknown int-range key rejected; unknown/empty GPS keys rejected; unknown
  `STRING_MATCH` key, invalid `mode`, and missing `value` rejected.

### 8. Documentation

- `ouestcharlie-wally/wally_LLD.md` — document the sort contract: `sort_by` uses
  `list_search_fields` names, describe the type-based sortable rule (do not enumerate every field),
  and note that unknown/non-sortable keys are rejected.
- `ouestcharlie-py-toolkit/py_toolkit_LLD.md` — document the `SORTABLE_FIELD_TYPES` / `is_sortable`
  helper if the taxonomy addition warrants it.
- Note the filter sub-key contract (unknown sub-keys / empty range objects / invalid `mode`
  rejected) wherever the filter-validation behavior is described.

---

## Verification

- `list_search_fields` returns a `sortable` boolean on every field descriptor.
- `search_photos(..., sort_by="dateTaken")` sorts by date; `sort_by="rating"` sorts by rating.
- `search_photos(..., sort_by="not_a_real_field_xyz")` returns a clear error — **not** a normal
  result set.
- `search_photos(..., sort_by="tags")` (non-sortable) is rejected.
- `search_photos(..., sort_order="descending")` returns a clear error — **not** an ascending
  result set.
- `search_photos(filters={"dateTaken": {"from": "2024", "to": "2025"}})` returns a clear error —
  **not** the whole library.
- Run the suites:
  - `cd ouestcharlie-wally && .venv/bin/pytest tests/ -v`
  - `cd ouestcharlie-py-toolkit && .venv/bin/pytest tests/ -v`
