# Folio

Folio is a fork of [Open Scanner](https://github.com/pencilresearch/OpenScanner) by Pencil Research (MIT). It keeps Open Scanner's scanner, library, Core Data + CloudKit sync, search, Spotlight and Shortcuts, restyles every screen in the Fernlet design system, and adds a rebuild mode that turns a scanned page into an editable Word (.docx) or PowerPoint (.pptx) file — on the phone, with no server.

What the fork adds:

- **Capture** — Folio's own camera (AVFoundation + Vision) with live page outlining, auto-capture when steady, perspective correction, shadow removal and a whiteboard mode; imported photos get the same cleanup.
- **Searchable PDF** — page images with an invisible OCR text layer; notes become PDF annotations.
- **Rebuild** — Vision's document reader (iOS 26) plus layout heuristics build one intermediate document (`scanner/Rebuild/FolioDocument.swift`) that every exporter reads; Apple Intelligence re-ranks uncertain words on capable iPhones.
- **Review & fix** — uncertain words and arrows are flagged for one-tap fixes; bold/italic/underline, heading and notes edit the document before export.
- **Export** — Word, PowerPoint, searchable PDF and plain text, written by Folio's own OOXML writer.

Requires iOS 17 (rebuilding needs iOS 26). For a sample library in the Simulator, launch with `-seedSampleLibrary YES`; `-deviceTier smart|basic|pdf` previews each device tier.

The original Open Scanner README follows.

---

# Open Scanner

Open Scanner is a fast, free document scanning app for iPhone. You can [download it from the App Store](https://apps.apple.com/app/id6578414558).

## About the app

### What is Open Scanner?

Open Scanner scans your receipts, notes, textbooks, and anything else you point your iPhone at.

It saves your scans into its built-in library, and syncs them to all your devices.

Unlike other scanner apps, Open Scanner is free, and always will be: no ads, no in-app purchases, no subscriptions.

### Why should I trust Open Scanner?

Open Scanner is open source (MIT License). That means another app developer can take the source code and audit it, or republish it as their own app.

You can even run your own private version of Open Scanner on your iPhone, if you’re adventurous.

### What permissions does Open Scanner ask for?

Open Scanner will prompt you for the following permissions:

 - **Camera**: Required for scanning your documents.
 - **Location**: Optional. If you grant location permission, Open Scanner will annotate your scans with location data.

### What data does Open Scanner collect?

Please see [Open Scanner's privacy policy](https://openscanner.app/#privacy).

### Who made Open Scanner?

[Pencil Research](https://pencilresearch.com).

## About this project

This project's purpose is to provide iPhone users with a free (and ad-free), privacy-respecting, and auditable document scanning app.

Open Scanner is written in Swift and built with SwiftUI. It uses Core Data for data storage, and CloudKit for synchronization. It supports iOS 16.0+ and visionOS 1.2+.

Contributions to the project, either as issues or pull requests, are welcome.

The version numbers in [Releases](https://github.com/pencilresearch/OpenScanner/releases) correspond to the version numbers in Open Scanner's App Store listing.
