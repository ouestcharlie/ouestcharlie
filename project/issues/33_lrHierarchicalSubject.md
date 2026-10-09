# OEC-33: Hierarchical tags from `lr:hierarchicalSubject` (darktable-compatible)

#status:done

Status flow: draft (write spec) -> open (review spec) -> todo (spec validated) -> ongoing (implementation started) -> done (merged)

## Context

darktable, Lightroom and digiKam organize tags as a hierarchy, e.g.
`Places|Europe|France|Paris`. In XMP, a hierarchy is stored in two places:

- `lr:hierarchicalSubject` (namespace `http://ns.adobe.com/lightroom/1.0/`): an
  `rdf:Bag` of full paths, `|`-separated. Flat tags are single-level paths.
- `dc:subject`: an `rdf:Bag` of flat keywords. darktable and Lightroom write
  every component of every path there (`Places`, `Europe`, `France`, `Paris`),
  so that tools without hierarchy support still find the photo.

When `lr:hierarchicalSubject` is present, darktable reads tags from it and
ignores `dc:subject`.

OuEstCharlie only knows `dc:subject`:

- `lr:hierarchicalSubject` is not in `_KNOWN_CHILDREN`
  (`ouestcharlie-py-toolkit/src/ouestcharlie_toolkit/xmp.py:90-99`). It
  round-trips verbatim through `XmpSidecar._extra` but is otherwise ignored.
- `XmpSidecar.tags` (`schema.py:242`) is a flat `list[str]`. The index stores
  the flat `dc:subject` terms, so a photo tagged `Places|Europe|France|Paris`
  in darktable is indexed as four unrelated tags.
- Search (`array_has(tags, …)`, `wally/searcher.py:398-399`), tag facets
  (`partition_summary.py:35-40`) and the gallery pills
  (`gallery/src/components/PreviewPanel.svelte:178-184, 215-221`) are all flat.
- darktable's automatic tags (`darktable|format|jpg`, `darktable|changed`, …)
  and their components (`darktable`, `format`, `jpg`) end up indexed as user
  tags (moved here from OEC-63).
- The Woof skills (`tag_files.py`) add tags to `dc:subject` only. On a sidecar
  that darktable has written, darktable ignores those tags because it reads
  `lr:hierarchicalSubject` first.

Intended outcome:

1. Hierarchical tags are first-class: read from `lr:hierarchicalSubject`
   (favored over `dc:subject`), indexed as paths, queryable at any level of
   the hierarchy, counted per node in facets, and displayed as a hierarchy in
   the gallery.
2. Tags round-trip with darktable: what darktable wrote is read correctly
   (without its internal tags), and what OuEstCharlie or the Woof skills write
   is visible in darktable.

Other darktable compatibility topics (date format, `xmp:Rating` namespace, GPS
attributes) stay in OEC-63.

---

## Design decisions

### Tag representation: a list of paths

A tag is a **path**: a string whose levels are separated by `|`, the darktable
and Lightroom convention. A flat tag is a one-level path (`Family`).
`XmpSidecar.tags` and the index `tags` column keep their type (`list[str]`) but
now hold paths instead of flat keywords. No separate `hierarchical_tags` field:
one list, with the hierarchy taking precedence (the previous spec's option (a)
is dropped because it kept the flat list as the source of truth).

Only leaf paths are stored. If a sidecar contains both `Places|Europe` and
`Places|Europe|France`, the index keeps `Places|Europe|France`: the ancestor is
implied. This mirrors darktable, which doesn't attach parent tags to the image.

Paths are normalized on read: whitespace around each level is trimmed, empty
levels are dropped (`a||b` → `a|b`), and duplicates are removed. Case is kept
and matching stays case-sensitive, as today (case-insensitive matching: OEC-33b).

### Queryable form: a derived `list<string>` column, not JSON

The index needs two kinds of query:

- **By path or subtree**: `Places|Europe` should match
  `Places|Europe|France|Paris`.
- **By name at any level**: `Paris` should match `Places|Europe|France|Paris`.
  Existing callers (agents, skills) send bare names, and must keep working
  without knowing where a tag sits in the hierarchy.

A new derived column `tag_terms: list<string>` holds, for each photo, the
deduplicated union of:

- every ancestor prefix of every path (`Places`, `Places|Europe`,
  `Places|Europe|France`, `Places|Europe|France|Paris`);
- every level name (`Places`, `Europe`, `France`, `Paris`).

