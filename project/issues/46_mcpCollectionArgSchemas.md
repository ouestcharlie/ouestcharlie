# OEC-46: Clean array/object schemas for Woof MCP collection arguments

#status:done

## Context

Claude Desktop flagged that `index_library`'s `partition_scope` argument renders as a
**string** instead of an **array of strings**. Root cause: it is declared
`partition_scope: list[str] | None = None` in `ouestcharlie-woof/src/woof/mcp_server.py`.
The `| None` union makes pydantic emit an `anyOf: [array, null]` schema, which Claude
Desktop collapses into a plain string input.

Auditing every collection/object argument in Woof surfaced a deeper inconsistency. Woof
already carries `_coerce_json_param` because "some MCP clients (Claude Desktop's CoWork
mode) serialize object/array-typed tool arguments to JSON strings." The other tools opted
into tolerance by adding `str` to the type union and coercing in the body — but that union
is exactly what makes them render as `anyOf`/string as well. `partition_scope` is the
worst case: `list[str] | None` gives it neither a clean schema nor coercion.

| Tool | Arg | Current type | Coerced? | Schema |
|---|---|---|---|---|
| `get_summary` | `filters`, `full_text_filter` | `dict \| str \| None` | yes (body) | anyOf |
| `search_photos` | `filters`, `full_text_filter` | `dict \| str \| None` | yes (body) | anyOf |
| `browse_gallery` | `session_tokens` | `list[str] \| str` | yes (body) | anyOf |
| `index_library` | `partition_scope` | `list[str] \| None` | no | anyOf(null) |

Key finding (verified against the exact `fastmcp` v2 Woof imports): body-level coercion
and a clean schema are mutually exclusive **only** when coercion runs after validation. A
pydantic **`BeforeValidator`** runs *during* validation, so it reconciles both — it parses
a JSON-stringified value while the annotation's base type still drives a clean
`array`/`object` schema. Verified end-to-end:

- `Annotated[list[str], BeforeValidator(...), Field(default_factory=list)]` →
  `{"type":"array","items":{"type":"string"}}`, arg optional (not `required`), accepts
  both `["a"]` and `'["a"]'`, no mutable default (no ruff B006).
- Same shape for `dict` → `{"type":"object", ...}`.

Intended outcome: every collection argument renders strictly correctly *and* keeps the
CoWork string-tolerance the codebase depends on — one reusable pattern replacing the
scattered `| str` unions and body-level coercion.

---

## Changes

**File:** `ouestcharlie-woof/src/woof/mcp_server.py`

### 1. Imports (top-level only)

Extend `from typing import Any` with `Annotated`; add
`from pydantic import BeforeValidator, Field`.

### 2. Validator factory + reusable annotated aliases

Fold the existing `_coerce_json_param` parsing rules into a `BeforeValidator` factory and
define reusable aliases near the top of the module (same JSON-string parsing, same clear
`ValueError` on undecodable input):

```python
JsonList = Annotated[list[str], BeforeValidator(_json_coercer(list, "…")), Field(default_factory=list)]
JsonDict = Annotated[dict,      BeforeValidator(_json_coercer(dict, "…")), Field(default_factory=dict)]
```

### 3. Migrate signatures, drop body coercion

- `index_library`: `partition_scope: JsonList` (remove `partition_scope = partition_scope or []`)
- `get_summary` / `search_photos`: `filters: JsonDict`, `full_text_filter: JsonDict`
  (remove the two `_coerce_json_param(...)` lines each)
- `browse_gallery`: `session_tokens: JsonList` (remove the body coercion)

Semantic tweak for the filter "omitted" case: today an omitted filter is `None` and
skipped when building `args`. With `default_factory=dict` it becomes `{}`; preserve intent
by guarding with `if parsed_filters:` (truthy) instead of `is not None`, so an empty dict
means "no filter".

### 4. Retire the old helper

Remove the standalone `_coerce_json_param` once no body calls remain, or keep it as the
shared parsing primitive the validator delegates to (prefer folding it in — one code path).

Scalar optional args (`library_name`, `library_type`, `sort_by`, `sort_order`, the
booleans) already produce clean schemas and are left unchanged. Whitebeard's
`index_partition_scope` (`ouestcharlie-whitebeard/src/whitebeard/agent.py`) already
declares `partition_scope: list[str]` and is unaffected.

---

## Verification

1. Lint: `cd ouestcharlie-woof && uv tool run ruff check src/woof/mcp_server.py`
2. Schema check — every migrated arg exposes `type: array` / `type: object` with **no**
   `anyOf`, and none is newly `required` (iterate `mcp._list_tools()` inputSchemas, or use
   the MCP inspector).
3. Tests: `cd ouestcharlie-woof && .venv/bin/pytest tests/test_mcp_server.py -v`.
   - Existing `test_index_library_with_partition_scope` and the filter/session-token
     coercion tests must still pass.
   - Add a test per migrated arg passing a JSON **string** (e.g. `'["2024/2024-07"]'`,
     `'{"rating":5}'`) and asserting it is forwarded to the agent as a native list/dict.
4. In Claude Desktop, confirm `index_library` now prompts for a list, and that CoWork
   (stringified args) still succeeds against `search_photos` / `browse_gallery`.
