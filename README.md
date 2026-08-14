# OuEstCharlie

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![MCP Compatible](https://img.shields.io/badge/MCP-compatible-blueviolet)](https://modelcontextprotocol.io/)

A decentralized, storage-agnostic media management system (photos and videos) inspired by data lakehouse architectures.

> **More about OuEstCharlie on the [OuEstCharlie Blog](https://ouestcharlie.github.io/ouestcharlie/)**

## Overview

A OuEstCharlie is a gallery for **media files — photos and videos** within your AI Assistant (Claude, Goose...). The system is designed around these core principles (see [HLD.md](HLD.md)):

- **No central database** — metadata lives alongside the media: per-file XMP sidecars are the source of truth, and each backend carries its own LanceDB columnar index for fast queries. There is no shared catalog service; every backend is self-contained, with its own root marker and metadata tree.
- **Storage-agnostic** — works with local drives, S3, GCS, Azure Data Lake Storage Gen2, OneDrive, Kdrive.
- **Woof as mediator (control plane)** — a single local MCP server is the security and operational boundary between the AI assistant and the agent ecosystem. It owns credentials, mints scoped short-lived tokens, and orchestrates agents. Woof is AI-assistant-agnostic (any MCP-capable client).
- **Stateless, distributed agents (data plane)** — idempotent workers coordinated by Woof over the Model Context Protocol, each running with least-privilege scope.
- **Immutable media & content-based identity** — photos and videos are never modified in place; a BLAKE3 content hash gives each file a stable identity and enables cross-backend deduplication.

## Repositories

| Repository | Purpose |
|------------|---------|
| [**ouestcharlie** *(this repo)*](https://github.com/ouestcharlie/ouestcharlie/) | Architecture docs — HLR/HLD/rationale, MCP interface, project charter |
| [ouestcharlie-woof](https://github.com/ouestcharlie/ouestcharlie-woof/) | Woof controller — MCP server, gallery UI, agent orchestration |
| [ouestcharlie-whitebeard](https://github.com/ouestcharlie/ouestcharlie-whitebeard/) | Indexing agent (index mode) |
| [ouestcharlie-wally](https://github.com/ouestcharlie/ouestcharlie-wally/) | Search / consumption agent |
| [ouestcharlie-py-toolkit](https://github.com/ouestcharlie/ouestcharlie-py-toolkit/) | Python toolkit for building agents (AgentBase, stores, data models) |
| [ouestcharlie-imageproc](https://github.com/ouestcharlie/ouestcharlie-imageproc/) | Rust `image-proc` coprocessor — decode, resize, AVIF/JPEG encode |

## Architecture

### Woof (Controller)

Woof is the central coordinator running on the user's device. It serves two roles:

1. **UI backend** — serves the photo browsing experience (web, mobile, desktop)
2. **MCP client** — orchestrates agents via the Model Context Protocol

### Agents

Agents are stateless workers (MCP servers) that execute against storage. Three types:

1. **Housekeeping** — maintain metadata consistency (manifests, thumbnails, XMP sidecars)
2. **Enrichment** — add metadata (face detection, scene classification)
3. **Ingestion** — import photos with date-based partitioning

Agents communicate with Woof via MCP (stdio or HTTP transport).

**Documentation:**
- [agent/agent_LLD_rationale.md](agent/agent_LLD_rationale.md) — Technology selection (Python + Rust)
- MCP tool schemas — defined in each agent's tool registrations, discoverable at runtime via `tools/list`

**Python toolkit** (in [ouestcharlie-py-toolkit](../ouestcharlie-py-toolkit)):
- [README.md](../ouestcharlie-py-toolkit/README.md) — Toolkit usage guide

### Data Model

See High-Level Design

## Design Documentation

### High-Level

| Document | Purpose |
|----------|---------|
| [HLR.md](HLR.md) | Requirements: principles, agent taxonomy, albums, least privilege |
| [HLD.md](HLD.md) | Design: architecture, EXIF pipeline, manifests, partitioning, consistency, security |
| [HLD_rationale.md](HLD_rationale.md) | Rationale: reasoning for each HLD decision, alternatives considered |

### Low-Level

| Component | Requirements | Design | Rationale |
|-----------|-------------|--------|-----------|
| **Woof** | [woof_LLR.md](https://github.com/ouestcharlie/ouestcharlie-woof/blob/master/woof_LLR.md) | [woof_LLD.md](https://github.com/ouestcharlie/ouestcharlie-woof/blob/master/woof_LLD.md) | [woof_LLD_rationale.md](https://github.com/ouestcharlie/ouestcharlie-woof/blob/master/woof_LLD_rationale.md) |
| **Agents general** | — | - | [agent_LLD_rationale.md](agent/agent_LLD_rationale.md) |
| **Agent toolkit** | | [py_toolkit_LLD.md](https://github.com/ouestcharlie/ouestcharlie-py-toolkit/blob/master/py_toolkit_LLD.md) |

## Technology Stack

### Woof (Controller)
- **Python** server (MCP + HTTP)
- **Svelte** frontend

### Agents
- **Python** — official MCP/FastMCP SDK, rich image ecosystem (Pillow, rawpy, pyexiv2)
- **Rust `image-proc` coprocessor** ([ouestcharlie-imageproc](https://github.com/ouestcharlie/ouestcharlie-imageproc/)) — pixel operations: decode, EXIF orientation, resize/fit, AVIF grid and JPEG encode

### Protocols & Standards
- **MCP** (Model Context Protocol) — agent ↔ Woof communication, Woof MCP App
- **XMP** (ISO 16684) — metadata storage
- **AVIF** — thumbnail containers (AV1-based, royalty-free)

---

## Project execution

### Current Scope

See the [Status section in Woof](https://github.com/ouestcharlie/ouestcharlie-woof#status)

### Current iteration

| Document | Purpose |
|----------|---------|
| [project/Version1_vision.md](project/Version1_vision.md) | V1 charter, functional/non-functional goals, scope, decisions, risks |

### Issues, feature suggestions, implementation plans

Bug reports and feature suggestions are welcome in the [Github issues](https://github.com/ouestcharlie/ouestcharlie/issues).

Design and implementation plans are stored as Markdown in the [project/issues folder](https://github.com/ouestcharlie/ouestcharlie/tree/master/project/issues).

### Contributing

Contributions are welcome. Please:

- **Open an issue first** for anything beyond a small fix — bug reports, feature requests, or design questions — so the change can be discussed against the [HLD](HLD.md)/[HLR](HLR.md) before work starts.
- **Submit pull requests to the relevant repository** from the table above (architecture/docs changes go here, in `ouestcharlie`; component changes go to `ouestcharlie-woof`, `ouestcharlie-whitebeard`, `ouestcharlie-wally`, `ouestcharlie-py-toolkit`, or `ouestcharlie-imageproc`).
- **Align with the documentation hierarchy** — requirements → design → implementation. If a change affects architecture or data models, update the corresponding HLD/LLD in the same PR.
- **Keep PRs focused and atomic**, with a clear description of the rationale.

## License

MIT license