Both queries then become `array_has(tag_terms, '<value>')`, the same exact-match
predicate as today. A `LABEL_LIST` scalar index on `tag_terms` speeds up
`array_has` filters.

A semi-structured JSON column (e.g. a nested `{"Places": {"Europe": {…}}}`
tree) was considered and rejected:

- the "name at any level" query has no simple JSON-path form;
- LanceDB's JSON functions can't use a scalar index, whereas `LABEL_LIST` can;
- DuckDB unnests `list<string>` directly for facets, with no JSON parsing;
- MCP clients and the gallery already handle string tags.

The hierarchy is still exposed in JSON form where it matters: facets are keyed
by path, so a client can rebuild the tree (see section 7).

### Precedence between `lr:hierarchicalSubject` and `dc:subject`

**Read:**

1. If `lr:hierarchicalSubject` is present:
   - tags = its paths;
   - plus each `dc:subject` term that is not a level of any path in
     `lr:hierarchicalSubject`. These are flat tags added by a tool that only
     writes `dc:subject`. They are kept as one-level paths.
2. Otherwise: tags = `dc:subject` terms, each read as a path. A term containing
   `|` becomes hierarchical, as it would in darktable.
3. In both cases, paths matching one of the library's **excluded tag
   prefixes** are moved out of the tags (see below).

### Excluded tag prefixes (library setting)

Each library has an `excluded_tag_prefixes: list[str]` setting, which
defaults to `["darktable"]`. A path is excluded when it equals a prefix or sits
below it: `darktable` excludes `darktable` and `darktable|format|jpg`, but not
`darktable-fans`. Prefixes can be deeper paths (e.g. `Lightroom|Internal`) and
are normalized like tags. An empty list disables the filter.

Excluded paths are:

- not indexed, so they can't be searched, don't appear in facets, and never
  reach the gallery;
- kept in the sidecar: OuEstCharlie writes them back to `lr:hierarchicalSubject`
  unchanged, so darktable's own tags survive a round trip.

The filter applies when sidecars are read during indexing. Changing the
setting takes effect at the next full reindex of the library.

Example: `lr:hierarchicalSubject` = `Places|Europe|France`, `darktable|format|jpg`;
`dc:subject` = `Places`, `Europe`, `France`, `darktable`, `format`, `jpg`,
`Alpinism`, with the default setting → tags = `Places|Europe|France`,
`Alpinism`. `darktable`, `format` and `jpg` are levels of the excluded
`darktable|format|jpg` path, so they are not read as flat tags. A user tag `jpg`
written by darktable shows up as its own path `jpg` in `lr:hierarchicalSubject`,
so it is kept.

**Write** (`_serialize_xmp`), when `sidecar.tags` is non-empty or the original
sidecar had `lr:hierarchicalSubject`:

- `lr:hierarchicalSubject` = the user's paths, followed by the excluded paths
  read from the original sidecar (kept in a private field so they survive the
  round trip);
- `dc:subject` = every level of every user path, deduplicated, in first-seen
  order. This is darktable's and Lightroom's default "include parents" export.
  Excluded paths are left out: darktable rewrites `dc:subject` from its own
  tags at its next sync anyway.

Writing `lr:hierarchicalSubject` for flat tags too is required: if it exists,
darktable reads only it, so a flat tag written only to `dc:subject` would be
lost in darktable.

If there are no user tags and no excluded paths, neither element is written
(same as today, `test_serialize_xmp_empty_tags_omits_subject`).

---

## Changes

### 1. Tag path helpers

**File:** `ouestcharlie-py-toolkit/src/ouestcharlie_toolkit/tags.py` (new)

Pure functions, shared by the XMP layer, the index and Wally:

```python
TAG_SEPARATOR = "|"
DEFAULT_EXCLUDED_TAG_PREFIXES: tuple[str, ...] = ("darktable",)

def normalize_path(raw: str) -> str | None: ...          # trim levels, drop empty ones; None if empty
def levels(path: str) -> list[str]: ...                   # "a|b|c" -> ["a", "b", "c"]
def ancestors(path: str) -> list[str]: ...                # "a|b|c" -> ["a", "a|b", "a|b|c"]
def leaf_paths(paths: Iterable[str]) -> list[str]: ...    # dedupe, drop paths that are ancestors of another
def is_excluded(path: str, prefixes: Iterable[str]) -> bool: ...  # path == prefix or starts with prefix + "|"
def tag_terms(paths: Iterable[str]) -> list[str]: ...     # ancestors ∪ levels, deduplicated
def flatten(paths: Iterable[str]) -> list[str]: ...       # all levels, deduplicated, first-seen order (dc:subject)
```

