# OuEstCharlie — Claude Working Rules

## Project Context

OuEstCharlie is a decentralized, storage-agnostic photo management system with:
- **Woof**: Central controller (UI backend + MCP client coordinator)
- **Agents**: Stateless workers (MCP servers) for housekeeping, enrichment, ingestion
- **No central database**: Metadata in XMP sidecars + hierarchical manifests

## Architecture Understanding Required

Before making changes, ALWAYS:
1. Check relevant design documents:
   - [HLR.md](../HLR.md) — High-level requirements
   - [HLD.md](../HLD.md) — System design & data model
   - [HLD_rationale.md](../HLD_rationale.md) — Design decisions & alternatives
   - Component-specific LLDs in `woof/` and `agent/` directories
2. Understand the MCP interface: [controller_api.json](../controller_api.json)
3. Review [Version1_vision.md](../project/Version1_vision.md) for V1 scope boundaries

## Code Guidelines

### General
- **Respect the documentation hierarchy**: Requirements → Design → Implementation
- **Don't bypass existing architecture**: Changes should align with HLD/LLD
- **Keep agents stateless**: No persistent state in agent code
- **Storage-agnostic**: Never hardcode assumptions about storage backend

### Python (Agents)
- Follow toolkit structure in `agent/py_toolkit/`
- Use the `AgentBase` wrapper around FastMCP
- Respect data models in `agent/py_toolkit/src/models/`
- Implement optimistic concurrency for manifest/XMP writes
- Check [py_toolkit_LLD.md](../agent/py_toolkit/py_toolkit_LLD.md) for design patterns

### JavaScript / Frontend
- **No inline JS**: Never use inline `<script>` tags or `onclick`/`onX` attributes in HTML. All JavaScript must live in separate `.js` files and be referenced via `<script src="...">`.

### Rust (CLI helpers)
- Used only for performance-critical operations (e.g., AVIF grid assembly)
- Keep CLI interface minimal and well-documented

### Documentation
- **Update docs when design changes**: If you modify architecture, update corresponding HLD/LLD
- **Use established patterns**: Follow the existing LLR/LLD/rationale structure
- **Mark open questions**: Add to [OpenPoints.md](../OpenPoints.md) if uncertain
- **Avoid listing individual code files**: Don't enumerate specific implementation files in documentation - it's not maintainable. Instead, describe patterns, directories, or link to generated documentation
- **Document only what is non-obvious**: Don't document APIs or what code already makes clear by reading it. Only document constraints, architectural decisions, non-obvious invariants, and cross-cutting behavior not visible from a single file.
- **Don't reference issue numbers in code or docs**: Issue numbers (e.g. "OEC-39") are only valid at the time of their implementation and become stale afterwards. Explain the rationale directly instead of pointing to an issue.

## Testing & Validation

- Target: 10K photos on local or mounted cloud drives
- Test against both local filesystem and cloud storage backends
- Validate MCP communication between Woof and agents
- Check XMP sidecar consistency

## Current Phase: Implementation

See project/ subfolder for current status and open points

## Commit Conventions

- Keep commits focused and atomic
- Reference design docs in commit messages when implementing from specs
- Use Co-Authored-By for AI-assisted changes

## Communication & Documentation

- **OuEstCharlie is cross-platform**: runs on macOS, Windows, and Linux. Never write as if it's macOS-only.
- **Woof is AI-assistant-agnostic**: compatible with any MCP-capable assistant (Claude Desktop, ChatGPT, Goose, etc.). Never write as if Claude Desktop is the only supported client.

## What NOT to Do

- ❌ Don't add a central database or stateful storage in Woof
- ❌ Don't create tight coupling between agents and storage backends
- ❌ Don't implement features outside V1 scope (check Version1_vision.md)
- ❌ Don't modify XMP/manifest schemas without updating HLD
- ❌ Don't add dependencies without considering cross-platform compatibility

## Questions or Uncertainty?

1. Check if it's documented in HLD/LLD
2. Review rationale documents for context
3. Look at [OpenPoints.md](../OpenPoints.md) for known gaps
4. Ask before making architectural changes