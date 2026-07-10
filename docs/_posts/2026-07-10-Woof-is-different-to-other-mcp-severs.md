<!--
OUTLINE — not drafted yet. Edit freely, discuss in chat, then we'll draft prose section by section.
-->

# Title (working): Woof Is Different From Other Photo MCP Servers

## Revised thesis (per discussion)
Main point is NOT the backend — Woof V1 is local-only today, which is
honestly a current weakness vs. multi-backend competitors, not a
strength to lead with. The real differentiator is the **integration
with Claude for both search AND browsing** in the same conversational
surface: ask in natural language, then actually look at and navigate
the results (grid/carousel/full-screen) without leaving the chat.
Competitors typically do one or the other, not both, in one place.

## 1. Hook
You can already ask an AI assistant to "find my photos from Spain."
Most photo MCP servers either stop there — you get a list of filenames or
paths back as text — or you need to switch to another UI. 
Woof's difference isn't where your photos live;
it's what happens the moment after the search: you *see* them, browse
them, flip through them, without leaving the conversation.

## 2. The landscape today
As of today, none of Apple, Google, Microsoft, or Amazon has released
an official MCP server for their own photo product (Photos, Google
Photos, OneDrive, Amazon Photos) — every server discussed below is a
third-party/community project reverse-engineering the vendor's app or
API, not a vendor-blessed integration. Worth keeping in mind for the
credential-sharing point in section 6: where a credential is required,
it's being handed to a community project, not the platform owner.

