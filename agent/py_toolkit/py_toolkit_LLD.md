# Python Toolkit Low-Level Design

This document details the shared Python toolkit used by all OuEstCharlie agents. For technology selection rationale, see [agent_LLD_rationale.md](../agent_LLD_rationale.md). For MCP tool definitions, see [controller_api.json](../../controller_api.json).

## Overview

The Python toolkit (`ouestcharlie-toolkit`) is a shared library that provides three core capabilities to all agents:

1. **MCP integration** — MCP server lifecycle, tool registration, progress reporting, and logging
2. **Manifest read-edit with consistency** — hierarchical manifest traversal, atomic read-modify-write with optimistic concurrency
3. **XMP read-edit with consistency** — sidecar read-modify-write with optimistic concurrency and field-level semantics

Agents import the toolkit and focus on their domain logic (indexing, enrichment, search). The toolkit handles protocol, storage, and consistency concerns.

## Package Structure

```
ouestcharlie-toolkit/
├── pyproject.toml
├── src/
│   └── ouestcharlie/
│       ├── __init__.py
│       ├── server.py          # MCP server lifecycle and base agent class
│       ├── backend.py         # Backend abstraction (file I/O interface)
│       ├── backends/
│       │   ├── __init__.py
│       │   └── local.py       # Local filesystem backend (V1)
│       ├── manifest.py        # Manifest read-edit with consistency
│       ├── xmp.py             # XMP sidecar read-edit with consistency
│       ├── schema.py          # Shared data models (manifest entries, XMP fields)
│       └── progress.py        # Progress reporting helpers
```

V1 scope: local filesystem backend only. The `backend.py` abstraction enables adding cloud backends (S3, GCS, ADLS Gen2) later without changing agent code.

## MCP Integration

### Server Lifecycle

Each agent is an MCP server using the official `mcp` Python SDK. The toolkit provides a base class that handles the MCP lifecycle, letting agents focus on tool implementation.

```python
from ouestcharlie.server import AgentBase

class HousekeepingAgent(AgentBase):
    name = "ouestcharlie-housekeeping"
    version = "1.0.0"

    @tool(schema=REBUILD_PARTITION_SCHEMA)
    async def rebuild_partition(self, backend: str, partition: str, mode: str = "lazy"):
        # Agent-specific logic here
        ...
```

`AgentBase` responsibilities:
1. Parse environment variables (`WOOF_BACKEND_CONFIG`, `WOOF_AGENT_TOKEN`)
2. Initialize the backend connection from config
3. Register tools declared by subclass decorators
4. Run the MCP server on stdio transport (default) or HTTP
5. Handle `initialize` handshake — declare server info, capabilities, and tools
6. Route incoming `tools/call` requests to the appropriate method
7. Handle `notifications/cancelled` — set a cancellation flag and let the agent's tool method check it cooperatively

### Tool Registration

Tools are declared using a `@tool` decorator that maps to the MCP `tools/list` response:

```python
@tool(
    name="rebuild_partition",
    description="Reconcile a partition...",
    input_schema={...},   # JSON Schema from controller_api.json
    output_schema={...},
    annotations={"readOnlyHint": False, "destructiveHint": False}
)
async def rebuild_partition(self, **params):
    ...
```

The decorator validates input against the schema before calling the method and wraps the return value in an MCP tool result.

### Progress Reporting

The toolkit provides a `ProgressReporter` that wraps MCP `notifications/progress`:

```python
async def rebuild_partition(self, backend: str, partition: str, **kwargs):
    photos = await self.backend.list_photos(partition)
    progress = self.progress(total=len(photos))

    for photo in photos:
        await self.check_cancelled()
        # ... process photo ...
        await progress.advance(
            message=f"processing {photo.name} — partition {partition}"
        )

    return {"photosProcessed": len(photos), "errors": 0}
```

