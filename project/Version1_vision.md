# OuEstCharlie Version 1 Vision

## Charter

Functional goals:
- Index pictures on local drive (MacOs)
    - Create corresponding agent (Whitebeard)
    - Create XMP including ouestcharly: specific fields (picture identity hash...)
    - Create manifests (leaf)
    - Create thumbnails and previews
- Search pictures based on simple predicates (e.g. date)
    - Create corresponding consumption agent (Wally)
    - Retrieve and cache matching manifests and previews
    - Open picture using file system
- Support for modern image formats (JPEG, HEIC, RAW, PNG)


Non functional goals
- Test context
    - Standard local drive
    - Mounted cloud drive (iCloud, Onedrive)
    - 10k pictures
- Tests to accomplish
    - indexing performance
        - criteria: time to index 100, 1k and 10k pictures
    - retrieval performance as time to get 1st and all matching results
        - criteria: date as full date (Y-M-d), month (Y-M) and year (Y)    
- Define technologies for Woof and agent
    - Woof controller and UI
    - Agent toolkit and implementations
- Validate controller-agent protocol through MCP

Out of scope:
- No cloud backends (S3, GCS, ADLS, OneDrive, Kdrive)
- No enrichment agents (faces, scenes)
- No albums
- No ingest mode (index only)
- No change detection / re-indexing
- No multi-device

## Decisions
- **Woof**: Tauri (Rust backend + web frontend). V1 can start as a localhost web app, then wrap in Tauri — zero throwaway work. See [woof/woof_LLD_rationale.md](../woof/woof_LLD_rationale.md).
- **Agents**: Python + Rust AVIF helper. Official MCP Python SDK, rich image ecosystem (Pillow, rawpy, pyexiv2). Rust CLI tool for AVIF grid container assembly. See [agent/agent_LLD_rationale.md](../agent/agent_LLD_rationale.md).

## Open points
- Query interface
- Schemas
    - Manifest JSON schema (leaf + parent)
    - XMP sidecar: which ouestcharlie: fields for V1 (contentHash, metadataVersion, schemaVersion — anything else?)
- Parameters
    - AVIF grid container: encoding parameters (quality, tile size)

## Risks
- Mounted cloud drive testing (iCloud, OneDrive) may surface issues with file watching, symlinks, and .icloud placeholder files on macOS. Worth noting as a known risk.