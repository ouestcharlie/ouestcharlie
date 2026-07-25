# OEC-35: Accept stringified object/array arguments from CoWork's MCP client

#status:done

## Context

`search_photos` and `browse_gallery` in Woof's MCP server started failing when called from Claude
CoWork, while working fine from Claude Desktop Chat.

**Root cause:** CoWork's MCP client serializes object- and array-typed tool arguments (dicts,
lists) to JSON strings instead of sending them as native JSON objects/arrays. `search_photos`
declares `filters: dict | None` and `full_text_filter: dict | None`; `browse_gallery` declares
`session_tokens: list[str]`. When CoWork sends a JSON string instead of a real object, argument
validation either rejects the call or passes the raw string through, surfacing as an opaque
downstream failure.

This is a client-side serialization bug in CoWork, not something Woof can fix at the root. The
workaround widens the accepted parameter types to include `str` and coerces via `json.loads` when
a string arrives, raising a clear `ValueError` if it isn't valid JSON or doesn't decode to the
expected type.

---

## Changes

**File:** `ouestcharlie-woof/src/woof/mcp_server.py`

1. New `_coerce_json_param(value, expected_type, param_name)` helper: passes through the native
   type or `None` unchanged, `json.loads`-parses a string and validates the decoded type, else
   raises `ValueError`.
2. `search_photos`: `filters` and `full_text_filter` typed as `dict | str | None`, run through the
   helper before being forwarded to the backend call.
3. `browse_gallery`: `session_tokens` typed as `list[str] | str`, run through the helper before
   use.

**File:** `ouestcharlie-woof/tests/test_mcp_server.py` — added coverage for: stringified `filters`
decoded correctly, malformed JSON raises, stringified `full_text_filter` decoded correctly,
stringified `session_tokens` decoded and resolved correctly.

---

## Verification

- Run `.venv/bin/pytest tests/ -v` in `ouestcharlie-woof/` — all pass including the new coercion
  tests.
- Manual: exercise `search_photos` (with filters) and `browse_gallery` from Claude CoWork —
  confirm both succeed instead of failing on object-typed arguments.

Merged via PR [#40](https://github.com/ouestcharlie/ouestcharlie-woof/pull/40) (commits
`f783a8b`, `75cdb67`).