`ProgressReporter`:
- Emits `notifications/progress` with the tool call's progress token
- Tracks `progress` (items completed) and `total`
- `advance(n=1, message=...)` increments progress and sends the notification
- Rate-limited: sends at most one notification per 500ms to avoid flooding the transport (queues the latest state and flushes on the next tick)

### Logging

The toolkit wraps MCP `notifications/message` for structured logging:

```python
self.log.info("Starting partition rebuild", partition=partition)
self.log.error(
    "Failed to decode EXIF",
    category="permanent",
    photo="IMG_042.cr3",
    partition=partition,
    operation="EXIF extraction"
)
```

Log levels map to MCP severity: `debug`, `info`, `warning`, `error`. The `data` field carries structured context (category, photo, partition, operation) matching the schema in `controller_api.json`.

### Cancellation

Cooperative cancellation via `check_cancelled()`:

```python
async def rebuild_partition(self, ...):
    for photo in photos:
        await self.check_cancelled()  # raises CancelledError if Woof sent cancellation
        ...
```

When Woof sends `notifications/cancelled`, the base class sets an internal flag. `check_cancelled()` raises `asyncio.CancelledError`, which the base class catches to return a graceful error result. Agents can also check `self.cancelled` directly for cleanup logic.

## Backend Abstraction

### Interface

The `Backend` protocol defines the storage operations the toolkit needs. All paths are relative to the backend root.

```python
class Backend(Protocol):
    async def read(self, path: str) -> tuple[bytes, VersionToken]:
        """Read file contents and its version token."""

    async def write_conditional(self, path: str, data: bytes, expected_version: VersionToken) -> VersionToken:
        """Write file if version matches. Raises VersionConflictError if not."""

    async def write_new(self, path: str, data: bytes) -> VersionToken:
        """Write a new file. Raises FileExistsError if it already exists."""

    async def list_files(self, prefix: str, suffix: str = "") -> list[FileInfo]:
        """List files under prefix, optionally filtered by suffix."""

    async def exists(self, path: str) -> bool:
        """Check if a file exists."""

    async def delete(self, path: str) -> None:
        """Delete a file."""
```

`VersionToken` is backend-specific: `mtime` for local filesystem, `ETag` for S3/GCS/ADLS Gen2, `generation` for GCS. It is opaque to callers — they receive it from `read()` and pass it to `write_conditional()`.

### Local Filesystem Backend (V1)

```python
class LocalBackend:
    def __init__(self, root: Path):
        self.root = root

    async def read(self, path: str) -> tuple[bytes, VersionToken]:
        full = self.root / path
        data = full.read_bytes()
        mtime = full.stat().st_mtime_ns
        return data, VersionToken(mtime)

    async def write_conditional(self, path: str, data: bytes, expected_version: VersionToken):
        full = self.root / path
        current_mtime = full.stat().st_mtime_ns
        if current_mtime != expected_version.value:
            raise VersionConflictError(path, expected_version, VersionToken(current_mtime))
        # Write to temp file, then atomic rename
        tmp = full.with_suffix(full.suffix + ".tmp")
        tmp.write_bytes(data)
        tmp.rename(full)
        return VersionToken(full.stat().st_mtime_ns)
```

Atomic write uses write-to-temp-then-rename — atomic on POSIX. The version check before rename guards against concurrent modification (another agent or external tool writing the same file).

**Race window**: Between reading `mtime` and renaming, another writer could modify the file. For V1 (single-device, sequential agent execution by Woof), this window is acceptable. For future multi-agent concurrency, the backend can use `flock` or a compare-and-swap mechanism.

## Manifest Read-Edit with Consistency

### Data Model

Manifests are JSON files at well-known paths. The toolkit defines typed models for both leaf and parent manifests.

