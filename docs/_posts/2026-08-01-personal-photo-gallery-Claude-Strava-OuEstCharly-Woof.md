---
layout: post
title: "Create you personal photo gallery with Claude, Strava and OuEstCharlie Woof"
date: 2026-08-01
last_modified_at: 2026-08-01
image: /assets/screenshot_2026-04-11.jpg
categories: [DIY, MacOs, Linux, Windows]
---

Personal photo galleries are a great assets, they gather many memories of our life. However, creating and managing one is also a challenge and consumes time. Digital photos have not changed much from the old paper photo albums: we must sort photos in albums of digital equivalent (tags, smart albums), add captions, name the people. We got accustomed to delegate this to packages services like Google Photo or Apple Photo, but then [we get dependent on those: the metadata is created there and remains there](./2026-04-10-why-we-need-to-move-past-gallery-apps.md).

New AI tools and their integrations may change that. In the following we show how to create, search and browse a photo library in Claude. Starting from a folder full of photo, use **Claude CoWork** to automatically sort photos into folders and add captions. This extra information is issued from your **Strava activity log**. Eventually, the photos are indexed into **OuEstCharlie Woof** such that they are searched and browsed directly from Claude.

# Getting the pictures in Claude CoWork

First import your photos from the camera or smart phone to a folder on your computer. As usual when using (AI) automation, **be sure to make a backup of this valuable asset**.

The Claude Desktop application is required. at the prompt footer, select the "CoWork" module. CoWork is a variant of the chat that is specialized at interacting with your information and files.

Below the prompt box, click on "Folder or project", select the folder in which the photos are, and allow Claude CoWork to edit those files.

# Connect to Strava

Assuming you have a subscription with Strava, from the "Customize" section of the Claude settings, select the "Connectors" tab and search or add (depending on the Claude Desktop version) the Strava connector from the market place. You will need to log into Strava providing your credentials.
 
 You may now start the photo enrichment with the following prompt that you may adapt to your taste:
>I would like to sort the pictures in the project folders by date and also add a description.
>Most of the photos are from sport outings, you can use the Strava integration to get the corresponding outing of that day.
>I usually name the photo folder with ISO dates and PascalCase for the goal of the day and, if available, the name of the persons with me.
>E.g.: 2025-06-12_MontBlanc_Paul
>Please validate the folder structure before moving any pictures. Ask if you miss information.

The last two instructions are very important as there are probably incomplete outing descriptions in Strava, and many exceptions you want to handle.

{% include post-image.html src="/assets/Claude+Strava+Woof/001_ClaudeFirstShow.png" alt="First shot from Claude using Strava activity stream to sort photos" %}

As instructed, Claude use the Strava connector to fetch information of the activity stream, analyze this information relatively to the photo dates, and ask for clarifications when needed.

The first question is about how to handle a day with two activities in Strava. This actually underlines a limit of the prompt: it requires to match the activity with the photo day, but does not tell to actually match also the full time of the day.

As for the description enrichment, Claude asks if it should be in a separate text file within the folder or embedded in the photo's EXIF header, let's ask for both. The photo EXIF header is used by OuEstCharlie Woof during indexing.

Claude eventually highlights that some photos do not have a matching outing, with the proposal to name the corresponding folder as the ISO date only. 

As per instruction, a draft folder structure is created for review and validation.

{% include post-image.html src="/assets/Claude+Strava+Woof/002_draftFolderStructure.png" alt="Draft folder structure from Claude" %}

Claude is able to detect multi-day trips and asks for the corresponding name:

>Mar 28–31, 2025: a 4-day ski touring trip (Combeynot, Chamoissière, Pic de Neige Cordier, Col des Agneaux) with a rotating group of 7. What should I call this trip in the folder name?

When all clarifications are made, Claude is generating the Python code for the folder creation, the photo file movement, and the EXIF header edition. If you have the knowledge of this language, you may review again the intended modifications.

Following user validation, Claude is operating the plan and provides a summary of the changes. You may check the folder structure, the description.txt files, and the photo assignments.

# Search and browse the photos in OuEstCharlie Woof

Now that photos are sorted in folders and contain context information, how are they accessed and explored? This is provided by the search and browse capabilities of a photo gallery. Claude does not provide those skills or only low performers: search would probably mean a traversal of all the photos, browse is through the system preview app.

To overcome those limits of Claude, we have created a companion app, [OuEstCharlie Woof](https://github.com/ouestcharlie/ouestcharlie-woof). Woof is extending Claude providing instant search on folder names and photo metadata (from headers), and a user interface within Claude for grid or single photo display. The user experience is the one of Claude: chat with AI, it will work out your intention into queries to Woof and display the result.

Install of Woof is through a small package bundle that is installed as a local connnector to Claude. Here are a the [step by step install instructions](./2026-05-13-claude-how-to-step-by-step.md).

Once Woof is installed, first step is the configuration of the gallery root folder:

> Can you create an OuEstCharlie Woof library for this folder ?

Claude will probably suggest the next logical step: index the library. This step is necessary to gather the metadata, and prepare the thumbnails such that search and browse are fast and pleasant.

Once the progress bar of the indexing reaches 100%, you may start the gallery exploration.

# Wrap-up

With this tutorial, we have shown how to create a photo gallery from end to end in Claude Desktop CoWork. The gains are quite impressive compared to legacy systems:
- Photo are sorted and enriched with the Strava activity log as source. The AI not only matches the photos and activities but also finds missing information and incoherencies. Scripting this process and all the exceptions would require quite complex rules.
- Search also benefits from the AI, your request are in natural language in the chat; the AI interprets and find the best matching pictures using all available information fields.

OuEstCharlie Woof is the companion app extending Claude for photo search and browsing without breaking the user experience. Today, most photo gallery integrations with Claude only wrap actions like search or album creation, the photos are at best shared with Claude one-by-one.