### 2. Library setting `excluded_tag_prefixes`

**File:** `ouestcharlie-woof/src/woof/config.py` (`LibraryConfig`, lines 82-110)

- Add `excluded_tag_prefixes: list[str] = field(default_factory=lambda: ["darktable"])`.
  Libraries in an existing `config.json` have no such key, so
  `LibraryConfig(**b)` (line 137) gives them the default. `save()` then writes
  it explicitly.
- `to_dict()` includes it (the return type becomes `dict[str, Any]`), which
  forwards it to the agents through `WOOF_BACKEND_CONFIG`
  (`agent_client.py:317`), and shows it in `list_libraries`.
- `LibraryConfig.create()` takes an optional `excluded_tag_prefixes`. Each
  prefix goes through `normalize_path`, and empty entries are dropped.

**File:** `ouestcharlie-woof/src/woof/mcp_server.py` (`register_library`, lines 171-190)

The setting is managed through `register_library`, not by editing
`config.json` by hand. Add a parameter:

```python
async def register_library(
    name: str,
    path: str,
    library_type: str = "filesystem",
    excluded_tag_prefixes: list[str] | None = None,
) -> dict[str, Any]:
```

- `None` (omitted): a new library gets `["darktable"]`. A library already
  registered under that name keeps its current value, so re-registering it to
  change its path or type doesn't reset the setting.
- A list replaces the value. `[]` turns the filter off.
- To change the setting of an existing library, call `register_library` again
  with the same `name`, `path` and `library_type` and the new list.
  `add_library` (`config.py:185`) already replaces a library by name.
- The result adds `excluded_tag_prefixes` (through `to_dict()`). When an
  existing library's value changes, it also returns `reindexRequired: true`
  and a `message` asking the caller to run `index_library` with a full
  reindex, because tags already indexed don't change until then.
- Docstring: explain what the parameter does, its default, the matching rule
  (whole path levels, subtree included) and the reindex requirement. Add an
  example: `excluded_tag_prefixes=["darktable", "Lightroom|Internal"]`.
- Keep `destructive_hint=True`: re-registering overwrites the library's
  configuration.

**File:** `ouestcharlie-py-toolkit/src/ouestcharlie_toolkit/server.py` (next to
`lance_index_path_override`, line 72)

Add an `excluded_tag_prefixes` property that reads the key from
`backend_config`. If the key is absent (Woof older than this change), it falls
back to `DEFAULT_EXCLUDED_TAG_PREFIXES`. Pass it to `XmpStore` (line 55).

**File:** `ouestcharlie-whitebeard/src/whitebeard/indexer.py` (line 181)

Pass the agent's `excluded_tag_prefixes` to the `XmpStore` built there.

### 3. Data model

**File:** `ouestcharlie-py-toolkit/src/ouestcharlie_toolkit/schema.py` (line 242)

- `tags: list[str]` now documents its contents as "tag paths, `|`-separated;
  user tags only".
- Add `_excluded_tags: list[str] = field(default_factory=list)`: the excluded
  paths read from `lr:hierarchicalSubject`. They are never indexed, only written
  back.

### 4. XMP read

**File:** `ouestcharlie-py-toolkit/src/ouestcharlie_toolkit/xmp.py`

- Add `{_NS_LR}hierarchicalSubject` to `_KNOWN_CHILDREN` (lines 90-99), and a
  `_NS_LR` constant for the namespace already listed in `_WELL_KNOWN_NS`.
- Replace the `dc:subject` parsing (lines 513-519) with the read precedence
  above. Accept both `rdf:Bag` and `rdf:Seq` containers in both elements:
  some writers use `rdf:Seq`.
- `parse_xmp` (line 457) takes `excluded_tag_prefixes`, which defaults to
  `DEFAULT_EXCLUDED_TAG_PREFIXES`. `XmpStore.__init__` takes the same argument
  and passes it to every parse.

**File:** `ouestcharlie-py-toolkit/src/ouestcharlie_toolkit/photo.py` (line 468)

XPKeywords bootstrap: run each keyword through `normalize_path`. No other
change: Windows keywords are flat. `XmpStore.read_or_create_from_picture`
applies the excluded tag prefixes to freshly extracted sidecars too, so the
index sees the same rule whether the tags came from a sidecar or from EXIF.

### 5. XMP write

**File:** `ouestcharlie-py-toolkit/src/ouestcharlie_toolkit/xmp.py` (lines 698-703)

