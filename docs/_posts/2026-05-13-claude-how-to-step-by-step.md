---
layout: post
title: "Step by Step install of OuEstCharlie Woof in Claude Desktop"
date: 2026-05-13
categories: [howto]
---

[Woof](https://github.com/ouestcharlie/ouestcharlie-woof/) is the frontend to OuEstCharlie, a modern photo gallery integrated into Claude Desktop (and other AI assistants). Woof is an MCP app: it acts both as a connector between your photo library and Claude, and as a user interface for browsing photos. Metadata flows through Claude while gallery and photo files remain local to your machine.

## Security

Woof is a local MCP server connected to Claude via the STDIO protocol. This means:
- Claude launches and stops Woof
- No specific authentication is required, since both application processes are coupled

Woof uses Python for the server, JavaScript for the gallery frontend, and Rust for image processing. Security of the code and dependencies is continuously checked by GitHub. You can check the current status on the [security page of Woof](https://github.com/ouestcharlie/ouestcharlie-woof/security/dependabot).

## Pre-requisites

You need to [install Claude Desktop on your machine](https://support.claude.com/en/articles/10065433-install-claude-desktop). OuEstCharlie Woof is not compatible with the web version of Claude.

Woof is installed by the [uv](https://docs.astral.sh/uv/) Python package manager, which is normally bundled with Claude Desktop. If you run into issues, see the Troubleshooting section below.

## Install Woof in Claude

The simplest way to install Woof is through the MCP bundle included in the [Woof releases](https://github.com/ouestcharlie/ouestcharlie-woof/releases): download the latest `ouestcharlie-woof-x.y.z.mcpb` file.

Double-click the downloaded MCP bundle — Claude should open it and display the following dialog:

<p align="center"><img src="{{ "/assets/ClaudeHowTo/001.png" | relative_url }}" alt="Open the Woof MCP bundle in Claude Desktop" height="600"></p>

If Claude is not launched by the double-click, see the section "Alternate bundle install from the Claude settings" below.

Review the dialog and confirm the install by clicking **Install**.

A second confirmation step is required:

<p align="center"><img src="{{ "/assets/ClaudeHowTo/002.png" | relative_url }}" alt="Validate Woof install in Claude Desktop" max-height="600"></p>

Once successful, the Woof extension appears as enabled:

<p align="center"><img src="{{ "/assets/ClaudeHowTo/003.png" | relative_url }}" alt="Woof extension is enabled in Claude Desktop" max-height="600"></p>

## First steps in Claude Desktop

You can verify that Woof is correctly installed by asking Claude: "Is OuEstCharlie Woof loaded?" Claude may ask you to authorize listing libraries — see below for details.

<p align="center"><img src="{{ "/assets/ClaudeHowTo/010.png" | relative_url }}" alt="Check if Woof is loaded in Claude Desktop" max-height="600"></p>

Before searching and browsing photos, you need to point Woof to your photo library. This is done by creating a **library**, which consists of a nickname and the path to your photo library on your local drive.

<p align="center"><img src="{{ "/assets/ClaudeHowTo/011.png" | relative_url }}" alt="Define a Woof library in Claude Desktop" max-height="600"></p>

Supported drive types are:
- *filesystem*: any local or local-area network drive
- *cloud_mounted*: cloud drives such as iCloud, Google Drive, OneDrive, or kDrive

> Cloud-mounted drives may cause issues if photo files are "dehydrated" (i.e. their content is not immediately available locally). The workaround is to download the files before indexing the library.

Creating a library will require your confirmation.

> It is recommended to allow only once for commands that modify your drive — such as *create library* and *index library*. For read-only commands like *list libraries*, *list search fields*, *search*, or *browse*, you can allow permanently.

<p align="center"><img src="{{ "/assets/ClaudeHowTo/012.png" | relative_url }}" alt="Allow creation of a Woof library in Claude Desktop" max-height="600"></p>

Once the library has been added, the next step is to index its contents. Indexing extracts metadata (date, GPS location, dimensions, tags, etc.) and generates optimized thumbnails. Depending on library size, drive throughput, and machine performance, this may take several minutes. Typical indexing speed is 500–1,500 photos/min.

<p align="center"><img src="{{ "/assets/ClaudeHowTo/013.png" | relative_url }}" alt="Trigger library index in Claude Desktop" max-height="600"></p>

On macOS, an additional permission prompt may appear:

<p align="center"><img src="{{ "/assets/ClaudeHowTo/014.png" | relative_url }}" alt="Allow Woof to access document files in Claude Desktop" max-height="600"></p>

Durign the indexing, a progress bar is shown as well as details of the last indexed partitions. When indexing is complete, the UI displays a summary of the library and the indexing results:

<p align="center"><img src="{{ "/assets/ClaudeHowTo/015b.png" | relative_url }}" alt="Indexing summary in Claude Desktop" max-height="600"></p>

Claude and Woof are ready to start photo search and browsing.

## First search

You can now search and browse your library using Claude's prompt for queries, and the Woof UI to explore results — either inline in the chat or in full-screen:

<p align="center"><img src="{{ "/assets/ClaudeHowTo/016.png" | relative_url }}" alt="Search and Browse using Woof in Claude Desktop" max-height="600"></p>

---

## Alternate bundle install from the Claude settings

If double-clicking the `ouestcharlie-woof-x.y.z.mcpb` file does not open Claude, you can install it directly from the Claude Desktop settings by clicking the **Extensions** tab:

<p align="center"><img src="{{ "/assets/ClaudeHowTo/021.png" | relative_url }}" alt="Select Extension in Claude Desktop Settings" max-height="600"></p>

Enable **Advanced Settings**, then click **Install Extension**. In the file browser dialog, select the `ouestcharlie-woof-x.y.z.mcpb` file and follow the install steps described above.

<p align="center"><img src="{{ "/assets/ClaudeHowTo/022.png" | relative_url }}" alt="Install Extension in Claude Desktop Settings" max-height="600"></p>

## Troubleshooting

If Claude is unable to use the Woof MCP tools, inspect the logs. From **Settings → Developer**, select the Woof logs. A successful install should produce output similar to this screenshot:

<p align="center"><img src="{{ "/assets/ClaudeHowTo/031.png" | relative_url }}" alt="Woof install logs in Claude Desktop" max-height="600"></p>
