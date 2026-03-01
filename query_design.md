# Query Design

Working document for OuEstCharlie's query mechanism. Aggregates requirements and design decisions from HLR, HLD, and V1 vision; adds open questions and design work needed.

## Requirements (from HLR and Version1_vision)

**Functional:**
- Search photos based on predicates: date, tag, person, location, rating, album membership
- Date-based partitioning is the primary filter dimension (HLR: date-based partitioning)
- Albums: smart albums (saved predicates) and manual albums (XMP tag filter)
- Cross-backend deduplication at query time: same content hash in two backends → show once

**V1 scope (Wally):**
- Date predicates: full date `Y-M-D`, month `Y-M`, year `Y`
- Tag predicates: exact match on `dc:subject` keywords
- Rating predicates: numeric range (`rating >= N`)
- Camera predicates: substring match on `tiff:Make` / `tiff:Model`
- Retrieve and cache matching manifests and previews
- Open original file on the filesystem
- No enrichment-based filters (faces, scenes, descriptions) — deferred post-V1

**Non-functional (V1):**
- Retrieval performance: time to first result and all results for a date query
- Test context: local drive + mounted cloud drives (iCloud, OneDrive), 10k photos

## Consumption Agent: Wally

Wally is the V1 consumption agent. It is **stateless and read-only**: it receives a query and a scope (backend + credential) from Woof, traverses the manifest tree, and returns matching photo metadata. It never reads XMP sidecars — manifests contain full per-photo metadata inline.

| Operation | Reads XMP? | Reads manifest? |
|---|---|---|
| Consumption query (browse, search, filter) | No | Yes |

Woof invokes Wally in response to Claude tool calls (e.g., `search_photos`) and passes results to the gallery UI.

## Query Execution: Two-Level Pruning

From HLD § Efficient Filtering and Pruning.

Querying uses a two-level strategy inspired by data lakehouse query planning:

**Level 1 — Parent manifest pruning**: Read root → year manifests, which contain summary statistics and bloom filters for each child partition. Skip any subtree whose summary proves no photos can match (e.g., date range outside bounds, person absent from bloom filter).

**Level 2 — Leaf manifest scan**: For partitions that pass pruning, read the leaf manifest (full per-photo metadata inline). Evaluate the complete predicate against all entries. No per-photo file reads.

### Cost example

"Photos of Alice from July 2024" on a 100,000 photo library (100 leaf partitions × 1,000 photos):

1. Root manifest (~5 KB) → year summaries → prune years without "Alice"
2. 2024 year manifest (~15 KB) → month summaries → bloom filter → prune 10 months, keep Jul + Sep
3. Jul 2024 leaf manifest (~1.5 MB) → scan 1,000 inline entries → 12 matches
4. **Total: 3 file reads, ~1.5 MB** — vs. 100,000 XMP reads without pruning

### Manifest content relevant to queries

| Manifest level | Query-relevant content |
|---|---|
| Root | Consolidates year summaries (bloom filters, min/max dates, tag unions) |
| Year | Bloom filters, min/max dates, tag unions per month |
| Leaf (month) | Full per-photo metadata inline: hash, date, GPS, tags, rating, faces, scene |

### Pruning mechanisms per field type

Two complementary primitives cover all filter types — bloom filters are not required for V1:

| Filter type | Pruning mechanism | V1? |
|---|---|---|
| Date range | `dateMin`/`dateMax` in summary | Yes |
| Rating range | `ratingMin`/`ratingMax` in summary | Yes |
| Tag exact match | Bloom filter over `dc:subject` values | Post-V1 (full scan in V1) |
| Camera substring | No pruning (full scan) | V1 — acceptable at 10k scale |
| Person / scene | Bloom filter over enrichment fields | Post-V1 |

Note: bloom filters answer "is value X a member of this set?" — they do not support range comparisons. Range queries always use min/max stats.

## Albums

From HLR § Albums and HLD § Albums.

**Smart albums**: saved predicate evaluated at query time. Zero additional storage — pure read query through the pruning pipeline.

```json
{ "name": "Vacation 2024", "type": "smart", "filter": "date:2024 AND tag:travel" }
```

