# Agent LLD Rationale

This document captures the reasoning behind technology choices for OuEstCharlie agents.

## Agent Technology

Agents are MCP servers launched as child processes (stdio transport). They can use any language — the MCP protocol boundary decouples agent implementation from Woof.

### Requirements

1. **MCP server SDK** — maturity and documentation
2. **EXIF extraction** — JPEG, HEIC, RAW, PNG
3. **XMP writing** — XML generation
4. **SHA-256** — fast hashing of large files
5. **AVIF grid encoding** — multi-tile ISOBMFF containers (not just single images)
6. **Image resizing** — thumbnail/preview generation across formats

### Alternatives considered

| | TypeScript (Node.js) | Python | Rust |
|---|---|---|---|
| **MCP SDK** | Reference implementation (`@modelcontextprotocol/sdk`) | Official SDK (`mcp`) | Community (`mcp-rust-sdk`), less mature |
| **EXIF** | `exifr` — pure JS, handles JPEG/HEIC/CR3/TIFF/PNG | `exifread`, `pyexiv2`, or shell to `exiftool` | `kamadak-exif` for JPEG; HEIC/RAW needs FFI |
| **XMP write** | Template strings or `fast-xml-parser` | `python-xmp-toolkit` (wraps Adobe XMP SDK) | `xmp-toolkit` crate |
| **SHA-256** | `crypto` module (C-backed, fast) | `hashlib` (C-backed, fast) | `sha2` crate (fastest) |
| **Image resize** | `sharp` (wraps libvips — JPEG/HEIC/PNG/AVIF/RAW) | `Pillow` + `rawpy` for RAW | `image` crate; HEIC/RAW support limited |
| **AVIF grid** | No grid support in sharp/libvips | No grid support in Pillow | `libavif-rs` — native grid container support |
| **Dev velocity** | High | High | Moderate |

### AVIF grid gap

The critical gap is AVIF grid containers. Sharp and Pillow encode single AVIF images, but grid containers (multiple independently-decodable tiles in one ISOBMFF file) require `libavif` directly. Only Rust has clean bindings for this via `libavif-rs`.

### Two viable approaches

**Option A — Python agents + Rust AVIF helper**
- Agents in Python: official MCP SDK, `Pillow` + `rawpy` for resizing, `exifread`/`pyexiv2` or `exiftool` for EXIF, fast iteration
- Small Rust CLI tool (`ouestcharlie-avif-grid`) for grid container assembly — agents shell out to it
- Rich image processing ecosystem — Python is the dominant language for image/ML workflows
- Pragmatic: use the best tool for each job

**Option B — All Rust**
- Single language with Tauri backend, native `libavif-rs` for grids, best performance
- MCP SDK is less mature — more risk, more debugging
- Slower development velocity but no language boundary
- Strongest long-term choice if the team is Rust-comfortable

### Recommendation for V1

**Option A**: Python agents. The official MCP Python SDK is well-documented and actively maintained. Python's image processing ecosystem (`Pillow`, `rawpy`, `exiftool`, `pyexiv2`) is the richest available — particularly for HEIC and RAW formats which are critical for V1. Fast iteration on Whitebeard and Wally. AVIF grid complexity is isolated in a focused Rust CLI tool. If performance benchmarks on 10k photos reveal bottlenecks, individual agents can be rewritten in Rust without changing the MCP interface.

**References:**
- [MCP Python SDK](https://github.com/modelcontextprotocol/python-sdk)
- [Pillow](https://pillow.readthedocs.io/) — Python imaging library
- [rawpy](https://github.com/letmaik/rawpy) — RAW image processing (wraps LibRaw)
- [pyexiv2](https://github.com/LeoHsiao1/pyexiv2) — EXIF/IPTC/XMP read/write (wraps Exiv2)
- [exifread](https://github.com/ianare/exif-py) — Pure Python EXIF reader
- [python-xmp-toolkit](https://github.com/python-xmp-toolkit/python-xmp-toolkit) — XMP read/write (wraps Exempi)
- [libavif-rs](https://github.com/paolobarbolini/ravif) — Rust bindings for libavif
- [libavif](https://github.com/AOMediaCodec/libavif) — C library for AVIF encoding/decoding with grid support