```python
@dataclass
class PhotoEntry:
    filename: str
    content_hash: str              # sha256:...
    date_taken: datetime | None
    camera: str | None
    gps: tuple[float, float] | None
    orientation: int | None
    tags: list[str]                # includes album/* tags, enrichment tags
    metadata_version: int
    xmp_version_token: str         # backend version token of the XMP sidecar at consolidation time

@dataclass
class PartitionSummary:
    path: str
    photo_count: int
    date_min: datetime | None
    date_max: datetime | None
    tags_bloom: bytes              # serialized bloom filter over all tags
    hashes_bloom: bytes            # serialized bloom filter over content hashes

@dataclass
class LeafManifest:
    schema_version: int
    partition: str
    photos: list[PhotoEntry]
    summary: PartitionSummary
    thumbnails_hash: str | None    # content hash of thumbnails.avif
    previews_hash: str | None      # content hash of previews.avif

@dataclass
class ParentManifest:
    schema_version: int
    path: str
    children: list[PartitionSummary]
```

### Unknown Fields Preservation

Per the HLD schema evolution rules, unknown fields must be preserved. The toolkit uses a hybrid approach:

- Manifest JSON is deserialized into typed dataclasses for known fields
- Unknown top-level and per-entry fields are captured in an `_extra: dict` attribute
- On serialization, known fields and `_extra` are merged back

This ensures an agent running schema v1 can read a manifest written by a schema v2 agent without losing the new fields.

### Read-Modify-Write with Optimistic Concurrency

```python
class ManifestStore:
    def __init__(self, backend: Backend):
        self.backend = backend

    async def read_leaf(self, partition: str) -> tuple[LeafManifest, VersionToken]:
        path = f"{partition}.ouestcharlie/manifest.json"
        data, version = await self.backend.read(path)
        manifest = _deserialize_leaf(json.loads(data))
        return manifest, version

    async def write_leaf(self, manifest: LeafManifest, expected_version: VersionToken) -> VersionToken:
        path = f"{manifest.partition}.ouestcharlie/manifest.json"
        data = json.dumps(_serialize_leaf(manifest), ensure_ascii=False).encode()
        return await self.backend.write_conditional(path, data, expected_version)

    async def read_modify_write_leaf(
        self,
        partition: str,
        modify: Callable[[LeafManifest], LeafManifest],
        max_retries: int = 3
    ) -> LeafManifest:
        for attempt in range(max_retries + 1):
            manifest, version = await self.read_leaf(partition)
            updated = modify(manifest)
            try:
                await self.write_leaf(updated, version)
                return updated
            except VersionConflictError:
                if attempt == max_retries:
                    raise
                # Re-read and retry with the latest version
                continue
```

The `read_modify_write_leaf` method encapsulates the optimistic concurrency loop. Agents pass a `modify` function that transforms the manifest — the retry logic is invisible to them:

```python
# Agent usage — simple and focused on domain logic
async def add_photo_to_manifest(self, partition: str, entry: PhotoEntry):
    def modify(manifest: LeafManifest) -> LeafManifest:
        manifest.photos.append(entry)
        manifest.summary = _recompute_summary(manifest)
        return manifest

    await self.manifest_store.read_modify_write_leaf(partition, modify)
```

### Parent Manifest Rebuilding

Parent manifests (year-level and root) consolidate summaries from their children. Rebuilding a parent:

1. List all child manifest paths (`{year}/*/.ouestcharlie/manifest.json`)
2. Read each child manifest's summary (not full photo entries — summary only)
3. Merge summaries: union bloom filters, compute min/max dates, sum photo counts
4. Write the parent manifest with optimistic concurrency

Parent manifests are rebuilt as part of housekeeping after any leaf manifest changes.

### First-Time Manifest Creation

When indexing a partition for the first time (no existing manifest), the toolkit uses `write_new()` instead of `write_conditional()`. If two agents race to create the same manifest, one gets `FileExistsError` and falls back to `read_modify_write_leaf`.

## XMP Read-Edit with Consistency

### XMP Sidecar Format