Write `lr:hierarchicalSubject` and `dc:subject` as described above, both as
`rdf:Bag`. Register the `lr` prefix with `ET.register_namespace` so the element
is written as `lr:hierarchicalSubject`, not `ns0:`.

### 6. Index

**File:** `ouestcharlie-py-toolkit/src/ouestcharlie_toolkit/lance_index.py`

- `PHOTO_SCHEMA` (line 65): keep `tags: list<string>` (leaf paths). Add
  `tag_terms: list<string>` next to it.
- `photo_entry_to_row` (line 134): `"tag_terms": tag_terms(s.get("tags") or [])`.
- Create a `LABEL_LIST` scalar index on `tag_terms` next to the FTS index
  (line 287), and on existing tables when opened by the writer
  (`create_if_missing=True`). Readers (Wally) never create indexes.
  `maintain()` (`optimize`) brings rows written after the index under it.
- `tag_terms` is a derived column. It is not in `PHOTO_ENTRY_COLUMNS` and
  `row_to_photo_entry` ignores it.

**File:** `ouestcharlie-py-toolkit/src/ouestcharlie_toolkit/schema.py` (line 17)

Bump `SCHEMA_VERSION` to 6 and `LOWEST_SCHEMA_VERSION` to 6. Existing rows
hold flat `dc:subject` terms and no `tag_terms`, so tag filters would silently
miss photos. `index_library` already forces a full reindex on a version bump
(OEC-38a), which re-reads every sidecar with the new rules. Sidecars aren't
rewritten.

**File:** `ouestcharlie-py-toolkit/src/ouestcharlie_toolkit/fields.py` (lines 106-111)

Keep `tags` as `STRING_COLLECTION`. Add `label="Tags (hierarchical, '|'-separated)"`
so `list_search_fields` describes the semantics.

### 7. Search and facets

**File:** `ouestcharlie-wally/src/wally/searcher.py` (lines 398-399)

```python
# Before
return [f"array_has(tags, '{_esc(tag)}')" for tag in fv.values]

# After
return [f"array_has(tag_terms, '{_esc(normalize_path(tag))}')" for tag in fv.values]
```

AND semantics stay unchanged. `{"tags": ["Places|Europe", "Alpinism"]}`
returns photos in the Europe subtree that are also tagged Alpinism.

**File:** `ouestcharlie-py-toolkit/src/ouestcharlie_toolkit/partition_summary.py` (lines 35-40, 158)

Facets count photos per node of the hierarchy. A photo counts once per node,
even if several of its paths share the node:

```sql
SELECT node, COUNT(*) AS cnt FROM (
  SELECT DISTINCT rid, node FROM (
    SELECT rid, UNNEST(list_transform(
             range(1, len(string_split(p, '|')) + 1),
             i -> array_to_string(string_split(p, '|')[1:i], '|'))) AS node
    FROM (SELECT row_number() OVER () AS rid, UNNEST(tags) AS p FROM photos)))
GROUP BY node ORDER BY cnt DESC
```

The `tag_facets` stat keeps its shape (`{"type": "tag_facets", "counts": {…}}`),
so the MCP `tagFacets` contract is unchanged. Keys are now paths, including
ancestors: `{"Places": 12, "Places|Europe": 9, "Places|Europe|France": 7, "Alpinism": 4}`.
Clients rebuild the tree by splitting keys on `|`.

**Files:** `ouestcharlie-wally/src/wally/agent.py` (lines 47, 99, 489),
`ouestcharlie-woof/src/woof/mcp_server.py` (line 64)

Update the tool descriptions and examples:

- tags are `|`-separated paths;
- a filter value matches that node and its whole subtree; a bare name matches
  that name at any level;
- `tagFacets` keys are paths, counted per node.

Add an example such as `{"tags": ["Places|Europe|France"]}`.

### 8. Gallery display

**File:** `ouestcharlie-woof/gallery/src/components/PreviewPanel.svelte`
(lines 99, 178-184, 215-221), helpers in `gallery/src/lib/format.js`

- **Tag pill** (one per path): shows the hierarchy as nested segments, with the
  ancestors muted and the leaf emphasized, like a label holding its parents
  (`Places › Europe › France › **Paris**`). One-level tags look like today's
  pills.
- **Caption overlay** (max 5 tags): show only the leaf name, with the full path
  in `title` (tooltip). This keeps the caption to one line.
