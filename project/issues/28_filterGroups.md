# OEC#28 Nested filter groups with AND / OR logic

#status:done

## Context

All search filters were combined with implicit AND (flat `dict[str, FilterValue]`). This made OR queries impossible. The new design introduces **filter groups**: a group uses `all` (AND) or `any` (OR) as its key, with a list of children that are either field filter leaves or nested groups.

## Data Model

### Internal (`searcher.py`)

Two dataclasses alongside the existing filter value types:

```python
@dataclass(frozen=True)
class FilterLeaf:
    """A single field predicate."""
    field: str        # FieldDef.name
    value: FilterValue

@dataclass(frozen=True)
class FilterGroup:
    """Boolean combination of leaves and/or nested groups."""
    logic: str = "AND"                          # "AND" | "OR"
    children: list[FilterLeaf | FilterGroup] = field(default_factory=list)
```

`SearchPredicate` accepts a single `root: FilterGroup` parameter. No legacy flat-dict form.

`_build_group(group, field_config) -> str | None` — recursive SQL builder. OR sub-expressions with >1 child are wrapped in parentheses to compose correctly inside parent AND expressions.

### Wire format (MCP / `filters` dict)

A **group node** uses `all` (AND) or `any` (OR) as its key, with a list value of children. Each child is either:
- A **field filter leaf**: single-key dict `{"fieldName": filterValue}`.
- A **nested group**: a dict with an `all` or `any` key.

The flat dict form (no `all`/`any` key) is an implicit AND of its field entries.

```json
// Flat — implicit AND
{"make": "nikon", "rating": {"min": 4}}

// OR — two values for the same field
{"any": [{"make": "nikon"}, {"make": "canon"}]}

// Nested: shot in 2024 AND (tagged vacation OR rated 5★)
{"all": [
  {"dateTaken": {"min": "2024", "max": "2024"}},
  {"any": [
    {"tags": ["vacation"]},
    {"rating": {"min": 5, "max": 5}}
  ]}
]}
```

## Changes Made

### `ouestcharlie-wally/src/wally/searcher.py`

- Added `FilterLeaf` and `FilterGroup` dataclasses.
- `SearchPredicate.__init__` takes only `root: FilterGroup | None` (legacy `filters=` kwarg removed).
- `_build_where_clause` delegates to `_build_group` (recursive). OR groups with >1 child are parenthesised.

### `ouestcharlie-wally/src/wally/agent.py`

- Added `_parse_filter_node(raw, field_config) -> FilterLeaf | FilterGroup` — recursive parser:
  - `{"all": [...]}` → AND FilterGroup
  - `{"any": [...]}` → OR FilterGroup
  - Flat dict → AND FilterGroup (leaves); single-key flat dict → FilterLeaf directly (unwrapped)
- Replaced `_check_filters` with `_parse_filter_node`.
- Call site wraps a bare `FilterLeaf` result in a `FilterGroup` before passing to `SearchPredicate`.

### `ouestcharlie-woof/src/woof/server.py`

- Tool description updated with `all`/`any` group syntax examples.

### Tests

- `tests/test_where_clause.py`: AND/OR group SQL generation, nested composition, paren wrapping, single-child no-paren
- `tests/test_searcher.py`: `test_or_group_returns_union_of_results`, `test_nested_and_or_group`
- `tests/test_search_validation.py`: rewritten to test `_parse_filter_node` (flat dict, `all`, `any`, nested, unknown field)
- All ~30 call sites migrated from `SearchPredicate(filters={...})` to `SearchPredicate(root=FilterGroup(children=[FilterLeaf(...)]))`

## Verification

All 129 tests pass: `.venv/bin/pytest tests/ -v` in `ouestcharlie-wally`.

Via MCP inspector:
1. Flat dict (implicit AND): `filters={"make": "nikon", "rating": {"min": 4}}`
2. OR group: `filters={"any": [{"tags": ["vacation"]}, {"rating": {"min": 5}}]}`
3. Nested: `filters={"all": [{"dateTaken": {"min": "2024", "max": "2024"}}, {"any": [{"make": "nikon"}, {"make": "canon"}]}]}`
4. Unknown field → `ToolError` with clear message

## Documentation to update

- `ouestcharlie-wally/wally_LLD.md`: update `search_photos` parameter table, query execution section, filter types table
