---
layout: post
title: "Create your personal photo gallery with Claude, Strava and OuEstCharlie Woof"
date: 2026-08-01
last_modified_at: 2026-08-01
image: /assets/screenshot_2026-04-11.jpg
categories: [DIY, MacOs, Linux, Windows]
---

Personal photo galleries are a great asset; they gather and keep many memories of our life. However, creating and managing one is also a challenge and consumes time. Digital photos have not changed much from the old paper photo albums: we must sort photos in albums or their digital equivalent (tags, smart albums), add captions, and name the people. We got accustomed to delegating this to packaged services like Google or Apple photo applications, but then [we get dependent on those: the metadata is created there and remains there](./2026-04-10-why-we-need-to-move-past-gallery-apps.md).

New AI tools and their integrations may change that. In the following tutorial, we show how to create, search and browse a photo library in Claude. Starting from a folder full of photos, use **Claude CoWork** to automatically sort photos into folders and add captions. This extra information comes from your **Strava activity log**. Eventually, the photos are indexed into **OuEstCharlie Woof** so that they are searched and browsed directly from Claude. Added information is co-located with photos; everything remains local to your machine.

# Getting the pictures in Claude CoWork

First import your photos from the camera or smartphone to a folder on your computer. As usual when using (AI) automation, **be sure to make a backup of this valuable asset**.

The Claude Desktop application is required. At the prompt footer, select the "CoWork" module. CoWork is a variant of the chat that is specialized in interacting with your information and files.

Below the prompt box, click on "Folder or project", select the folder in which the photos are, and allow Claude CoWork to edit those files.

# Sort and enrich the photos with Claude and Strava

Strava will supply the activity data used to auto-caption and organize your photos. Strava is added to Claude through a connector. Assuming you have a subscription with Strava, from the "Customize" section of the Claude settings, select the "Connectors" tab and search or add (depending on the Claude Desktop version) the Strava connector from the marketplace. You will need to log into Strava with your credentials.
 
You may now start the photo enrichment with the following prompt that you may adapt to your taste:

>I would like to sort the pictures in the project folders by date and also add a description.
>Most of the photos are from sport outings, you can use the Strava integration to get the corresponding outing of that day.
>I usually name the photo folder with ISO dates and PascalCase (each word capitalized, no spaces) for the goal of the day and, if available, the name of the persons with me.
>E.g.: 2025-06-12_MontBlanc_Paul
>Please validate the folder structure before moving any pictures. Ask if any information is missing.

The last two instructions are very important as there are probably incomplete outing descriptions in Strava, and many exceptions you want to handle carefully.

{% include post-image.html src="/assets/Claude+Strava+Woof/001_ClaudeFirstShow.png" alt="First shot from Claude using Strava activity stream to sort photos" %}

As instructed, Claude uses the Strava connector to fetch information from the activity stream, analyze this information relative to the photo dates, and ask for clarifications when needed.

The first question is about how to handle a day with two activities in Strava. This actually underlines a limit of the prompt: it only requires matching the activity with the photo day, but does not specify matching the time of the day as well.

As for the description enrichment, Claude asks if it should be in a separate text file within the folder or embedded in the photo's EXIF header. The Exif header is metadata within the photo files describing the camera settings, the time the picture is taken, the GPS location if available, and descriptions or tags. This is the primary source of information for all the photo gallery software, including OuEstCharlie.

Claude eventually highlights that some photos do not have a matching outing, and proposes to name the corresponding folder with the ISO date only.

As per instruction, a draft folder structure is created for review and validation.

{% include post-image.html src="/assets/Claude+Strava+Woof/002_draftFolderStructure.png" alt="Draft folder structure from Claude" %}

Claude is able to detect multi-day trips and asks for the corresponding name:

>Mar 28–31, 2025: a 4-day ski touring trip (Combeynot, Chamoissière, Pic de Neige Cordier, Col des Agneaux) with a rotating group of 7. What should I call this trip in the folder name?

When all clarifications are made, Claude generates the Python code for the folder creation, the photo file movement, and the EXIF header edition. If you know this language, you may review the intended modifications.

Following user validation, Claude executes the plan and provides a summary of the changes. You may check the folder structure, the description.txt files, and the photo assignments.

# Search and browse the photos in OuEstCharlie Woof

Now that photos are sorted in folders and contain context information, how are they accessed and explored? This is provided by the search and browse capabilities of a photo gallery. Search is selecting the best matching picture using metadata; it might combine several metadata fields and eventually sorts the results by relevance and the requested field. Browsing the gallery is essential for visual content like photos. It often comes as a grid following the query results, but it can also use other displays such as a geographic map. Claude does not provide those skills, or provides them poorly: search would probably mean a traversal of all the photos; browse is through the system preview app.

To overcome those limits of Claude, we have created a companion app, [OuEstCharlie Woof](https://github.com/ouestcharlie/ouestcharlie-woof). Woof is extending Claude by providing instant search on folder names and photo metadata (from headers). It also augments Claude's user interface with grid or single-photo display. The user experience stays consistent with Claude: chat with the AI; it translates your intent into queries to Woof, and displays the result.

Woof is installed as a local Claude connector via a small package bundle. Here are [the step-by-step install instructions](./2026-05-13-claude-how-to-step-by-step.md).

Once Woof is installed, the first step is the configuration of the gallery root folder:

>Can you create an OuEstCharlie Woof library for this folder?

Claude will probably suggest the next logical step: index the library. This step is necessary to gather the metadata, and prepare the thumbnails such that search and browse are fast and pleasant.

Once the progress bar of the indexing reaches 100%, you may start the gallery exploration.

# Wrap-up

With this tutorial, we have shown how to create a photo gallery from end to end in Claude Desktop CoWork. The gains are quite impressive compared to legacy systems:
- Photos are sorted and enriched with the Strava activity log for context. The AI not only matches the photos and activities but also finds missing information and inconsistencies. Scripting this process and all the exceptions would require quite complex rules.
- Search also benefits from the AI. Your requests are in natural language in the chat. The AI interprets and finds the best matching pictures using all available information fields.

OuEstCharlie Woof is the companion app extending Claude for photo search and browsing without breaking the user experience. Today, most photo gallery integrations with Claude only wrap actions like search or album creation; the photos are at best shared with Claude one by one.

