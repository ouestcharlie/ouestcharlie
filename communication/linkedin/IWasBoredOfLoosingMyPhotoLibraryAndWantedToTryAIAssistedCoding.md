# I Was Bored of Losing My Photo Library and Wanted to Try AI-Assisted Coding

**I got tired of losing my photo library every time I switched cloud providers. So I built something about it.**

A few months ago, I migrated to @Infomaniak — and lost all my albums, face tags, and years of curation in one go. Again. It was the third time.

I could have just picked another proprietary cloud gallery. Instead, I used it as an excuse to experiment with AI-assisted coding on a real, meaningful project. Not a todo app. Not a chatbot wrapper. Something I actually needed.

**The idea:** apply Lakehouse principles to personal photo management.
- Metadata lives *with* the data, in open XMP sidecars
- Storage and compute are fully decoupled — works on local drives, iCloud, OneDrive, without lock-in
- Hierarchical manifests for fast search, no central database to migrate or lose

The result is **OuEstCharlie** — and its core component, **Woof**.

**Woof** is a local MCP server that plugs into any MCP-compatible AI assistant — Claude Desktop, ChatGPT, Goose, and more — on macOS, Windows, or Linux. You talk to it in natural language, it indexes your photos, and serves a full gallery — grid view, carousel, full screen — directly inside the chat interface. No standalone app, no cloud sync required.

V1 is feature-complete: index your library, search by date, browse in a full gallery with grid and carousel views — all from your AI assistant of choice.

Now I want to stress-test it on MacOs, Windows and Linux using Claude Desktop, ChatGPT or Goose.

**Looking for beta testers** — if you are curious about running a local-first, AI-native gallery. Drop me a message or comment below and visit the Woof Github, link in the first comment.

*Beta disclaimer: Woof never touches your original files, but please back up your library before trying it.*


---

Happy to share thoughts on AI-assisted coding too — what worked, what didn't, and why I'll keep doing it.
