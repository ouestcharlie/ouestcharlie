# OEC-33b: Case-insensitive tag search

#status:done

Status flow: draft (write spec) -> open (review spec) -> todo (spec validated) -> ongoing (implementation started) -> done (merged)

## Context

OEC-33 made tags hierarchical paths and kept matching case-sensitive and exact
per level. Searching `paris` doesn't find a photo tagged `Places|Europe|France|Paris`,
and two photos tagged `Paris` and `paris` count as two separate facets.

Tags come from several tools (darktable, Lightroom, digiKam, Woof skills,
agents), and callers type tag names freely, so case differences are common and
meaningless to the user. The other string filters are already case-insensitive
(`lower(col) LIKE …`, `wally/searcher.py:405-412`).

Intended outcome:

1. A tag filter matches regardless of case, at any level and for any subtree,
   with the `LABEL_LIST` index still used.
2. Facets merge spellings that differ only by case.
3. Excluded tag prefixes match regardless of case.
4. The Woof skills don't add a tag that already exists with a different case.

The stored tags keep the user's spelling: sidecars, the index `tags` column and
the gallery are unchanged.

Out of scope: accent-insensitive matching (`Ete` vs `Été`), see Open points.

---

## Design decisions

### Fold at write time, compare exactly

The index `tag_terms` column holds **folded** terms, and the filter value is
folded the same way before the `array_has` comparison. The predicate stays an
exact match, so the `LABEL_LIST` index on `tag_terms` is still used.

Folding `tag_terms` at query time (`list_transform(tag_terms, x -> lower(x))`)
was rejected: the scalar index can't serve it, so every tag filter would scan
the table.

`tags` keeps its original spelling. It is what the gallery shows and what is
written back to sidecars.

### Folding rule

```python
def fold(term: str) -> str:
    return unicodedata.normalize("NFC", term).lower()
```

- NFC makes a precomposed `é` and `e` + combining accent compare equal.
- `str.lower()` rather than `str.casefold()`: it matches DuckDB's
  `lower()`, which the facet query uses (see section 3), so search and facets
  agree on what is "the same tag". The cost is that `ß` and `SS` aren't merged,
  which is acceptable.

`fold` is applied in Python everywhere except in the facet SQL, which uses
`lower(nfc_normalize(…))`, its DuckDB equivalent.

### Spelling shown when several exist

Where several spellings of the same tag meet (facets, skill writes), the one
kept is:

- **facets**: the most frequent spelling, ties broken by sort order so the
  result is deterministic;
- **skill writes**: the spelling already in the sidecar.

Leaf deduplication in the sidecar (`leaf_paths`) stays case-sensitive: OuEstCharlie
never rewrites the user's tags on its own.

---

## Changes

### 1. Folding helper and `tag_terms`

**File:** `ouestcharlie-py-toolkit/src/ouestcharlie_toolkit/tags.py`

- Add `fold(term: str) -> str` (above).
- `tag_terms()` (line 69) emits folded terms, deduplicated after folding:
  `Places|Europe` and `places|europe` give one term `places|europe`.
- `is_excluded()` (line 61) compares folded path and prefixes:
  `Darktable|format|jpg` is excluded by the default `darktable` prefix. The
  whole-level rule is unchanged (`darktable-fans` is still kept).

`excluded_tag_prefixes` keep the user's spelling in `config.json`; only the
comparison is case-insensitive.

### 2. Search filter

**File:** `ouestcharlie-wally/src/wally/searcher.py` (line 403)

```python
# Before
return [f"array_has(tag_terms, '{_esc(normalize_path(v) or v)}')" for v in fv.values]

# After
return [f"array_has(tag_terms, '{_esc(fold(normalize_path(v) or v))}')" for v in fv.values]
```

AND semantics, subtree and any-level matching are unchanged.

### 3. Facets

**File:** `ouestcharlie-py-toolkit/src/ouestcharlie_toolkit/partition_summary.py` (lines 36-52, 170-171)

- `_TAG_FACETS_SQL` groups nodes by `lower(nfc_normalize(node))` and still
  counts `DISTINCT rid`, so a photo tagged both `Paris` and `paris` counts once.
  It also returns the node's display spelling (most frequent, ties broken by
  sort order).
- The keys must still form a tree that clients can rebuild by splitting on
  `|`. A node's spelling is chosen independently of its parent's, so they could
  disagree (`Places` but `places|Europe`). The Python side builds the keys top
  down: a node's key is its parent's key + `|` + the last level of its chosen
  spelling. Every ancestor is present in the result, so the parent's key always
  exists.

The `tag_facets` shape and the MCP `tagFacets` contract are unchanged. A key is
one of the stored spellings, and searching it returns every spelling.

### 4. Index schema

**File:** `ouestcharlie-py-toolkit/src/ouestcharlie_toolkit/schema.py` (line 17)

Rows indexed under OEC-33 hold mixed-case `tag_terms`. A folded filter would
silently miss them.

- If OEC-33b ships in the same release as OEC-33 (schema v6 not released yet,
  which is the case today: 0.16.0 predates the OEC-33 commit), no bump is
  needed.
- Otherwise bump `SCHEMA_VERSION` and `LOWEST_SCHEMA_VERSION` to 7.
  `index_library` then forces a full reindex (OEC-38a). Sidecars aren't
  rewritten.

### 5. Woof skills: no duplicates that differ only by case

**Files:** `ouestcharlie-woof/plugins/woof-photo-workflows/skills/*/scripts/tag_files.py`,
`…/scripts/sort_photos.py`

