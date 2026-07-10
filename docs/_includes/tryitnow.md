## Try It Today

<p align="center"><img src="{{ "/assets/woof_large_850.png" | relative_url }}" alt="Woof" height="200"></p>

**[Woof](https://github.com/ouestcharlie/ouestcharlie-woof)** — the MCP app for OuEstCharlie — is available now as an early preview. Here is how to go from zero to browsing your library in three steps.

### Step 1 — Install Woof

The easiest path is a single double-click. Download the latest `ouestcharlie-woof.mcpb` from the [Releases page](https://github.com/ouestcharlie/ouestcharlie-woof/releases) and open it. Claude Desktop will prompt you to install Woof in one click — no configuration file to edit, no terminal required.

If you prefer a manual setup or use a different AI client (ChatGPT Desktop, Goose, VS Code Copilot), add Woof via `uvx`:

```json
{
  "mcpServers": {
    "woof": {
      "command": "uvx",
      "args": ["--python", "3.12", "--from", "ouestcharlie-woof", "woof"]
    }
  }
}
```

### Step 2 — Point Woof at your photos

Once Woof is connected, tell your AI assistant where your photos live:

> *"Add a local library to Woof pointing to /Users/your-name/Pictures"*

Then kick off indexing:

> *"Index my local library"*

Woof reads your library as-is — no migration, no reorganization. It writes XMP sidecar files next to your originals (never touching the originals themselves) and builds a fast metadata index. Expect roughly 10–100 seconds per thousand photos.

### Step 3 — Start searching

Once indexing is done, your library is fully accessible through natural conversation:

> *"Show me photos from last July"*

> *"Pictures taken near Paris"*

> *"How many photos do I have?"*

The gallery panel appears inline in your conversation with matching results. Your photos never leave your machine — only metadata and thumbnails travel to the AI assistant.

**V1 supports local filesystems on macOS, Linux, and Windows**, including folders synced from iCloud Drive, OneDrive, or Google Drive as long as files are locally available. Native cloud storage is on the roadmap for V2.

[Get Woof on GitHub](https://github.com/ouestcharlie/ouestcharlie-woof) — see the [README](https://github.com/ouestcharlie/ouestcharlie-woof#readme) for full install and usage details.

<p align="center"><img src="{{ "/assets/screenshot_2026-04-11.jpg" | relative_url }}" alt="Woof photo gallery in Claude Desktop" height="600"></p>

## It does not work

First check the [step by step install guide]({{ "/2026/05/13/claude-how-to-step-by-step/" | relative_url }}).

If your problem remains unsolved after going through this guide, please [file an issue on the Woof GitHub repository](https://github.com/ouestcharlie/ouestcharlie-woof/issues) — include the logs above and a description of what you tried.