XMP sidecars are XML files following the XMP specification (ISO 16684), with OuEstCharlie-specific fields in a custom namespace:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<x:xmpmeta xmlns:x="adobe:ns:meta/">
  <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
    <rdf:Description
      xmlns:dc="http://purl.org/dc/elements/1.1/"
      xmlns:exif="http://ns.adobe.com/exif/1.0/"
      xmlns:tiff="http://ns.adobe.com/tiff/1.0/"
      xmlns:ouestcharlie="http://ouestcharlie.app/ns/1.0/"
      rdf:about="">

      <!-- Standard EXIF fields (extracted at ingestion) -->
      <exif:DateTimeOriginal>2024-07-14T10:30:00</exif:DateTimeOriginal>
      <exif:GPSLatitude>48.8566</exif:GPSLatitude>
      <exif:GPSLongitude>2.3522</exif:GPSLongitude>
      <tiff:Make>Canon</tiff:Make>
      <tiff:Model>EOS R5</tiff:Model>
      <tiff:Orientation>1</tiff:Orientation>

      <!-- OuEstCharlie-specific fields -->
      <ouestcharlie:contentHash>sha256:a1b2c3d4e5f6...</ouestcharlie:contentHash>
      <ouestcharlie:metadataVersion>3</ouestcharlie:metadataVersion>
      <ouestcharlie:schemaVersion>1</ouestcharlie:schemaVersion>

      <!-- Tags (enrichment + albums) -->
      <dc:subject>
        <rdf:Bag>
          <rdf:li>ouestcharlie:faces/alice</rdf:li>
          <rdf:li>ouestcharlie:scene/outdoor</rdf:li>
          <rdf:li>album/vacation-2024</rdf:li>
        </rdf:Bag>
      </dc:subject>
    </rdf:Description>
  </rdf:RDF>
</x:xmpmeta>
```

### Data Model

```python
@dataclass
class XmpSidecar:
    content_hash: str | None
    metadata_version: int
    schema_version: int
    date_taken: datetime | None
    gps: tuple[float, float] | None
    camera_make: str | None
    camera_model: str | None
    orientation: int | None
    tags: list[str]
    _raw_xml: str                  # preserved for unknown fields / namespaces
```

The `_raw_xml` field preserves the original XML. On write, the toolkit modifies only the fields it manages and leaves the rest of the XML intact. This ensures compatibility with third-party XMP fields written by Lightroom, darktable, or ExifTool.

### XMP Read-Write Operations

```python
class XmpStore:
    def __init__(self, backend: Backend):
        self.backend = backend

    async def read(self, photo_path: str) -> tuple[XmpSidecar, VersionToken]:
        xmp_path = _xmp_path_for(photo_path)  # IMG_001.jpg → IMG_001.xmp
        data, version = await self.backend.read(xmp_path)
        sidecar = _parse_xmp(data.decode("utf-8"))
        return sidecar, version

    async def write(self, photo_path: str, sidecar: XmpSidecar, expected_version: VersionToken) -> VersionToken:
        xmp_path = _xmp_path_for(photo_path)
        sidecar.metadata_version += 1
        xml = _serialize_xmp(sidecar)
        return await self.backend.write_conditional(xmp_path, xml.encode("utf-8"), expected_version)
```

### Read-Modify-Write with Optimistic Concurrency

Same pattern as manifests — a retry loop around the read-modify-write cycle:

```python
    async def read_modify_write(
        self,
        photo_path: str,
        modify: Callable[[XmpSidecar], XmpSidecar],
        max_retries: int = 3
    ) -> XmpSidecar:
        for attempt in range(max_retries + 1):
            sidecar, version = await self.read(photo_path)
            updated = modify(sidecar)
            try:
                await self.write(photo_path, updated, version)
                return updated
            except VersionConflictError:
                if attempt == max_retries:
                    raise
                continue
```

Agent usage:

```python
# Enrichment agent adding face tags
async def tag_faces(self, photo_path: str, faces: list[str]):
    def modify(xmp: XmpSidecar) -> XmpSidecar:
        for face in faces:
            tag = f"ouestcharlie:faces/{face}"
            if tag not in xmp.tags:
                xmp.tags.append(tag)
        return xmp

    await self.xmp_store.read_modify_write(photo_path, modify)