`tag_files.py`:

- `normalize_tags()` (line 120) deduplicates case-insensitively and keeps the
  first spelling: `--tags Paris paris` adds one tag.
- `apply()` (line 182) maps each requested path onto the sidecar's spelling,
  level by level: for each prefix of the path, if the sidecar's current tags
  hold the same prefix with a different case, that spelling is used. Example:
  the sidecar has `Places|Europe`, `--tags "places|europe|France"` adds
  `Places|Europe|France`.
- `_merge_bag()` (line 152) treats an item as present when its folded form is
  present, for both `lr:hierarchicalSubject` and `dc:subject`. Existing entries
  are never rewritten.
- `new_tags` and the notes use the same comparison, so a re-run with a
  different case reports "tags already present".

`sort_photos.py`: `normalize_tags()` (line 143) gets the same
case-insensitive deduplication. `enrich_sidecar` only writes sidecars without
tags, so nothing else changes there.

The scripts stay identical across both skills (enforced by a test).

### 6. Tool descriptions and field label

**Files:** `ouestcharlie-wally/src/wally/agent.py` (lines 49, 102),
`ouestcharlie-woof/src/woof/mcp_server.py` (line 64),
`ouestcharlie-py-toolkit/src/ouestcharlie_toolkit/fields.py` (`tags` label)

State that tag matching ignores case, and that `tagFacets` merges spellings
that differ only by case.

### 7. Tests

**`ouestcharlie-py-toolkit/tests/test_tags.py`**:

- `fold`: case, NFC (precomposed vs combining `é` fold equal).
- `tag_terms`: folded; `Places|Europe` + `places|Europe|France` gives no
  duplicate terms.
- `is_excluded`: `Darktable|format` excluded by `darktable`; `DARKTABLE`
  prefix excludes `darktable|changed`; `Darktable-fans` kept.

**`ouestcharlie-py-toolkit/tests/test_xmp.py`**: a sidecar with
`Darktable|format|jpg` in `lr:hierarchicalSubject` → excluded, and written back
unchanged.

**`ouestcharlie-py-toolkit/tests/test_lance_index.py`**: `tag_terms` folded;
`row_to_photo_entry` returns `tags` with the original spelling.

**`ouestcharlie-py-toolkit/tests/test_partition_summary.py`**:

- `Paris` on two photos and `paris` on one → one key `…|Paris`, count 3.
- A photo tagged both `Paris` and `paris` counts once.
- Keys form a tree: with `Places|Europe` on three photos and `places|europe|France`
  on one, the keys are `Places`, `Places|Europe`, `Places|Europe|France`.
- Tie on spelling frequency → deterministic choice.

**`ouestcharlie-wally/tests`**: `{"tags": ["paris"]}`,
`{"tags": ["PLACES|europe"]}` and `{"tags": ["Places|Europe|France|Paris"]}`
each match `Places|Europe|France|Paris`; AND across two tags with mixed case.

**Skills** (`tag_files.py`):

- `--tags paris` on a sidecar holding `Paris` → no change, "tags already present".
- `--tags "places|europe|France"` on a sidecar holding `Places|Europe` →
  `Places|Europe|France` added to `lr:hierarchicalSubject`; `dc:subject` gets
  `France` only.
- `--tags Paris paris` → one tag added.

### 8. Documentation

- `ouestcharlie-py-toolkit/py_toolkit_LLD.md` (line 45, Hierarchical tags):
  `tag_terms` is folded with `fold`; why folding is done at write time; facets
  merge spellings; `excluded_tag_prefixes` are case-insensitive.
- `ouestcharlie-wally/wally_LLD.md` (line 156): tag filter values are folded;
  matching ignores case.
- `ouestcharlie-woof` LLD/README: `excluded_tag_prefixes` matching ignores case.
- Woof skills `SKILL.md`: tags are matched regardless of case; the existing
  spelling is kept.
- OEC-33 spec: the "Case is kept and matching stays case-sensitive" sentence
  and the "Case and synonyms" open point now point to OEC-33b.

---

## Verification

1. Unit tests:
   ```bash
   cd ouestcharlie-py-toolkit && uv run pytest tests/ -v
   cd ouestcharlie-wally && uv run pytest tests/ -v
   cd ouestcharlie-woof && uv run pytest tests/ -v
   ```
2. Tag one photo `Places|Europe|France|Paris` in darktable and another `paris`
   with a Woof skill. Run `index_library` (full reindex if the schema was
   bumped).
3. `search_photos` with `{"tags": ["PARIS"]}` returns both photos.
   `{"tags": ["places|europe"]}` returns the first one.
4. `get_summary` `tagFacets` has a single Paris key with count 2, and its keys
   still split into a consistent tree.
5. The search result `tags` and the gallery show `Places|Europe|France|Paris` and
   `paris`, as written.
6. Run `tag_files.py --tags "places|europe|France|PARIS"` on the first photo:
   the sidecar is unchanged and the note says "tags already present".

---

## Open points

- **Accent-insensitive matching.** `Ete` doesn't match `Été`. Removing accents
  in `fold` (NFD, drop combining marks) would help with French place names
  typed without accents, but it widens matching more than case does (e.g.
  `Pâte` and `Pâté` would no longer be distinct). Undecided. If adopted, it
  belongs in `fold` and the facet SQL equivalent (`strip_accents`), with a
  schema bump.
- **`ß` vs `SS`.** Not merged by `lower()`. `casefold()` would merge them but
  diverge from DuckDB's `lower()` used for facets. Proposal: accept.
