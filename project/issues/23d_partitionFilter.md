# Add `directory` filter and remove standalone `partitions` param

#status:done

## Context

The `partitions: list[str]` MCP parameter on `search_photos` (both Woof and Wally) does exact partition path matching. Replace it with a `directory` filter inside the standard `filters` dict, supporting flexible partial matching (`startswith` / `contains`). This unifies partition-scoping with the rest of the filter API.

## Changes Required

### 1. `ouestcharlie-py-toolkit/src/ouestcharlie_toolkit/fields.py`

Add `directory` FieldDef at the end of `PHOTO_FIELDS`:
```python
FieldDef(
    name="directory",
    type=FieldType.STRING_MATCH,
    entry_attr="partition",   # maps to the LanceDB `partition` column
    label="Directory",
    # no sidecar_attr — partition is assigned by the indexer, not from XMP
),
```

### 2. `ouestcharlie-wally/src/wally/searcher.py`

**Extend `StringFilter`** with an optional `mode` field:
```python
@dataclass(frozen=True)
class StringFilter:
    value: str
    mode: str = "contains"  # "contains" | "startswith"
```

**Update `_build_where_clause`** STRING_MATCH branch:
```python
elif isinstance(fv, StringFilter) and fdef.type is FieldType.STRING_MATCH:
    col = fdef.entry_attr
    escaped = _esc(fv.value.lower())
    if fv.mode == "startswith":
        clauses.append(f"lower({col}) LIKE '{escaped}%'")
    else:
        clauses.append(f"lower({col}) LIKE '%{escaped}%'")
```

### 3. `ouestcharlie-wally/src/wally/agent.py`

**Remove `partitions` param** from `_search_photos_tool`. Pass `partitions=None` to `searcher.search_photos()`.

**Extend STRING_MATCH parsing** to accept dict form (line ~212):
```python
elif fdef.type == FieldType.STRING_MATCH:
    if isinstance(raw, str) and raw:
        predicate_filters[fdef.name] = StringFilter(value=raw)
    elif isinstance(raw, dict) and isinstance(raw.get("value"), str) and raw["value"]:
        predicate_filters[fdef.name] = StringFilter(
            value=raw["value"],
            mode=raw.get("mode", "contains"),
        )
```

**Update `_FORMAT`** for STRING_MATCH in `list_search_fields`:
```python
FieldType.STRING_MATCH: (
    'string (case-insensitive substring match) or '
    '{"value": "...", "mode": "startswith"|"contains"}'
),
```

### 4. `ouestcharlie-woof/src/woof/server.py`

**Remove `partitions` param** from `search_photos` MCP tool signature and docstring.
**Remove** the `if partitions is not None: args["partitions"] = partitions` forwarding block.

### 5. Tests

**Wally `tests/test_searcher.py`**:
- Update `test_root_parameter_limits_search_to_subtree` → rename and rework to test `directory` filter via `SearchPredicate(filters={"directory": StringFilter("2024/07", mode="startswith")})`
- Add test: `directory` filter with `contains` mode
- Add test: `startswith` generates correct SQL (`LIKE '2024%'`)
- Add test: plain string value for `make`/`model` still works (backward compat)

**Woof `tests/test_server.py`**:
- Remove any test asserting `args_passed.get("partitions")` from the `partitions` param path

## Verification

1. `.venv/bin/pytest tests/ -v` in both `ouestcharlie-wally` and `ouestcharlie-woof`
2. `.venv/bin/pytest tests/ -v` in `ouestcharlie-py-toolkit`
3. Via MCP inspector: `list_search_fields` → `directory` appears with updated format string
4. `search_photos` with `filters: {"directory": {"value": "2024", "mode": "startswith"}}` → only photos under `2024/` partitions returned
5. `search_photos` with `filters: {"directory": "holiday"}` → contains match works