```

### Conflict-Free Merges

Since agents write non-overlapping fields (HLD § Consistency Model), most retry scenarios are simple merges. The `modify` function always operates on the latest state, so:

- **Face enrichment** adds `ouestcharlie:faces/*` tags — does not touch `ouestcharlie:scene/*`
- **Scene enrichment** adds `ouestcharlie:scene/*` tags — does not touch `ouestcharlie:faces/*`
- **Housekeeping** writes `contentHash`, `metadataVersion`, EXIF fields — does not touch enrichment tags

If two enrichment agents of the same type run concurrently on the same photo (a scheduling error by Woof), the retry loop ensures one wins and the other re-reads and re-applies. Since enrichment is idempotent (same input pixels produce the same tags), the final result is correct.

### XMP Creation at Ingestion

When a new photo is indexed and no XMP sidecar exists, the toolkit creates one:

1. Extract EXIF from the photo file (using `pyexiv2`)
2. Compute `SHA-256(file_bytes)` for the content hash
3. Build an `XmpSidecar` with extracted fields, `metadataVersion=1`, `schemaVersion=1`
4. Write using `write_new()` to avoid overwriting an existing sidecar

If an XMP sidecar already exists (created by Lightroom, darktable, etc.), the toolkit reads it, merges in OuEstCharlie-specific fields (`contentHash`, `metadataVersion`, `schemaVersion`), and writes using the optimistic concurrency path. Existing third-party fields are preserved.

### XMP Parsing and Serialization

The toolkit uses `pyexiv2` for XMP read/write. `pyexiv2` wraps Exiv2, which handles the full XMP specification including:

- Multiple RDF namespaces
- Structured types (`rdf:Bag`, `rdf:Seq`, `rdf:Alt`)
- Namespace preservation (unknown namespaces passed through)

For writing OuEstCharlie-specific fields, the toolkit registers the `ouestcharlie:` namespace prefix and uses `pyexiv2`'s API to set/get values by qualified key.

## Error Handling

### Error Categories

Errors follow the three-category model from [controller_api.json](../../controller_api.json):

| Category | Toolkit behavior | Example |
|---|---|---|
| `transient` | Logged via MCP, agent continues with next item | File locked by another process |
| `permanent` | Logged via MCP, photo skipped | Corrupt EXIF, unsupported RAW format |
| `configuration` | Raised as exception, aborts the tool call | Backend root does not exist, invalid config |

### Per-Photo Error Isolation

The toolkit provides a context manager for per-photo processing that catches and logs errors without aborting the batch:

```python
async def rebuild_partition(self, backend: str, partition: str, **kwargs):
    photos = await self.backend.list_photos(partition)
    errors = 0

    for photo in photos:
        async with self.per_photo(photo, partition) as ctx:
            # ... process photo ...
            # If an exception occurs, it is caught, logged as permanent/transient,
            # and the loop continues
        if ctx.failed:
            errors += 1

    return {"photosProcessed": len(photos), "errors": errors}
```

## Dependencies

| Dependency | Purpose | Version constraint |
|---|---|---|
| `mcp` | MCP server SDK | `>=1.0` |
| `pyexiv2` | EXIF/XMP read-write (wraps Exiv2) | `>=2.8` |
| `Pillow` | Image processing, thumbnail generation | `>=10.0` |
| `rawpy` | RAW format support (wraps LibRaw) | `>=0.19` |

## References

- [MCP Python SDK](https://github.com/modelcontextprotocol/python-sdk)
- [MCP Specification (2025-11-25)](https://modelcontextprotocol.io/specification/2025-11-25)
- [pyexiv2](https://github.com/LeoHsiao1/pyexiv2) — EXIF/IPTC/XMP read-write
- [XMP Specification (ISO 16684)](https://www.iso.org/standard/75163.html)
- [HLD § Consistency Model](../../HLD.md) — optimistic concurrency design
- [controller_api.json](../../controller_api.json) — MCP tool definitions