- **Details panel**: group paths by root, so photos with
  `Places|Europe|France|Paris` and `Places|Europe|France|Lyon` show a single
  `Places › Europe › France` segment with `Paris` and `Lyon` as children.
- Excluded tags never reach the gallery: they are filtered at read time.
- `paraglide` messages: only if new labels are introduced (none expected).

### 9. Woof skills: write hierarchical tags

**Files:** `ouestcharlie-woof/plugins/woof-photo-workflows/skills/*/scripts/tag_files.py`,
both `SKILL.md`

`tag_files.py` edits sidecars with regexes and adds tags to `dc:subject` only.
Change it to follow the write rule above:

- accept `|`-separated paths in `--tags` (e.g. `--tags "Trips|2025|Alps" Family`);
- add each missing path to `lr:hierarchicalSubject`, creating the element if
  needed;
- add the path's levels to `dc:subject`;
- keep the existing merge rule: never drop existing entries, never create a
  second block of either element. The idempotence check looks at
  `lr:hierarchicalSubject`.

Two other scripts write or protect tags and follow the same rules:

- `sort_photos.py` (`enrich_sidecar`) writes tags as paths in
  `lr:hierarchicalSubject` and levels in `dc:subject`, and treats an existing
  `lr:hierarchicalSubject` as "already enriched";
- `snapshot_sidecars.py` snapshots and restores `lr:hierarchicalSubject`
  along with the `dc:` blocks, since a forced EXIF re-extraction drops it too.

The three scripts stay identical across both skills (enforced by a test).

`SKILL.md`: document hierarchical tags and suggest a hierarchy for generated
tags (e.g. `Activities|Hiking`, `Places|<country>|<region>`) rather than flat
keywords. Keep the hierarchy short and stable, and don't invent deep trees.

### 10. Tests

**`ouestcharlie-py-toolkit/tests/test_tags.py`** (new): `normalize_path`,
`ancestors`, `leaf_paths` (ancestor dropped, duplicates removed), `tag_terms`,
`flatten` order, `is_excluded` (`darktable` excludes `darktable` and
`darktable|format`, not `darktable-fans`; a deeper prefix `a|b` excludes
`a|b|c`, not `a|c`; an empty prefix list excludes nothing).

**`ouestcharlie-py-toolkit/tests/test_xmp.py`**:

- Update `test_parse_xmp_preserves_unknown_child_element` and
  `test_serialize_xmp_roundtrip_preserves_extra` (lines 404, 414): the
  `Europe|France|Paris` fixture now parses into `tags`, not `_extra`.
- `test_hierarchical_subject_takes_precedence`: paths from
  `lr:hierarchicalSubject`; `dc:subject` components are not duplicated as flat
  tags.
- `test_flat_only_dc_subject_terms_kept`: a `dc:subject` term outside every
  path is kept as a one-level path.
- `test_darktable_tags_excluded_by_default`: `darktable|format|jpg` +
  `dc:subject` `darktable`, `format`, `jpg`, `Alpinism` → tags `["Alpinism"]`.
  `jpg` present as its own path is kept.
- `test_excluded_tag_prefixes_custom`: with `["Lightroom|Internal"]`,
  `Lightroom|Internal|x` is excluded and `darktable|format|jpg` is kept as a
  tag. With `[]`, nothing is excluded.
- `test_dc_subject_only_pipe_term_is_hierarchical`.
- `test_seq_container_accepted`.
- `test_write_hierarchical_and_flattened_subject`: paths are written to
  `lr:hierarchicalSubject` (bag of `rdf:li` under the `lr` prefix); levels go to
  `dc:subject`.
- `test_write_flat_tags_also_in_hierarchical_subject`.
- `test_excluded_tags_round_trip`: read → write keeps `darktable|…` paths in
  `lr:hierarchicalSubject`, out of `tags` and `dc:subject`.
- `test_roundtrip_hierarchical`: parse → serialize → parse gives identical `tags`.
- Keep `test_serialize_xmp_empty_tags_omits_subject` (line 535), and extend it
  to `lr:hierarchicalSubject`.

**`ouestcharlie-py-toolkit/tests/test_server.py`** (or wherever
`lance_index_path_override` is tested): `excluded_tag_prefixes` read from
`WOOF_BACKEND_CONFIG`; default `["darktable"]` when the key is absent.

**`ouestcharlie-woof/tests/test_config.py`**: a library loaded from a
`config.json` without the key gets `["darktable"]`; a custom list round-trips
through `save()`/`load()`; `to_dict()` includes it; `create()` normalizes the
prefixes.