**Manual albums**: writing `album/<name>` tag to XMP sidecar makes it filterable as `tag:album/<name>`. Multi-album membership with no file duplication.

```json
{ "name": "Birthday Party", "type": "manual", "filter": "tag:album/birthday-party" }
```

Album definitions are device-local (`~/.ouestcharlie/albums.json`), not stored in the backend. Album tags live in XMP sidecars — they travel with photos.

Album queries use the same two-level pruning: `album/*` tags are included in manifest bloom filters and per-photo inline metadata.

**V1 scope**: Albums are out of scope for V1 (Version1_vision.md).

## Query Language

### Two-layer model

The user never writes a query string directly. Claude is the UI layer and translates natural language into a structured predicate. There are two distinct query representations:

| Layer | Format | Who handles it |
|---|---|---|
| User → Claude | Natural language ("photos from last summer tagged travel") | Claude translates |
| Album definitions (`albums.json`) | Textual DSL — human-readable, stored at rest | Woof parses at query time |
| Woof → Wally (MCP tool call) | Structured JSON predicate | Serialized from parsed DSL |
| Wally → manifest entries | Python evaluation | Walks predicate against inline photo fields |

The DSL matters for **album definitions**: they are saved filters written by users (or Claude on their behalf) and stored in `albums.json`. They must be human-readable, editable in a text editor, and parseable by Wally.

### DSL options considered

| DSL | Example | Pros | Cons |
|---|---|---|---|
| **Custom mini-language** | `date:2024 AND tag:travel` | Simple to spec for narrow use | Another thing to maintain; no ecosystem |
| **XPath** | `//photo[xmp:Rating >= 4]` | XML standard | Designed for XML tree navigation, not tabular filtering; verbose |
| **OData `$filter`** | `dateTaken ge 2024-01-01 and rating gt 3` | OASIS standard; used by OneDrive and Azure APIs | Verbose; less familiar outside enterprise/REST contexts |
| **RSQL / FIQL** | `dateTaken>=2024-01;rating>=4` | Compact, URL-safe | Obscure outside Java/REST ecosystems; limited Python support |
| **SQL `WHERE` subset** | `dateTaken >= '2024-01' AND 'travel' IN tags` | Universally understood | Not a standalone parseable standard |
| **Lucene query syntax** | `dateTaken:[2024-01-01 TO *] AND tags:travel AND rating:[4 TO 5]` | De facto standard (Elasticsearch, Solr, many search tools); well-specified; broad familiarity | Slightly search-centric; range syntax is verbose |

### Decision: Lucene query syntax via luqum

**Lucene query syntax** is the query language used by Elasticsearch and Apache Solr — de facto standards for full-text and structured search. It is widely understood by developers and familiar to anyone who has used Elasticsearch, Kibana, or Jira's advanced search.

