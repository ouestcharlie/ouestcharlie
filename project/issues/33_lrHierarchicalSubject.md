# OEC-33: Read/Write `lr:hierarchicalSubject` for Darktable Hierarchical Tags

#status:open

## Context

Darktable (and Lightroom-derived tools) export hierarchical tags — e.g. `Europe|France|Paris` — via the `lr:hierarchicalSubject` XMP field (namespace `http://ns.adobe.com/lightroom/1.0/`), in addition to the flat `dc:subject` keyword list.

OuEstCharlie's XMP layer already registers the `lr` namespace prefix for serialization (`xmp.py:52`), but `lr:hierarchicalSubject` is not in `_KNOWN_CHILDREN` (`xmp.py:93-99`). It is therefore parsed as an unknown element and stashed verbatim in `sidecar._extra`, then written back unchanged on serialize (`xmp.py:594-604`).

This means:
- Hierarchy information Darktable wrote is invisible to Woof's own tag logic (search, tag facets, dedup) — only the flat `dc:subject` copy is usable, if Darktable also wrote one.
- Woof never emits `lr:hierarchicalSubject` itself, so tags added or edited via Woof never appear as hierarchical in Darktable — only as flat entries.
- `XmpSidecar.tags` (`schema.py:232`) has no hierarchy concept at all — flat `list[str]`, no separator parsing, no `Tag` dataclass.

This is a known, already-tested limitation (see `test_serialize_xmp_roundtrip_preserves_extra`, `tests/test_xmp.py:373`, using an `Europe|France|Paris` fixture) — currently the pass-through is lossless but inert.

---

## Changes

### 1. Data model — represent hierarchy without breaking the flat `tags` API

**File:** `ouestcharlie-py-toolkit/src/ouestcharlie_toolkit/schema.py` (near line 232)

Decide on representation before implementing — options:
- (a) Keep `tags: list[str]` as the flat, leaf-level view (what search/facets use today), and add a separate `hierarchical_tags: list[str] = field(default_factory=list)` storing raw `"Europe|France|Paris"`-style paths.
- (b) Fold hierarchy into `tags` using a path-like convention and derive flat/leaf tags from it on demand.

(a) is lower-risk: it doesn't change the meaning or shape of the existing `tags` field that search/facets (`OEC-23`) already depend on.

### 2. Parsing — `xmp.py`

Add `lr:hierarchicalSubject` to `_KNOWN_CHILDREN` (`xmp.py:93-99`) so it stops being captured in `_extra`. Parse its `rdf:Bag`/`rdf:Seq` of `rdf:li` strings into `hierarchical_tags`, mirroring the existing `dc:subject` parse at `xmp.py:339-343`.

### 3. Serialization — `xmp.py`

Write `sidecar.hierarchical_tags` back to `lr:hierarchicalSubject` (same container shape Darktable uses — `rdf:Bag`), alongside the existing `dc:subject` write (`xmp.py:492-497`). Only emit the element if `hierarchical_tags` is non-empty, matching the existing "omit when empty" pattern used for `dc:subject` (`test_serialize_xmp_empty_tags_omits_subject`, `tests/test_xmp.py:482`).

### 4. Reconciliation with flat `dc:subject`

Define and document the merge rule when both fields exist and diverge (e.g. Woof adds a flat tag but doesn't know its hierarchy path). Simplest option: `dc:subject` remains the source of truth for search; `hierarchical_tags` is preserved/updated independently and only used for Darktable-compatible export, with no attempt to auto-derive one from the other in this pass.

### 5. Tests

**File:** `ouestcharlie-py-toolkit/tests/test_xmp.py`

- Replace/extend `test_parse_xmp_preserves_unknown_child_element` and `test_serialize_xmp_roundtrip_preserves_extra` (lines 363, 373) — the `Europe|France|Paris` fixture should now parse into `hierarchical_tags`, not `_extra`.
- Add round-trip test: parse → serialize → parse yields identical `hierarchical_tags`.
- Add test: sidecar with only flat `tags` (no hierarchy) omits `lr:hierarchicalSubject` on write.
- Add test: sidecar with `hierarchical_tags` set writes valid `lr:hierarchicalSubject` XML that Darktable/digiKam can read (structural check only — bag of `rdf:li` under the `lr` namespace).

### 6. Documentation

- **`ouestcharlie-py-toolkit/py_toolkit_LLD.md`**: document the new field and the flat/hierarchical reconciliation rule.
- **`ouestcharlie/HLD.md`**: note hierarchical tag support if tags are otherwise described there.

---

## Verification

```bash
cd ouestcharlie-py-toolkit
.venv/bin/pytest tests/test_xmp.py -v
.venv/bin/pytest tests/ -v   # full suite to catch regressions
```

Manually confirm:
- Tag a photo hierarchically in Darktable (writes `lr:hierarchicalSubject`), run Woof indexing, verify `hierarchical_tags` is populated and round-trips unchanged on next write.
- Add a tag via Woof, reopen the sidecar in Darktable, confirm no data loss / no corruption of existing hierarchy.
