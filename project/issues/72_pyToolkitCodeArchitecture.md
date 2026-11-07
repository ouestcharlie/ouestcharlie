# OEC-72: Split py-toolkit into sub-packages by responsibility

#status:done

Implemented on branch `OEC-72_pyToolkitCodeArchi` in py-toolkit, Wally and Whitebeard.
Differences from the original spec are marked *(as built)*.

## Context

`ouestcharlie-py-toolkit/src/ouestcharlie_toolkit` is a flat package of 19 modules
(~5,000 lines). It grew one feature at a time, and several modules now mix unrelated
concerns:

| Module | Lines | Mixes |
|---|---|---|
| `xmp.py` | 937 | sidecar paths, namespace tables, date/GPS parsing, `XmpStore` (I/O + concurrency), `parse_xmp`, `serialize_xmp`, darktable date-offset recovery (needs `Photo`) |
| `photo.py` | 728 | EXIF parsing, HEIF EXIF reader, AVIF/JXL/RAW display-size probes, suffix lists, `Photo` |
| `lance_index.py` | 540 | Arrow schema, `PhotoEntry` ↔ row mapping, table migrations, SQL escaping, FTS filter, `LanceIndex` |
| `video.py` | 509 | MP4/MOV box parsing, rotation, time-zone resolution, `Video` |
| `schema.py` | 396 | schema version, `.ouestcharlie/` layout paths, data models, `summary.json` (de)serialization |

Other problems:
- **Private names used across repos.** Wally imports `_esc` from `lance_index` and
  `_summary_to_dict` from `schema`. Any rename inside the toolkit breaks Wally silently.
- **Unclear public API.** `__init__.py` exports a subset, but agents import from ~13
  modules directly (`fields`, `tags`, `thumbnail_builder`, `partition_summary`, …).
- **Hidden dependency.** `xmp.py` imports `Photo` and `Video` lazily inside `XmpStore`.
  *(As built: not a real cycle, since `photo.py`/`video.py` never import `xmp`. The fix is
  to place `xmp` above `media` in the layer order and import at module level, see §3.)*
- **Stale naming.** Since OEC-11 (LanceDB index) there is no per-partition manifest left.
  `ManifestStore` only reads/writes `summary.json`, and `ManifestSummary` is a partition
  summary.
- **Mixed import styles.** Some modules use relative imports, others
  `from ouestcharlie_toolkit.x import …` (`schema.py`, `thumbnail_builder.py`,
  `preview_builder.py`).
- **Native binary dependency mixed in.** `thumbnail_builder.py` and `preview_builder.py`
  are the only modules that import `ouestcharlie_imageproc` (native `image-proc` binary),
  but they sit next to modules Wally uses without it. Grouping them keeps the option of
  making imageproc an extra later (not part of this issue).

Same approach as the imageproc refactor (commit `96ae302`): the single 1,100-line
`main.rs` was split into `protocol`, `transform`, `decode/` and `commands/`, with a thin
`main.rs`, new focused tests per module, and an updated LLD. No behavior change.

Intended outcome: each module has one responsibility, the dependency direction is
explicit (storage → model → media → xmp → index → renditions → agent), and agents only import public
names.

Out of scope: behavior changes, new features, changing the on-disk formats or
`SCHEMA_VERSION`.

---

## Changes

### 1. Target layout

```
ouestcharlie_toolkit/
  __init__.py            public API (re-exports only)
  storage/
    backend.py           Backend protocol, FileInfo, VersionToken, PartitionLockToken, errors, backend_from_config
    local.py             LocalBackend            (from backends/local.py)
    cloud_mount.py       CloudMountBackend       (from backends/cloud_mount.py)
    layout.py            METADATA_DIR, summary_path, lance_index_path, preview_jpeg_path, thumbnail_avif_path
    hashing.py           content_hash   (as built: storage, since LocalBackend uses it)
  model/
    fields.py            FieldDef, FieldType, PHOTO_FIELDS
    entries.py           PhotoEntry, XmpSidecar
    summary.py           ManifestSummary, RootSummary + (de)serialization
    thumbnails.py        ThumbnailGridLayout, ThumbnailChunk            (as built)
    version.py           SCHEMA_VERSION, LOWEST_SCHEMA_VERSION, is_index_schema_compatible, OUESTCHARLIE_NS
    tags.py              tag normalization / folding / hierarchy
  media/
    suffixes.py          PHOTO_SUFFIXES, VIDEO_SUFFIXES, RAW/HEIF suffix sets
    filename_time.py
    photo/
      exif.py            EXIF date/GPS/rational parsing, extra-field mapping
      heif.py            HEIF EXIF reader
      dimensions.py      AVIF / JXL / RAW display size
      photo.py           Photo
    video/
      mp4.py             moov/box parsing, rotation
      timing.py          creation time, ISO 6709, UTC offset, time-zone resolution
      video.py           Video, video_identity_hash
  xmp/
    paths.py             xmp_path_for, sidecar_candidates
    namespaces.py        namespace URIs, registration, known props
    values.py            date and GPS value conversions   (as built)
    parse.py             parse_xmp, tag reading
    serialize.py         serialize_xmp
    store.py             XmpStore
  index/
    schema.py            PHOTO_SCHEMA, PHOTO_TABLE_NAME, photo_entry_to_row, row_to_photo_entry
    migrations.py        _migrate_table, tag-terms index
    query.py             FtsFilter, sql_quote (today `_esc`)
    lance_index.py       LanceIndex
    partition_summary.py compute_summary
    summary_store.py     SummaryStore (today ManifestStore)
  renditions/            only sub-package importing ouestcharlie_imageproc
    thumbnails.py        (from thumbnail_builder.py)
    previews.py          (from preview_builder.py)
  agent/
    server.py            AgentBase, PerPhotoContext
    logging.py           setup_logging
```

