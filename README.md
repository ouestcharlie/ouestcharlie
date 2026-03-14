# OuEstCharlie

A decentralized, storage-agnostic photo management system inspired by data lakehouse architectures.

## Overview

OuEstCharlie is designed around three core principles:
- **No central database** — metadata lives alongside photos in XMP sidecars and hierarchical manifests
- **Storage-agnostic** — works with local drives, S3, GCS, Azure Data Lake Storage Gen2, OneDrive, Kdrive
- **Stateless, distributed agents** — coordinated by a central controller (Woof) using the Model Context Protocol

## Repository Layout

This project is split across three repositories:

| Repository | Purpose |
|------------|---------|
| **ouestcharlie** *(this repo)* | Architecture docs, HLR/HLD, MCP interface, project charter |
| [ouestcharlie-woof](../ouestcharlie-woof) | Woof controller — LLR, LLD, rationale |
| [ouestcharlie-py-toolkit](../ouestcharlie-py-toolkit) | Python toolkit for building agents |

### This repository

```
ouestcharlie/
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
└── agent/
    └── agent_LLD_rationale.md      # Technology selection (Python + Rust)
```

## Architecture

### Woof (Controller)

Woof is the central coordinator running on the user's device. It serves two roles:

1. **UI backend** — serves the photo browsing experience (web, mobile, desktop)
2. **MCP client** — orchestrates agents via the Model Context Protocol

**Documentation** (in [ouestcharlie-woof](../ouestcharlie-woof)):
- [woof_LLR.md](../ouestcharlie-woof/woof_LLR.md) — Requirements
- [woof_LLD.md](../ouestcharlie-woof/woof_LLD.md) — Design
- [woof_LLD_rationale.md](../ouestcharlie-woof/woof_LLD_rationale.md) — Rationale

### Agents

Agents are stateless workers (MCP servers) that execute against storage. Three types:

1. **Housekeeping** — maintain metadata consistency (manifests, thumbnails, XMP sidecars)
2. **Enrichment** — add metadata (face detection, scene classification)
3. **Ingestion** — import photos with date-based partitioning

Agents communicate with Woof via MCP (stdio or HTTP transport).

**Documentation:**
- [agent/agent_LLD_rationale.md](agent/agent_LLD_rationale.md) — Technology selection (Python + Rust)
- [controller_api.json](controller_api.json) — MCP tool schemas

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
| **Woof** | [woof_LLR.md](../ouestcharlie-woof/woof_LLR.md) | [woof_LLD.md](../ouestcharlie-woof/woof_LLD.md) | [woof_LLD_rationale.md](../ouestcharlie-woof/woof_LLD_rationale.md) |
| **Agents** | — | [ouestcharlie-py-toolkit](../ouestcharlie-py-toolkit) | [agent_LLD_rationale.md](agent/agent_LLD_rationale.md) |

## Project execution

| Document | Purpose |
|----------|---------|
| [project/Version1_vision.md](project/Version1_vision.md) | V1 charter, functional/non-functional goals, scope, decisions, risks |

## Technology Stack

### Woof (Controller)
- **Python** server (MCP + HTTP)
- **Svelte** frontend

### Agents
- **Python** — official MCP/FastMCP SDK, rich image ecosystem (Pillow, rawpy, pyexiv2)
- **Rust CLI helper** — `ouestcharlie-avif-grid` for AVIF grid container assembly

### Protocols & Standards
- **MCP** (Model Context Protocol) — agent ↔ Woof communication, Woof MCP App
- **XMP** (ISO 16684) — metadata storage
- **AVIF** — thumbnail containers (AV1-based, royalty-free)

## Current Status

### ✅ Design Phase Complete
- HLR, HLD, HLD rationale finalized
- Woof architecture & requirements detailed
- Agent LLD rationale complete (tech selection finalized)
- MCP tool definitions specified ([controller_api.json](controller_api.json))
- Version 1 vision & charter defined

### ✅ Implementation of the toolkit and agents
- Package structure, data models, protocols defined
- Local filesystem backend implemented
- ManifestStore and XmpStore
- First version of indexer (Wally) and searcher (Wally)
- First version of the controller and interface (Woof)


### 📋 Next Steps
- Refine search DSL or use existing standard
- Indexing and search optimizations
- Packaging

## Context

| Repository | Purpose |
|------------|---------|
| [**ouestcharlie** *This repo*](https://github.com/ouestcharlie/ouestcharlie/) | Architecture docs, HLR/HLD, MCP interface |
| [ouestcharlie-woof**](https://github.com/ouestcharlie/ouestcharlie-woof/) | Woof controller |
| [ouestcharlie-py-toolkit](https://github.com/ouestcharlie/ouestcharlie-py-toolkit) | Python toolkit for agents |
| [ouestcharlie-whitebeard](https://github.com/ouestcharlie/ouestcharlie-whitebeard) | Indexing agent |
| [ouestcharlie-wally](https://github.com/ouestcharlie/ouestcharlie-wally) | Search/consumption agent |

## License

MIT license

---

**Project Status:** Design complete, implementation in progress
**Target:** V1 with 10K photos on macOS (local + mounted cloud drives)
