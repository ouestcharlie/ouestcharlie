# I Lost My Photo Library Again. So I Built an AI-Native One.

*Your photos and your AI tools have never talked to each other. Here's why that needs to change.*

I've lost my photo library three times.

Not the photos. The *meaning* I had layered on top of them.

The albums I spent evenings organizing. The face tags. The captions I wrote for my kids years from now. Every time I switched cloud providers, all of it was gone — silently, irreversibly, by design.

The last time it happened, I'd just migrated to Infomaniak. The photos came through fine. Everything else didn't. And I thought: I trusted a platform that was never designed for me to leave.

---

## The lock-in we all experienced

We talk a lot about data portability in the abstract. We talk less about what it actually feels like to open a freshly imported library and see 3,000 flat, unnamed photos where your carefully curated albums used to be.

Every major gallery app — Google Photos, Apple iPhoto, Amazon, OneDrive — has the same fundamental architecture: your enrichments live in *their* database, not with your photos. Albums, face groups, captions, ratings. It's all proprietary, invisible, and non-transferable.

This isn't an accident. Your own curation becomes the switching cost they impose on you. The more you invest in a platform, the harder it is to leave. That's the model.

---

## What actually needs to change

The fix isn't a better export button. It's a different starting assumption: **metadata should live with the data**.

There's already a standard for this: [XMP sidecars](https://en.wikipedia.org/wiki/Extensible_Metadata_Platform) (ISO 16684). Plain files, sitting next to your photos. Lightroom and Darktable read them. They'll be readable long after any particular app is gone.

This is the approach the data world figured out years ago with the Lakehouse pattern — open formats, decoupled storage and compute, metadata that survives the tools that created it. Nobody had applied it to personal photo management.

So I did. That became the **OuEstCharlie** framework with its **Woof** frontend agent and app.

---

## The AI angle that actually matters

Your AI assistant can help you plan a trip, analyze a document, write code. But ask it to show you photos from your 2023 vacation and it stares blankly. Photos live in one app; intelligence lives in another; the two never meet.

This is an architectural problem, not a technical one. Existing gallery apps were never designed to be integrated.

OuEstCharlie is built around the [Model Context Protocol (MCP)](https://modelcontextprotocol.io/) for the integration with the AI conversion, and MCP Apps for the user interface. The result: your photo library becomes something your AI assistant can actually query, browse, and reason over — through natural conversation, not manual file uploads.

The app isn't embedding AI. The app is *embedded in* the AI.

---

## Here comes OuEstCharlie

**Woof** is the front end of OuEstCharlie: a local MCP server you connect to any MCP-compatible AI assistant (Claude, ChatGPT, Goose…). It indexes your library, writes metadata to XMP sidecars (never touching your originals), and serves a full gallery — grid, carousel, full screen — inline in your conversation. Woof delegates core tasks to two specialized agents: Whitebeard to index the library, Wally to query the library and serve thumbnails and preview photos.

Everything runs locally. Your photos don't leave your machine.

V1 covers the basics: indexing, date search, thumbnail and preview generation, support for modern image formats. It runs on macOS, Windows, and Linux. Works with local drives and cloud-synced folders (iCloud, OneDrive, Google Drive, as long as files are local).

Building it with AI-assisted coding was its own experiment — and honestly, a more interesting one than I expected. That's a separate post.

---

## Try it, if you're curious

Woof is available as an early preview on GitHub. If you are curious about running a local-first, AI-native gallery and are ready to give a hand, I'd genuinely appreciate it.

[→ OuEstCharlie / Woof on GitHub](https://github.com/ouestcharlie/ouestcharlie-woof#readme)

*This is beta software. Woof never modifies your original photo files, but please make sure your library is backed up before trying it.*

And if you've had the same experience with photo library migrations — I'd like to hear about it.