Most files land under ~300 lines; `storage/local.py` (386) and `index/lance_index.py` (316) are a bit above.

### 2. Public API

- Promote the private names agents use: `_esc` → `index.query.sql_quote`,
  `_summary_to_dict` → `model.summary.summary_to_dict` (or a method on `ManifestSummary`).
- `ouestcharlie_toolkit/__init__.py` and each sub-package `__init__.py` re-export what
  agents need, with `__all__`. Agents import from the sub-package, never from a leaf
  module or a `_name`.
- No compatibility shims: the old flat module paths are removed. Wally and Whitebeard
  are updated and released in the same release cycle as the toolkit (§7).

### 3. xmp above media

*(As built.)* `XmpStore.read_or_create_from_picture` needs `Photo` and `Video` to extract
metadata, not just the date offset, and `media/` never imports `xmp/`. So `xmp` sits above
`media` in the layer order and `xmp/store.py` imports `Photo` and `Video` at module level.
No API change.

### 4. Naming

- `ManifestStore` → `SummaryStore`, `manifest.py` → `index/summary_store.py`.
- Keep `ManifestSummary` unless the rename is cheap; it appears in the Wally tool output
  shape, which must not change.

### 5. Consistent imports

*(As built.)* Absolute imports everywhere, enforced by ruff `TID252` with
`ban-relative-imports = "all"`. `tests/test_architecture.py` checks the layer order
(`storage` ← `model` ← `media` ← `xmp` ← `index` ← `renditions` ← `agent`), that toolkit
modules import leaf modules rather than sub-package `__init__` files, and that importing
`index` or `xmp` does not load `ouestcharlie_imageproc`.

### 6. Tests

- Move tests to mirror the layout (`tests/storage/`, `tests/xmp/`, …). No test logic
  change in the move.
- Split the largest test files along the new modules: `test_xmp.py` (1,131 lines),
  `test_lance_index.py` (948), `test_photo.py` (868).
- *(As built.)* No new unit tests besides `test_architecture.py`: MP4 rotation, JXL and
  RAW size, XMP date/GPS helpers and `sql_quote` already had direct tests, now in the
  split files.

### 7. Consumers

Update imports in:
- `ouestcharlie-wally/src/wally/` (`agent.py`, `searcher.py`, `http_server.py`)
- `ouestcharlie-whitebeard/src/whitebeard/` (`agent.py`, `indexer.py`)

Woof does not depend on the toolkit at runtime. `woof/config.py` mirrors
`ouestcharlie_toolkit.tags` (excluded tag prefixes, `normalize_path`) and cites it in two
comments, also cited in `woof_LLD.md`: update those references to the new module path.
`tests/test_skill_scripts.py` imports `PHOTO_SUFFIXES` and `VIDEO_SUFFIXES` (the toolkit
is in Woof's dev environment through Whitebeard and Wally): import them from
`ouestcharlie_toolkit.media`.

Release the toolkit as `0.17.0`, and Wally and Whitebeard in the same release cycle,
each raising its requirement to `ouestcharlie-py-toolkit>=0.17.0`. Agents declare the
toolkit with `>=`, so a bigger version jump would not stop an older agent release from
resolving the new toolkit: only releasing all packages together does.

### 8. Documentation

- `py_toolkit_LLD.md`: new "Package layout" section with the tree, the layer order and
  the public API rule; update the module names used in existing sections
  (`lance_index.py`, Manifest Consistency, XMP Consistency).
- `py_toolkit_LLD_rationale.md`: why sub-packages, why `renditions/` is isolated.
- `README.md`: import examples.

### 9. Delivery

All changes go in one py-toolkit PR, with one matching PR each in Wally and Whitebeard
(separate repos), merged and released together. Inside the toolkit PR, use `git mv` before
editing so `git log --follow` keeps file history. Suggested commit order:
1. Public API for `_esc` / `_summary_to_dict` (§2).
2. `storage/`, `model/` (move `schema.py` content out).
3. `xmp/` split + cycle removal (§3).
4. `media/` split.
5. `index/` split + `SummaryStore` (§4).
6. `renditions/`, `agent/`, import rules (§5), LLD.

---

## Verification

- `uv run pytest` in py-toolkit passes, with the same test count or more.
- `uv run mypy` and `uv run ruff check` are clean, including the new import rules.
- No `from ouestcharlie_toolkit.… import _…` left in Wally and Whitebeard:
  `grep -rn "ouestcharlie_toolkit.* import .*\b_" ouestcharlie-{wally,whitebeard}/src`.
- Wally and Whitebeard test suites and integration tests pass against the
  refactored toolkit.
- Importing `ouestcharlie_toolkit.index` and `ouestcharlie_toolkit.xmp` does not load
  `ouestcharlie_imageproc` (check `sys.modules` in a test); only `renditions/` does.
- End-to-end: index a sample library with Whitebeard, search and open the gallery with
  Wally/Woof. Results, `summary.json` and the Lance table match a run on `master`
  (same row count, same summary).