**[luqum](https://github.com/jurismarches/luqum)** is the Python library for parsing Lucene queries into an AST (Apache2 / LGPLv3). It has no Elasticsearch dependency — it is a pure parser that produces a tree you evaluate against any data source.

```python
from luqum.parser import parser

tree = parser.parse('dateTaken:[2024-01-01 TO *] AND tags:travel AND rating:[4 TO 5]')
# → AndOperation(
#     SearchField("dateTaken", Range("2024-01-01", "*")),
#     SearchField("tags",      Word("travel")),
#     SearchField("rating",    Range("4", "5"))
#   )
```

Wally implements a visitor that walks the AST and evaluates each node against a manifest photo entry. The same visitor drives both album definition evaluation and ad-hoc queries forwarded from Woof.

### Supported operators per field type

| Field type | Lucene syntax | Example | Notes |
|---|---|---|---|
| `datetime` | Range `[A TO B]`, open `[A TO *]` | `dateTaken:[2024-01-01 TO 2024-12-31]` | ISO 8601 strings compare lexicographically |
| `string` | Word (exact), wildcard `*` / `?` | `model:Nikon*` | Case-insensitive by convention |
| `string[]` | Word (membership test) | `tags:travel` | True if value is in the array |
| `text` | Word, phrase `"..."`, fuzzy `~` | `description:holyday~` | Fuzzy via `rapidfuzz`; post-V1 |
| `int` / `float` | Range, exact | `rating:[4 TO 5]`, `rating:5` | Numeric comparison |
| Boolean | `AND`, `OR`, `NOT`, `+`, `-` | `tags:travel AND NOT tags:work` | Standard Lucene boolean operators |

**Note on fuzzy matching**: Lucene's `~` operator (e.g. `description:holyday~`) is parsed by luqum into a `Fuzzy` AST node. The visitor evaluates it using `rapidfuzz`. Meaningful only on `text` fields — not applicable to `string`, `string[]`, or numeric types.

### Fields that need to be queryable

| Field | Source | V1? | Notes |
|---|---|---|---|
| `dateTaken` | `exif:DateTimeOriginal` → XMP | Yes | Range by year, year-month, full date |
| `tags` | `dc:subject` → XMP | Yes | Membership test; full leaf scan (no bloom filter in V1) |
| `rating` | `xmp:Rating` → XMP | Yes | Numeric range; `ratingMin`/`ratingMax` in summary for pruning |
| `make` | `tiff:Make` → XMP | Yes | Wildcard/substring; no pruning |
| `model` | `tiff:Model` → XMP | Yes | Wildcard/substring; no pruning |
| `scene` | Enrichment agent | Post-V1 | Requires enrichment pipeline |
| `person` / face | Enrichment agent | Post-V1 | Requires face recognition |
| `album` | XMP tag (`album/*`) | Post-V1 | Sugar over `tags:album/<name>` |
| `location` | `exif:GPS*` → XMP | Post-V1 | Requires bounding box in summary |
| `description` | `dc:description` → XMP | Post-V1 | `text` type; fuzzy match via rapidfuzz |

## XMP → Manifest Field Mapping

Whitebeard is the sole translator: it reads XMP sidecars and writes JSON manifests. Wally (and all consumers) only read manifests — they never parse XMP.

The mapping is **driven by a configuration**, not hardcoded. This means:
- New fields can be indexed without a code change — update the mapping config and trigger a housekeeping rebuild
- The manifest schema evolves by incrementing `schemaVersion` and adding entries to the config
- Users can extend the mapping (e.g., add a custom namespace field) without modifying agent code

### Mapping config structure

Each entry defines one manifest field:

```json
{
  "manifestKey": "dateTaken",
  "xmpSources": ["exif:DateTimeOriginal", "xmp:CreateDate", "photoshop:DateCreated"],
  "type": "datetime",
  "nullable": true,
  "queryable": true,
  "summaryStats": ["min", "max"]
}
```

| Config field | Meaning |
|---|---|
| `manifestKey` | Key in the manifest photo entry |
| `xmpSources` | Ordered list of XMP fields to try (first non-null wins) |
| `type` | Value type — see table below |
| `nullable` | Whether absent XMP field → `null` or error |
| `queryable` | Whether Wally exposes this field as a filter predicate |
| `summaryStats` | Which summary stats to compute: `min`, `max`, `bloomFilter` |

**Types:**

| Type | JSON | XMP source type | Notes |
|---|---|---|---|
| `datetime` | `string` | `xmp:DateTime` | ISO 8601; preserve timezone offset if present |
| `string` | `string` | `xmp:Text`, `tiff:*`, etc. | Exact or substring match |
| `string[]` | `string[]` | `rdf:Bag`, `rdf:Seq` | Multi-value; flattened to array |
| `text` | `string` | `rdf:Alt` (lang alternatives) | Free text (description, comment); default language selected |
| `int` | `number` | `xmp:Integer` | Integer value |
| `float` | `number` | EXIF rational (`"N/D"`) | Rational string evaluated to float (e.g. `"20/10000"` → `0.002`) |

### Default V1 mapping

| `manifestKey` | `xmpSources` | `type` | `summaryStats` | Notes |
|---|---|---|---|---|
| `dateTaken` | `exif:DateTimeOriginal`, `xmp:CreateDate`, `photoshop:DateCreated` | `datetime` | `min`, `max` | |
| `make` | `tiff:Make` | `string` | — | |
| `model` | `tiff:Model` | `string` | — | |
| `orientation` | `tiff:Orientation` | `int` | — | EXIF values 1–8 |
| `width` | `exif:PixelXDimension`, `tiff:ImageWidth` | `int` | — | |
| `height` | `exif:PixelYDimension`, `tiff:ImageLength` | `int` | — | |
| `tags` | `dc:subject` | `string[]` | — (`bloomFilter` post-V1) | |
| `rating` | `xmp:Rating` | `int` | `min`, `max` | 0 = unrated, 1–5 stars, -1 = rejected (Lightroom) |

Post-V1 candidates (not in default mapping but reachable via config extension):

| `manifestKey` | `xmpSources` | `type` | Notes |
|---|---|---|---|
| `description` | `dc:description` | `text` | `rdf:Alt`; default language selected |
| `exposureTime` | `exif:ExposureTime` | `float` | Rational `"N/D"` → float, e.g. `"20/10000"` → `0.002` |
| `fNumber` | `exif:FNumber` | `float` | Rational, e.g. `"18000/10000"` → `1.8` |
| `iso` | `exif:ISOSpeedRatings` | `int` | `rdf:Seq`; first value taken |
| `focalLength` | `exif:FocalLength` | `float` | Rational, in mm |
| `gpsLat` | `exif:GPSLatitude` | `float` | Requires ref conversion (N/S) |
| `gpsLon` | `exif:GPSLongitude` | `float` | Requires ref conversion (E/W) |

Internal fields (`filename`, `contentHash`, `metadataVersion`, `xmpVersionToken`) are not driven by the mapping config — they come from the filesystem and OuEstCharlie internals.

### Unmapped fields

All XMP fields not listed in the mapping config remain in the XMP sidecar but are not copied to the manifest. They are not queryable through Wally. Adding a field means adding a mapping config entry and triggering a housekeeping rebuild (schema version bump).

### Schema evolution

Adding a new field to the mapping config:
1. Increment `schemaVersion`
2. Add the entry to the mapping config
3. Woof triggers a housekeeping rebuild — Whitebeard re-reads all XMP sidecars and rewrites manifests with the new field populated

## Thumbnail and Preview Access

Wally returns photo metadata from manifests. The gallery then fetches thumbnails and previews from Woof's local HTTP server, which serves cached AVIF containers.

Workflow:
1. Wally returns matching photo list with `content_hash` and partition info
2. Gallery requests thumbnails via Woof's local HTTP server
3. Woof checks cache; if miss, downloads the partition's `thumbnails.avif` from backend and caches it
4. Gallery decodes specific tiles by index using `photoOrder` from the manifest's `thumbnailGrid`

```json
"thumbnailGrid": {
  "cols": 32,
  "rows": 4,
  "tileSize": 256,
  "photoOrder": ["sha256:a1b2...", "sha256:c3d4...", ...]
}
```

Tile index for a photo = position of its `content_hash` in `photoOrder`.

## Open Points

### OP-Q1: Query language specification
(OpenPoints.md #7)

No grammar defined. Need to specify: syntax, operators, indexed fields, and how Woof serializes predicates for agent calls. V1 minimum: date-only structured predicate. Full DSL can come later.

### OP-Q2: Agent tool interface for Wally

The `controller_api.json` is incomplete for Wally. Need to define:
- MCP tool name(s) (e.g., `search_photos`, `browse_partition`)
- Input schema: predicate format, backend(s) to search, pagination
- Output schema: photo list with manifest-sourced metadata, partition references, thumbnail tile indices
- Progress reporting: how Wally reports partial results as it scans partitions

### OP-Q3: Result ordering and pagination

No design exists for how results are ordered (by date? relevance?) or paginated. Gallery browsing needs a stable ordering that maps back to tile indices in the AVIF container.

### OP-Q4: Cross-backend query scope

For a query spanning multiple backends, who deduplicates? Wally gets scoped to one backend per invocation (per HLD). Woof must merge and deduplicate results across multiple Wally calls by `content_hash`.

### OP-Q5: Manifest caching in Woof

Woof's local HTTP server caches AVIF containers. Where do manifests get cached? Wally reads manifests on each query — for large libraries, manifest caching in Woof would avoid redundant downloads. Not yet designed.
