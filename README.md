# OuEstCharlie

A decentralized, storage-agnostic photo management system inspired by data lakehouse architectures.

## Overview

OuEstCharlie is designed around three core principles:
- **No central database** — metadata lives alongside photos in XMP sidecars and hierarchical manifests
- **Storage-agnostic** — works with local drives, S3, GCS, Azure Data Lake Storage Gen2, OneDrive, Kdrive
- **Stateless, distributed agents** — coordinated by a central controller (Woof) using the Model Context Protocol

## Project Structure

```
ouestcharly/
├── HLR.md                          # High-Level Requirements
├── HLD.md                          # High-Level Design (comprehensive)
├── HLD_rationale.md                # Design decision rationale & deep dives
├── Market.md                       # Market analysis & competitive positioning
├── OpenPoints.md                   # Known gaps & open questions
├── controller_api.json             # MCP tool definitions (agent interface)
│
├── project/
│   └── Version1_vision.md          # V1 charter, scope, decisions, risks
│
├── woof/                           # UI and Controller (Woof) design
│
└── agent/                          # Agent implementations

```

## Architecture

### Woof (Controller)

Woof is the central coordinator running on the user's device. It serves two roles:

1. **UI backend** — serves the photo browsing experience (web, mobile, desktop)
2. **MCP client** — orchestrates agents via the Model Context Protocol

**Documentation:**
- [woof/woof_LLR.md](woof/woof_LLR.md) — Requirements
- [woof/woof_LLD.md](woof/woof_LLD.md) — Design
- [woof/woof_LLD_rationale.md](woof/woof_LLD_rationale.md) — Rationale

### Agents

Agents are stateless workers (MCP servers) that execute against storage. Three types:

1. **Housekeeping** — maintain metadata consistency (manifests, thumbnails, XMP sidecars)
2. **Enrichment** — add metadata (face detection, scene classification)
3. **Ingestion** — import photos with date-based partitioning

Agents communicate with Woof via MCP (stdio or HTTP transport).

**Documentation:**
- [agent/agent_LLD_rationale.md](agent/agent_LLD_rationale.md) — Technology selection (Python + Rust)
- [agent/py_toolkit/py_toolkit_LLD.md](agent/py_toolkit/py_toolkit_LLD.md) — Python toolkit design
- [agent/py_toolkit/README.md](agent/py_toolkit/README.md) — Toolkit usage guide
- [controller_api.json](controller_api.json) — MCP tool schemas

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
| **Woof** | [woof_LLR.md](woof/woof_LLR.md) | [woof_LLD.md](woof/woof_LLD.md) | [woof_LLD_rationale.md](woof/woof_LLD_rationale.md) |
| **Agents** | — | [py_toolkit_LLD.md](agent/py_toolkit/py_toolkit_LLD.md) | [agent_LLD_rationale.md](agent/agent_LLD_rationale.md) |

## Project execution

| Document | Purpose |
|----------|---------|
| [project/Version1_vision.md](project/Version1_vision.md) | V1 charter, functional/non-functional goals, scope, decisions, risks |

## Technology Stack

### Woof (Controller)
- **Tauri** (Rust backend + web frontend)
- V1: localhost web app, wrap in Tauri later

### Agents
- **Python** — official MCP SDK, rich image ecosystem (Pillow, rawpy, pyexiv2)
- **Rust CLI helper** — `ouestcharlie-avif-grid` for AVIF grid container assembly

### Protocols & Standards
- **MCP** (Model Context Protocol) — agent ↔ Woof communication
- **XMP** (ISO 16684) — metadata storage
- **AVIF** — thumbnail containers (AV1-based, royalty-free)

## Current Status

### ✅ Design Phase Complete
- HLR, HLD, HLD rationale finalized
- Woof architecture & requirements detailed
- Agent LLD rationale complete (tech selection finalized)
- MCP tool definitions specified ([controller_api.json](controller_api.json))
- Version 1 vision & charter defined

### ✅ Python Toolkit Skeleton Complete
- Package structure, data models, protocols defined
- Local filesystem backend implemented
- ManifestStore and XmpStore with optimistic concurrency
- AgentBase wrapping FastMCP
- Stubs documented for XMP parsing, EXIF extraction, bloom filters

See [agent/py_toolkit/SKELETON_COMPLETE.md](agent/py_toolkit/SKELETON_COMPLETE.md) for details.

### 📋 Next Steps
1. Implement Python toolkit stubs (XMP parsing, EXIF extraction, bloom filters)
2. Build first agent (Whitebeard: housekeeping for local filesystem)
3. Build Woof controller (localhost web app)
4. Integrate agent ↔ Woof via MCP
5. Performance testing with 10K photos


## License

TBD

---

**Project Status:** Design complete, implementation in progress
**Target:** V1 with 10K photos on macOS (local + mounted cloud drives)
