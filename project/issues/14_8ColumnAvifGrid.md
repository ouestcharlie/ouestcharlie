# Plan: Fix AVIF grid to 8 columns, remove thumbnailCols from all layers

#status:done

## Context

The AVIF thumbnail grid currently uses `ceil(sqrt(n))` for column count and stores/transmits the result as `thumbnailCols` through every layer (manifest → Wally API → Gallery). Since cols is always `min(8, n)`, it is redundant to store or transmit it. This change fixes cols to 8 (or n if n < 8), removes `cols` from the Rust output, manifest JSON, Wally API, and has the Gallery use the constant 8.

**Protocol change**: removing `cols` from the Rust response → bump image-proc major version 1→2.

**Gallery**: always uses `AVIF_GRID_COLS = 8`. For chunks with n < 8 photos, `tileIndex < 8` so `tileIndex % 8 = tileIndex` — col/row are always computed correctly.

---

## Implementation order

**Phase 1 — `ouestcharlie-imageproc`**: update Rust binary + Python wrapper, publish to PyPI.  
**Phase 2 — everything else**: update py-toolkit, wally, and woof gallery once the new wheel is available.

---

## Phase 1 — ouestcharlie-imageproc

### `image-proc/src/main.rs`

**`grid_dims()` (lines 375–379):** add constant, change formula:
```rust
const GRID_COLS: u32 = 8;

fn grid_dims(n: usize) -> (u32, u32) {
    let cols = (n as u32).min(GRID_COLS);
    let rows = n.div_ceil(cols as usize) as u32;
    (cols, rows)
}
```

**`AvifGridOutput` struct (lines 104–111):** remove `cols` field and its `#[serde(rename)]` line.

**Unit tests (lines 399–404):** update expected values:

| test | was | now |
|---|---|---|
| `grid_dims_one` | (1,1) | (1,1) — unchanged |
| `grid_dims_two` | (2,1) | (2,1) — unchanged |
| `grid_dims_four` | (2,2) | (4,1) |
| `grid_dims_five` | (3,2) | (5,1) |
| `grid_dims_nine` | (3,3) | (8,2) |
| `grid_dims_ten` | (4,3) | (8,2) |

**Integration test `avif_grid_four_photos_two_by_two` (line 496):** rename to `avif_grid_four_photos_four_by_one`; remove `cols`/`rows` assertions (field no longer in result); keep file-existence and photo-order assertions.

**Integration test `avif_grid_five_photos_pads_last_row` (line 518):** rename to `avif_grid_five_photos_five_by_one`; update comment to "5 photos → cols=5, rows=1"; remove `cols`/`rows` assertions.

**Integration test `avif_grid_single_photo` (line 478):** remove `assert_eq!(result.cols, 1)` and `assert_eq!(result.rows, 1)`.

**`image-proc/Cargo.toml`:** bump `version = "1.0.0"` → `"2.0.0"`.

### `src/ouestcharlie_imageproc/image_proc.py`

Bump `IMAGE_PROC_PROTOCOL_MAJOR_VERSION = 1` → `= 2` (line 26).

---

## Phase 2 — py-toolkit, wally, woof

### `ouestcharlie-py-toolkit/src/ouestcharlie_toolkit/schema.py`

**`ThumbnailGridLayout` (lines 222–233):** remove `cols: int` field entirely. Update docstring.
```python
@dataclass
class ThumbnailGridLayout:
    rows: int
    tile_size: int
    photo_order: list[str]
```

**`_grid_layout_to_dict` (line 463):** remove `"cols": g.cols`.

**`_grid_layout_from_dict` (line 472):** remove `cols=d["cols"]`. Old manifests with `"cols"` in JSON are silently ignored.

### `ouestcharlie-py-toolkit/src/ouestcharlie_toolkit/thumbnail_builder.py`

**`_call_image_proc` (lines 103–108):** remove `cols=grid_info["cols"]` from the `ThumbnailGridLayout(...)` constructor.

**Debug log (lines 155–157):** replace `grid.cols` with `min(8, len(chunk_entries))`.

### `ouestcharlie-py-toolkit/tests/test_thumbnail_builder.py`

- `_FakeAvifProcess`: remove `cols` constructor param and `"cols"` from returned JSON.
- `_CapturingProcess.communicate()`: remove `"cols": 1` from returned JSON.
- All `ThumbnailGridLayout(cols=..., ...)` calls: remove the `cols=` argument.
- `test_call_image_proc_returns_bytes`: remove `assert grid.cols == 1`.

### `ouestcharlie-wally/src/wally/searcher.py`

**`thumb_lookup` (lines 243–247):** drop cols from the tuple:
```python
thumb_lookup: dict[str, tuple[str, int]] = {}
for chunk in manifest.thumbnail_chunks:
    for i, h in enumerate(chunk.grid.photo_order):
        thumb_lookup[h] = (chunk.avif_hash, i)
```

**`PhotoMatch` (line 133):** remove `thumbnail_cols: int | None` field.

**`PhotoMatch` construction (lines 254–262):** remove `thumbnail_cols=thumb[2] if thumb else None`.

### `ouestcharlie-wally/src/wally/agent.py`

Remove `thumbnailCols` serialization:
```python
# Remove:
if m.thumbnail_cols is not None:
    d["thumbnailCols"] = m.thumbnail_cols
```

### `ouestcharlie-woof/gallery/src/App.svelte`

Replace variable `cols` (from `thumbnailCols`) with a module-level constant:
```javascript
const AVIF_GRID_COLS = 8;
```

Update `thumbnailTile()` to use it directly:
```javascript
function thumbnailTile(match) {
  const { avifHash } = match;
  if (!httpPort || !avifHash || match.tileIndex == null) return null;
  const encodedPartition = match.partition.split('/').map(encodeURIComponent).join('/');
  const url = `http://127.0.0.1:${httpPort}/thumbnail/${encodeURIComponent(backendName)}/${encodedPartition}/${encodeURIComponent(avifHash)}`;
  const col = match.tileIndex % AVIF_GRID_COLS;
  const row = Math.floor(match.tileIndex / AVIF_GRID_COLS);
  return { url, col, row, cols: AVIF_GRID_COLS };
}
```

No changes needed to `PreviewPanel.svelte` (keeps `THUMBNAIL_TILE_SIZE = 256` for geometry) or `PhotoGrid.svelte`.

## Handling of new Schema

- Bump to 2 the SCHEMA_VERSION
- Add a check in Wally search_photos to check if the summary has schema_version < SCHEMA_VERSION, if true return an error and suggest full index
- Add a check in Whitebeard index_library to force full index if schema_version < SCHEMA_VERSION
- In Whitebeard, in case of full index with thumbnail generation, delete previous thumbnails

Fix some issues with MCP error handling in Wally and Woof


---

## Verification

**Phase 1:**
1. `cd ouestcharlie-imageproc/image-proc && cargo test` — all tests pass.
2. `cargo build --release` — compiles without `cols` in `AvifGridOutput`.
3. Publish new wheel to PyPI.

**Phase 2:**
4. `.venv/bin/python -m pytest tests/ -v` in `ouestcharlie-py-toolkit`.
5. `.venv/bin/python -m pytest tests/ -v` in `ouestcharlie-wally`.
6. `npm run build` in `ouestcharlie-woof/gallery/`.
7. End-to-end: run Whitebeard on `test-perso/`, verify new manifests have no `"cols"` in `grid`, search via Wally, confirm thumbnails render correctly in Gallery.
