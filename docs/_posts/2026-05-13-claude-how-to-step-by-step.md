---
layout: post
title: "Step by Step install of OuEstCharlie Woof in Claude Desktop"
date: 2026-05-13
categories: [howto]
---

[Woof](https://github.com/ouestcharlie/ouestcharlie-woof/) is the frontend to OuEstCharlie, a modern photo gallery integrated into Claude Desktop (and other AI assistants). Woof is an MCP app, meaning it is at the same time a connector between your photo library and Claude, and a user interface to browse the photos. Metadata flows through Claude, the gallery and photo files remain local to your machine.

## Security

Woof is a local MCP server connected to Claude through the STDIO protocol. This means that:
- Claude launches and stops Woof
- There is no need for specific authentication since both application processes are coupled

Woof involves Python for the servers, Javascript for the gallery frontend, and rust for the image processing. Security of the code and dependencies is continuously checked by Github. You may check the current status on the [security page of Woof](https://github.com/ouestcharlie/ouestcharlie-woof/security/dependabot)

## Pre-requisites

You need to [install Claude Desktop on your machine](https://support.claude.com/en/articles/10065433-install-claude-desktop). OuEstCharlie Woof is not compatible with the Web version of Claude.

Install of the Woof code is handled by the [uv](https://docs.astral.sh/uv/) Python package manager which is normally delivered with Claude Desktop. In case of issues, see the trouble-shooting section here below.

## Install Woof in Claude

The simplest way to install Woof is through the MCP bundle delivered as part of the [Woof releases](https://github.com/ouestcharlie/ouestcharlie-woof/releases): download the latest version of ouestcharlie-woof-x.y.z.mcpb

You may then double click on this download MCP bundle file, it should be opened in Claude and display the following dialog:

<p align="center"><img src="{{ "/assets/ClaudeHowTo/001.png" | relative_url }}" alt="Open the Woof MCP bundle in Claude Desktop" height="600"></p>

If Claude is not triggered by the double click, have a look at the section "Alternate bundle install from the Claude settings"

Review the dialog content and validate the install through the "Install" button.

A second validation is necessary:

<p align="center"><img src="{{ "/assets/ClaudeHowTo/002.png" | relative_url }}" alt="Validate Woof install in Claude Desktop" max-height="600"></p>

When successful, the Claude extension of Woof is shown as enabled:

<p align="center"><img src="{{ "/assets/ClaudeHowTo/003.png" | relative_url }}" alt="Woof extension is enabled in Claude Desktop" max-height="600"></p>

## First step in Claude Desktop

You may first check in Claude if Woof is correctly installed, using a prompt like: "Is OuEstCharlie Woof loaded". Claude might ask you if you want and authorize to list backends, see below for explanations.

<p align="center"><img src="{{ "/assets/ClaudeHowTo/010.png" | relative_url }}" alt="Check if Woof is loaded in Claude Desktop" max-height="600"></p>


Before searching and browsing photos, you first need to define a configuration to your local library. This is performed through the creation of a "backend" which consists in a nickname and the path to your photo library on your local drive.

<p align="center"><img src="{{ "/assets/ClaudeHowTo/011.png" | relative_url }}" alt="Define a Woof backend in Claude Desktop" max-height="600"></p>

Supported drive types are: 
- *filesystem*: any local or local area drive,
- *cloud_mounted*: for drives like iCloud, Google Drive, Onedrive, kDrive. 

> There might be issues with cloud mounted drives if photo files are "dehydrated", that is the content is not directly available on the PC. The workaround is to download the files before indexing the library.

Confirmation will be required to create backends. 

> It is advised to only allow once for the commands that modify your drive: create a backend, index a backend. For other commands like *list backends*, *list search fields*, *search* or *browse* you may allow permanently

<p align="center"><img src="{{ "/assets/ClaudeHowTo/012.png" | relative_url }}" alt="Allow creation of a Woof backend in Claude Desktop" max-height="600"></p>


Once the library has been added, the next step is to index the content. The index will not only list the metadata (date of the picture, GPS location, dimensions, tags...) but also create optimized thumbnails of the pictures. This operation may take several minutes depending on the library size, the drive throughput and the machine compute. Indexing speed is between 500 and 1500 photo/min.

<p align="center"><img src="{{ "/assets/ClaudeHowTo/013.png" | relative_url }}" alt="Trigger library index in Claude Desktop" max-height="600"></p>

Validation might be required on MacOs:

<p align="center"><img src="{{ "/assets/ClaudeHowTo/014.png" | relative_url }}" alt="Allow Woof to access document files in Claude Desktop" max-height="600"></p>

When completed, Claude will get a summary of the library and indexing operations:

<p align="center"><img src="{{ "/assets/ClaudeHowTo/015.png" | relative_url }}" alt="Allow Woof to access document files in Claude Desktop" max-height="600"></p>

## First search

You may then search and browse your library using the Claude prompt for the search, and the Woof UI to browse results within the chat or in full screen:

<p align="center"><img src="{{ "/assets/ClaudeHowTo/016.png" | relative_url }}" alt="Search and Browse using Woof in Claude Desktop" max-height="600"></p>

---

## Alternate bundle install from the Claude settings

When the MCP bundle (ouestcharlie-woof-x.y.z.mcpb) file is not recognized when double-clicked, the install might be done from the Claude Desktop settings, clicking on the "Extensions" tab:

<p align="center"><img src="{{ "/assets/ClaudeHowTo/021.png" | relative_url }}" alt="Select Extension in Claude Desktop Settings" max-height="600"></p>

Then enable the "Advanced Settings", and click on "Install Extension". Within the file browser dialog, select the ouestcharlie-woof-x.y.z.mcpb file and proceed to the install as explained here above.

<p align="center"><img src="{{ "/assets/ClaudeHowTo/022.png" | relative_url }}" alt="Install Extension in Claude Desktop Settings" max-height="600"></p>

## Trouble Shooting

If Claude is not able to use the Woof MCP tools, you may inspect the logs. From the Settings, "Developer" tab, select the logs of Woof. The install of Woof should output something similar to this screenshot:

<p align="center"><img src="{{ "/assets/ClaudeHowTo/031.png" | relative_url }}" alt="Woof insall logs in Claude Desktop" max-height="600"></p>