Verified against each project's README (see **References** at the end)
on 2026-07-10 — framed around search vs. browsing, not backend
architecture:
- **[drolosoft/immich-photo-manager](https://github.com/drolosoft/immich-photo-manager)**
  — CLIP-based natural-language search over an Immich library, plus
  geographic/temporal album curation. Notably, it *does* produce a
  browsable surface: a "self-contained HTML page with embedded
  thumbnails" it generates on request — closer to Woof than most
  competitors, but it's a generated artifact you open separately
  (a file or a browser tab), not a view rendered live inside the
  conversation the way an MCP App is.
- **[barryw/ImmichMCP](https://github.com/barryw/ImmichMCP)** — same
  Immich backend, CLIP semantic search plus structured metadata
  filters, but results come back as JSON with thumbnail/download URLs
  only; no gallery generation — the client (or user) has to render
  or open them.
- **[sweetrb/apple-photos-mcp](https://github.com/sweetrb/apple-photos-mcp)**
  — queries the macOS Photos library via `osxphotos`. Search is
  structured-filter only (date range, album, keyword, person,
  favorite/hidden, title/description substring) — no semantic/CLIP
  search. Fully local, no credentials of any kind. Results are
  JSON summaries; actually viewing a photo means opening it in
  Photos.app or exporting it to disk.
- **[savethepolarbears/google-photos-mcp](https://github.com/savethepolarbears/google-photos-mcp)**
  — broader than pure metadata filtering: `search_photos` is a
  text-based search against the Google Photos Library API (leaning on
  Google's own backend categorization), plus a separate
  `search_media_by_filter` tool for structured filters (date, category,
  media type, favorites, archived), plus location search. Also ships a
  "Picker API" flow that opens the *user's browser* to Google's own
  picker UI to select photos — a real browsing surface, just not one
  rendered inside the AI conversation. Requires a Google Cloud OAuth
  client ID/secret and a full OAuth consent flow; tokens are cached in
  the OS keychain.

What they share: none render a live, interactive photo gallery inside
the AI conversation itself. The closest is
drolosoft/immich-photo-manager's generated HTML gallery, and even
that's a separate artifact rather than an in-conversation MCP App.

### Comparison table

| MCP server | Search | Browse in-chat | No credential sharing |
|---|---|---|---|
| **Woof** | Structured facets (date, rating, dimensions, orientation, tags, GPS, camera make/model/lens, ISO/aperture/shutter/focal length) + full-text search on description, AND/OR-combinable | ✅ Inline MCP App (grid/carousel/full-screen), rendered live in the conversation | ✅ Local-only, STDIO |
| drolosoft/immich-photo-manager | ✅ Semantic (CLIP) + geo/temporal | 🟡 Generates a separate HTML gallery page, not inline in the conversation | ❌ Immich instance API key |
| barryw/ImmichMCP | ✅ Semantic (CLIP) + metadata filters | ❌ JSON + URLs only, no gallery | ❌ Immich instance API key |
| sweetrb/apple-photos-mcp | Structured filters (date/album/keyword/person) | ❌ JSON only, view in Photos.app or export | ✅ Local-only, no credentials |
| savethepolarbears/google-photos-mcp | ✅ Text search + structured filters (Google backend) | 🟡 Picker API opens Google's own picker in the browser, not inline | ❌ Google OAuth client ID/secret |

Note on "credential sharing": the two Immich-backed servers require an
API key for the user's **own self-hosted** Immich instance — a
different trust boundary than handing OAuth credentials to a
third-party cloud API (Google Photos MCP), even though both count as
"a credential the MCP server holds" in this table.

Framed around the axes that matter — search, browse in one surface,
and credential exposure — rather than backend architecture. Woof is
the only one with a live in-conversation gallery. Its search is
richer than "filter-based" implies: a wide structured-facet set
(Wally's `search_photos`, backed by a LanceDB index — see
`ouestcharlie-wally/src/wally/searcher.py` and
`ouestcharlie-py-toolkit/src/ouestcharlie_toolkit/fields.py`) *plus*
genuine full-text search over the description field (LanceDB FTS,
BM25-ranked, not substring matching), all AND/OR-combinable. What it
still lacks is CLIP/embedding-based *visual* semantic search — "find
photos that look like a sunset" without a matching keyword/tag/
description — which the Immich-backed competitors have. That's the
honest weakness in section 7, refined to be specific rather than
just "filter-based."

## 3. Difference 1 — Search AND browse in one surface
Woof's gallery is an MCP App — an interactive view rendered inside the
Claude conversation itself. A search ("show me the beach trip in
2024") returns a live grid the user can scroll, switch to carousel,
open full-screen — all inline, no context switch to another
application. This is the core claim of the article.

## 4. Difference 2 — Conversational refinement of what you're browsing
Because search and browsing share the same surface, the user can
narrow/broaden/pivot the query conversationally while looking at
results ("now just the ones with Mia", "zoom into that one", "go back
a week") — vs. competitors where a text-only tool response can't be
refined by pointing at what's on screen, because nothing is on screen.

## 5. Difference 3 — A crowd of agents behind one experience
Brief, secondary point: Woof mediates stateless agents (Wally for
query/browse, Whitebeard for ingestion) behind this single experience,
so the search+browse surface can grow (enrichment, memories) without
becoming a monolith. Keep this short — supporting detail, not the
headline.

## 6. Difference 4 — No credential sharing
Several competitors require handing the MCP server a credential:
Google Photos MCP needs a Google Cloud OAuth client ID/secret plus a
full consent flow; the two Immich-backed servers need an API key for
your Immich instance (a smaller trust boundary since that's usually
self-hosted, but still a credential the MCP process holds). Woof is
local-only: no API keys to generate, share, or revoke — the assistant
talks to a local MCP server over STDIO, and there's no credential to
leak because none exists.

## 7. Honest weaknesses — backend, semantic search, and feature gaps
Say directly: Woof V1 only supports local/mounted drives; Immich-based
competitors already support a real multi-user server. On search,
Woof's structured facets + full-text description search cover a lot
of ground, but it's not CLIP/embedding-based visual semantic search —
"sunset at the beach" only works if that language shows up in tags,
keywords, or the description; Immich-backed competitors search the
actual pixel content. Don't oversell — this is a roadmap gap, not a
hidden strength. Cloud backends and visual semantic search are open
points, not solved. Also no editing, no enrichment agents
(faces/scenes) yet, index mode only. Keep short.

## 8. Closing
Through-line: Woof optimizes the *experience* of asking and then looking — search and browsing
unified in the conversation. More to come as enrichment agents and more backends will be supported.

---

## References
Landscape claims (search mechanism, browsing surface, credential
model) were verified directly against each project's README via the
GitHub API on 2026-07-10. Re-check before publishing if drafting is
delayed — these are actively developed projects and behavior can
change:
- [drolosoft/immich-photo-manager](https://github.com/drolosoft/immich-photo-manager) — README
- [barryw/ImmichMCP](https://github.com/barryw/ImmichMCP) — README
- [sweetrb/apple-photos-mcp](https://github.com/sweetrb/apple-photos-mcp) — README
- [savethepolarbears/google-photos-mcp](https://github.com/savethepolarbears/google-photos-mcp) — README

No official vendor MCP server for a photo product (verified via web
search on 2026-07-10; re-check periodically, this changes fast):
- [Announcing official MCP support for Google services](https://cloud.google.com/blog/products/ai-machine-learning/announcing-official-mcp-support-for-google-services) — Google's official MCP servers cover Workspace/Cloud services; no Google Photos
- [Apple just turned Safari into something AI agents can control](https://thenewstack.io/safari-mcp-platform-infrastructure/) — Apple's official MCP servers are Safari/WebKit devtools; no Photos
- [microsoft/mcp — Catalog of official Microsoft MCP servers](https://github.com/microsoft/mcp) — official OneDrive/SharePoint MCP server exists (general file management), no Photos-specific server
- [Welcome to Open Source MCP Servers for AWS](https://awslabs.github.io/mcp/) — AWS official MCP servers are cloud infrastructure (MSK, Lambda, ECS, EKS); no Amazon Photos

Woof's own search facets/behavior are verified against the current
source, not docs: `ouestcharlie-wally/src/wally/searcher.py`
(`search_photos`, `FilterGroup`/`FilterLeaf` AND/OR composition, FTS
query path) and `ouestcharlie-py-toolkit/src/ouestcharlie_toolkit/fields.py`
(`PHOTO_FIELDS` facet definitions: dateTaken, rating, width/height,
orientation, tags, make/model/lensModel, gps, description, isoSpeed,
aperture, exposureTime, focalLength/focalLength35mm, directory).

## Production notes
- We will add a screencast showing a real session (search → browse →
  refine) to make the core differentiator (section 3/4) tangible —
  placement TBD, likely embedded near section 3 or in the closing.

## Open questions for discussion
- Add a short concrete example/transcript showing search→browse→refine
  in one flow, to make the differentiator tangible? (may be superseded
  by the screencast above)
- ~~Do we still want a comparison table, now framed as "search only" vs
  "search + browse" vs "browse only" rather than backend architecture?~~
  Resolved — added under section 2, framed as search / browse / API
  key sharing.
- The outline previously listed a "Generic semantic-image-search MCPs
  (CLIP+FAISS style)" category with no named project. Removed from
  section 2/table since it couldn't be attributed to a specific,
  verifiable repo — re-add only with a concrete project to cite, or
  keep the comparison scoped to the four named/verified competitors.