**`ouestcharlie-woof/tests/test_mcp_server.py`** (or wherever
`register_library` is tested):

- a new library registered without the parameter gets `["darktable"]`;
- a custom list and `[]` are stored and returned as `excluded_tag_prefixes`;
- re-registering an existing library without the parameter keeps its value,
  with no `reindexRequired`;
- re-registering with a different list replaces it and returns
  `reindexRequired: true`; with the same list, no `reindexRequired`.

**`ouestcharlie-whitebeard/tests`**: indexing a darktable sidecar with a custom
`excluded_tag_prefixes` in the backend config indexes the expected tags.

**`ouestcharlie-py-toolkit/tests/test_lance_index.py`**: `tag_terms` is
populated; `row_to_photo_entry` round-trips `tags` paths.

**`ouestcharlie-py-toolkit/tests/test_partition_summary.py`** (lines 164-193):
per-node counts; a photo with two paths under the same parent counts once for
that parent.

**`ouestcharlie-wally/tests`**: a filter by subtree prefix, by bare name at a
deep level, by full path, and AND across two tags.

**`ouestcharlie-woof/gallery`**: `format.test.js` for path splitting and
grouping; `PreviewPanel.test.js` for the leaf-only caption pill with tooltip,
and the grouped details panel.

**Skills**: a test for `tag_files.py` `apply()` on a darktable-written sidecar
(both elements present) and on a sidecar with `dc:subject` only.

### 11. Documentation

- `ouestcharlie-py-toolkit/py_toolkit_LLD.md` (XMP section): the tag path
  model, the read precedence and write rules, excluded tag prefixes, and the
  `tag_terms` column.
- `ouestcharlie-woof` LLD/README: the `excluded_tag_prefixes` library setting,
  set through `register_library` (default, matching rule, how to change it on
  an existing library, and the reindex needed after a change).
- `ouestcharlie-wally/wally_LLD.md`: tag filter semantics (subtree, name at any
  level) and per-node facets.
- `ouestcharlie/HLD.md`: tags are hierarchical and shared with
  darktable/Lightroom through `lr:hierarchicalSubject`.
- Woof README (user-facing): tags written by darktable, including their
  hierarchy, are searchable; Woof skills write tags darktable can read.

---

## Verification

1. Unit tests:
   ```bash
   cd ouestcharlie-py-toolkit && uv run pytest tests/ -v
   cd ouestcharlie-wally && uv run pytest tests/ -v
   cd ouestcharlie-woof/gallery && npm test
   ```
2. In darktable, tag a photo `Places|Europe|France|Paris` and `Family`, then
   let it sync the sidecar. Run `index_library` (full reindex triggered by the
   schema bump). The search result `tags` is
   `["Places|Europe|France|Paris", "Family"]`, with no `darktable`, `format` or
   `jpg`.
3. `search_photos` with `{"tags": ["Paris"]}`, `{"tags": ["Places|Europe"]}` and
   `{"tags": ["Places|Europe|France|Paris"]}` each return the photo.
   `{"tags": ["Places|Asia"]}` does not.
4. `get_summary` `tagFacets` contains `Places`, `Places|Europe`, … with per-node
   counts.
5. In the gallery, the preview caption shows `Paris` (tooltip with the full
   path). The details panel shows the path grouped under `Places`.
6. Run a Woof skill's `tag_files.py --tags "Trips|2025|Alps"` on the same
   photo. darktable, with "look for updated XMP files on startup" enabled, shows
   `Trips|2025|Alps` in its tag tree. `darktable|…` tags and `darktable:history`
   are unchanged in the sidecar.
7. Call `register_library` again for the library with
   `excluded_tag_prefixes=[]`. The result has `reindexRequired: true`. Run a
   full reindex: `darktable|format|jpg` now appears in the tags and facets.
   `list_libraries` shows `excluded_tag_prefixes: []`. Restore the default by
   re-registering with `["darktable"]`.

---

## Open points

- **darktable categories.** darktable can mark a hierarchy node as a
  "category", which it leaves out of exported keywords. Such nodes are stored in
  darktable's database, not in the sidecar, so OuEstCharlie can't detect them.
  Proposal: ignore.
- **Case and synonyms.** Case-insensitive matching is specified in OEC-33b.
  darktable's tag synonyms are not in the sidecar. Proposal: out of scope.
- **Facet size.** Ancestor nodes increase the number of facet keys. If this is
  an issue for large libraries, `get_summary` could take a depth or root
  parameter. Proposal: wait until it's needed.
