# OuEstCharlie Version 1 Vision

## Charter

Functional goals:
- Index pictures on local drive (MacOs)
    - [x] Create corresponding agent (Whitebeard)
    - [x] Create XMP including ouestcharlie: specific fields (picture identity hash...)
    - [x] ~~Create manifests (leaf)~~ LanceDB index
    - [x] Create thumbnails and previews
    - [x] Trivial reindex: check new partitions of image files, do not check metadata or photo changes
- Search pictures based on simple predicates (e.g. date)
    - [x] Create corresponding consumption agent (Wally)
    - Retrieve and cache matching manifests and previews
    - [] Open picture using file system
    - [x] Batch update of index (only add new photos)
- Gallery as an MCP App
    - [x] Gallery integration as MCP App
    - [x] Grid view based on thumbnails
    - [x] Carousel view based on previews generated on the fly
    - [x] Full screen switch
    - [x] Indexing progress UI
- Controller agent and App (Woof)
    - [x] MCP Server as main entry point
    - [x] MCP client and manager of Wally and Whitebeard
    - [x] MCP App with HTML/JS forms to display the gallery and preview
- [x] Support for modern image formats (JPEG, HEIC, RAW, PNG)


Non functional goals
- Test context
    - [x] Standard local drive
    - [x] Mounted cloud drive (iCloud, Onedrive, kDrive)
    - [x] 10k pictures
- Tests to accomplish
    - indexing performance
        - criteria: time to index 100, 1k and 10k pictures
    - retrieval performance as time to get 1st and all matching results
        - criteria: date as full date (Y-M-d), month (Y-M) and year (Y)    
- Define technologies for Woof and agent
    - [x] Woof controller and UI
    - [x] Agent toolkit and implementations
- [x] Validate controller-agent protocol through MCP

Out of scope:
- No cloud backends (S3, GCS, ADLS, OneDrive, Kdrive)
- No enrichment agents (faces, scenes)
- No albums
- No ingest mode (index only)
- Only trivial re-indexing (do not check photo metadata updates)
- No multi-device
~~- No bloom filters~~
- No background daemon (launchd): Woof runs as a stdio MCP server launched on demand by Claude Desktop. Daemon mode is deferred to V2 when change detection and scheduled enrichment justify it.

## Decisions
- **Woof**: Local MCP server + Claude Desktop as UI shell. Woof is launched on demand by Claude Desktop as a stdio MCP server and exposes OuEstCharlie capabilities as MCP tools. The gallery is served as an MCP App (interactive iframe inside Claude Desktop's conversation). No standalone desktop app and no background daemon for V1. See [woof_LLD_rationale.md](../ouestcharlie-woof/woof_LLD_rationale.md) for the decision analysis; the Tauri and daemon alternatives are preserved there for reference.
- **Agents**: Python + Rust AVIF helper. Official MCP Python SDK, rich image ecosystem (~~Pillow~~, rawpy, pyexiv2). Rust CLI tool for AVIF grid container assembly. See [agent/agent_LLD_rationale.md](../agent/agent_LLD_rationale.md).

## Open points
- Query interface
- Schemas
    - Manifest JSON schema (leaf + parent)
    - XMP sidecar: which ouestcharlie: fields for V1 (contentHash, metadataVersion, schemaVersion — anything else?)
- Parameters
    - AVIF grid container: encoding parameters (quality, tile size)

## Risks
- Mounted cloud drive testing (iCloud, OneDrive) may surface issues with file watching, symlinks, and .icloud placeholder files on macOS. Worth noting as a known risk.