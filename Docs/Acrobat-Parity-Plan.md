# Matching Acrobat: what Folio needs, what's built, what's next

*Investigation and first build, 2026-10-11. Branch `pdf-documents` (from `folio` @6a41421). Five research passes (export formats; Dropbox, Google Drive and OneDrive; iPhone, iPad, Mac and iPhone Duo; accessibility checks; Okular, MuPDF, LibreOffice Draw and Scribus) plus prototypes run on this Mac and in the iOS 26.5 simulator. Signing is out of scope by request.*

**Summary.**
- Folio's largest gap was that it turned every imported PDF into photos. This branch keeps PDFs as PDFs.
- Opened PDFs now get:
  - a viewer with find, and a two-page book spread on wide screens
  - markup saved as standard, editable PDF annotations
  - form filling
  - a page organizer
  - detection of PDF/A, /X, /E, /VT, /UA, /R and XFA, with honest saves
- Of the eight requested areas, four are built (1–4). The other four (5–8) have a plan below.
- Everything stays on the device with zero new dependencies.

## The eight areas at a glance

| # | Area | Status | Next step | Effort |
|---|---|---|---|---|
| 1 | Open and view PDFs | **Built** | — | — |
| 2 | Find within a document | **Built** | Annotation review panel (Okular) | S |
| 3 | Organize pages | **Built** | Drag reorder on iPad with multi-select; split into files | S |
| 4 | Markup | **Built** | Select and move existing marks; Apple Pencil draws, finger scrolls | S–M |
| 5 | Export formats | Planned | Images + Markdown, then Excel, HTML, RTF | ~10 days |
| 6 | Dropbox, Drive, OneDrive | Partly there | Files-app route: Save to…, saved folders, open in place | 1–2 weeks |
| 7 | iPhone, iPad, Mac, iPhone Duo | Viewer ready (book spread) | Universal target, split layout, Catalyst | 5–7 weeks |
| 8 | Accessibility checks | Prototype passes | Check document sheet + tagged exports | 10–14 days |

## What this branch builds

All the new code is in `scanner/Documents/` (10 files), with 18 tests in `scannerTests/PDFDocumentsTests.swift`. The full suite runs 85 of 85 green.

**Storage (`PDFLibrary`).** Each imported PDF is copied into `Application Support/PDFs/<id>/`:

| File | What it is |
|---|---|
| `original.pdf` | The file as imported; never changed |
| `edited.pdf` | Folio's saves; written next to the old copy, then swapped in |
| `info.json` | Title, dates, favourite, page count |
| `text.txt` | The PDF's text, for library search |

The source file in Files, Dropbox, Drive or OneDrive is read through a file coordinator and left untouched. "Revert to original" deletes `edited.pdf`.

**Library.** A "PDF Files" row in the Library opens every PDF, newest first, as cards showing the first pages, with favourite and delete. Library search lists matching PDFs below matching scans, and opening a match starts find with that word. "Open a PDF" (on the Scan button and in PDF Files) replaces the old import that turned pages into photos. "Rebuild into Word or Slides" in the More menu makes a scan copy through PR #1's `PDFImport` and keeps the PDF as that scan's original. PDFs live as files, not in the scan store, so they don't go in folders, tags or smart folders yet.

**Viewer (`PDFDocumentView`, `PDFKitView`).**
- **Basics:** scroll, zoom, select and copy text, follow links, fill form fields, and a page indicator.
- **Book spread:** when the window is wide and landscape-shaped (iPad landscape, the unfolded iPhone Duo, Mac), pages sit side by side like a book. The first page sits alone as a cover by default, and that can be turned off. Checked on an iPad mini simulator.
- **Find bar:** "3 of 24", previous and next, and searching as you type. It runs PDFKit's background search, so long PDF/VT runs don't block the screen.
- **Why not the system find bar:** PDFKit's built-in one never appeared in testing.

**Markup (`PDFEditSession`, `PDFMarkupFactory`).**
- **Tools:**
  - Highlight, underline or strike out by dragging across text
  - Pen and highlighter
  - Line, arrow, rectangle and circle
  - Text box and sticky note, placed with a tap
  - Eraser, which never removes links or form fields
- **Saved as standard annotations,** so marks stay editable in Acrobat, Preview and other readers.
- **One finger draws, two fingers scroll.** Undo and redo cover marks and page edits.
- **Colours** match the annotate branch's palette.
- **Tested in code:**
  - Ink paths, line endpoints and highlight corner points are measured from each annotation's own corner, not the page's.
  - Highlighter transparency is saved.
  - Strokes start where the finger touched down, not where the drag was recognised.

**Organizer (`PDFPageOrganizer`).** Tap a page to jump to it, or drag one to reorder. Chosen pages can be rotated, deleted (a PDF always keeps at least one page) or saved as a new PDF. You can insert a blank page, photos, or another PDF's pages, which is how two PDFs are merged.

**Formats (`PDFFormatInspector`, `PDFClaimStripper`).**

| Kind | Opens | Edits | What the user sees |
|---|---|---|---|
| PDF/A | Yes | Yes | Badge, plus a banner: "Your changes go to Folio's copy, which won't claim that" |
| PDF/X, PDF/E, PDF/VT | Yes | Yes | Badge. 3D models aren't shown (banner); layers show in their default state |
| PDF/UA | Yes | Yes | Badge and a "Tagged" chip. Tags survive saves (tested) |
| PDF/R | Yes | Yes | Badge |
| Hybrid XFA | Yes | Yes | Fields fill normally; saving drops the XFA part, giving a standard fillable PDF (checked in the simulator) |
| Static-only XFA | Yes | Read | Banner: fields fill only in Adobe's apps |
| Dynamic XFA | Placeholder only | No | Banner explains; editing is off |
| Password-protected | After unlock | If the owner allows | Password card. The password is kept on save. Owner restrictions are respected. |

**Why the label-remover exists.** PDFKit's save keeps the "I conform to PDF/A" metadata but drops the colour profile (output intent) that PDF/A and PDF/X require. An edited copy would therefore claim a standard it no longer meets. `PDFClaimStripper` appends an incremental update that removes those labels from the metadata (and from the Info dictionary for PDF/X-1a and X-3). Everything else is left alone. It was checked end to end in the simulator: the original still claims PDF/A-2b with its colour profile, and the edited copy claims nothing.

**Known limits.**
- **Not drawn into the file:** PDFKit doesn't write appearance streams for these annotations. Acrobat, Preview and Chrome draw them anyway; very old viewers might not.
- **Editing existing page content:** changing the text and pictures already on a page (Acrobat's "Edit PDF") isn't possible with PDFKit.
- **Not synced:** these PDFs live on this device only (see area 7).
- **Original file not touched:** the picked file is copied, not edited in place (see area 6).
- **Simulator only:** checked on simulators; the full flow hasn't been run on a physical iPhone yet.

## 5. Export formats

Acrobat exports to 18 formats on desktop. On iOS it offers DOCX, DOC, RTF, XLSX, PPTX and images. All of Acrobat's mobile and web exports run on Adobe's servers. Folio has DOCX, PPTX, searchable PDF and TXT, all made on the phone.

| Format | How | Effort |
|---|---|---|
| Page images (JPEG/PNG/HEIC, multi-page TIFF) | ImageIO from the page images, or from PDFKit drawing for real PDFs | S, ~1 day |
| Markdown file | `MarkdownRenderer` already exists (`TextRenderers.swift`) but has no UI | XS |
| Excel (.xlsx) | SpreadsheetML written with the existing `ZipArchive`, using IR tables and `FolioTableGrid` for merged cells. One sheet per table, per page or for the whole document. Pages without tables put one row per paragraph | M, 3–4 days |
| HTML | Folio's own renderer. iOS has no `NSTextTable`, so NSAttributedString's HTML output loses tables. Tables use rowspan/colspan, figures go in as data URIs, diagrams as SVG, equations as MathML | M, 2–3 days |
| RTF | Folio's own writer: `\trowd` tables, `\pict` images, `\annotation` notes. Also covers Acrobat's `.doc` need | M, 2–3 days |
| Skip | `.doc` binary; PostScript and EPS (no writer on iOS) | — |

- **Real PDFs:** build one PDF → `PageSnapshot` adapter. It takes each line's text and bounds from PDFKit selections, bold and italic from `attributedString`, and runs OCR only on pages without text. Every renderer then works from it. That's 5–8 days.
- **Correction:** the export research said iOS can't write PDF/A. In fact Core Graphics' `kCGPDFContextCreatePDFA` produces PDF/A-2b (tested), but it can't be combined with a password or with the PDFKit notes pass.

## 6. Dropbox, Google Drive, OneDrive

- **What Acrobat does:** it signs in to each provider inside the app. Edits save back to the same file, and other services go through the iOS document picker.
- **What Folio already has:** the picker this branch uses already reaches all three providers through their Files extensions. Import reads through a file coordinator, so cloud files download first.
- **Recommendation: stay on the Files route.** It needs no SDKs, no network code and no change to the privacy label.

| Phase | Work | Effort |
|---|---|---|
| 0 | Device test of the three providers: write-back, folder picking, bookmarks surviving a relaunch, offline. Folder picking for Google Drive and OneDrive was historically blocked | 1–2 days |
| 1 | "Save to…" in Export; saved Locations (folder bookmarks, per device); "auto-save new scans to this folder" | 3–5 days |
| 2 | Open in place: recents with bookmarks, a `UIDocument`-backed editor with coordinated saves and `NSFileVersion` conflicts, "Open in Folio" document types | 5–8 days |
| 4 (only if needed) | In-app connectors (OAuth + REST, `drive.file` scope only) for gaps the device test proves | 2–3 weeks per provider |

**Gotchas.**
- A Google Drive "Save As" URL is temporary: writes to it succeed but never sync, so never bookmark it.
- Bookmarks only work on the device that made them, so keep them out of the iCloud-synced store.

## 7. iPhone, iPad, Mac and iPhone Duo

**Duo facts.** Announced 2026-09-09, on sale October 23:
- 7.6″ inner display, regular × regular
- 5.4″ outer display, compact width
- SwiftUI `onHingeChange` (iOS 27.1) is meant for effects, not layout

Duo testing needs Xcode 27.1, which is at RC; this Mac has 26.5.

**Decision.** The unfolded Duo uses the iPad layout, and that is driven by size class and width, never by device type.

**One adaptive layout.** Folio's custom route stack can host it without a rewrite:
- **Layout:** in ContentView, on regular width, put a library sidebar next to the detail stack.
- **Selection:** add `router.select(...)`, which replaces the detail root instead of pushing.
- **Keep in-progress work alive:** the camera and the rebuild screen must sit outside the layout switch, so folding the phone mid-scan doesn't lose pages.
- **Why not `NavigationSplitView`:** in compact width it falls back to sliding pushes, which breaks Folio's dissolve-only motion rule.

**Book feel.** The PDF viewer already does it. Scanned pages and Review should follow, pairing book-spread halves left and right. On the Duo, centre the spread on the fold's reserved region so the gutter sits on the hinge.

| Phase | Work | Effort |
|---|---|---|
| P0 | Install Xcode 27.1; baseline on the Duo and iPad simulators | 1 day |
| P1 | Universal target; multiwindow; camera rotation coordinator and interruption handling; remove fixed widths (`ReviewView.swift:161`, `RebuiltDocumentView.swift:607`); anchor the share popover; per-window routing | 4–6 days |
| P2 | Regular-width shell; Review side by side; scan book spreads; keyboard shortcuts, pointer, drag and drop | 7–10 days |
| P3 | Duo specifics: spine alignment, fold transitions mid-scan, mid-read and mid-sheet, ExportSheet height, screenshots (required from April 2027) | 3–5 days |
| P4 | Sync: iCloud Drive app container for these PDFs (plus originals and figures), download states | 6–9 days |
| P5 | Mac Catalyst: Continuity Camera, menus and commands, window sizes | 5–8 days |

## 8. Accessibility checks

- **What Acrobat has:** Acrobat Pro's Full Check runs 32 rules (Document 8, Page Content 9, Forms 2, Alternate Text 5, Tables 5, Lists 2, Headings 1). It isn't in Acrobat on iPhone or iPad.
- **What Folio can check:** about 28 of the 32 automatically with Core Graphics alone: catalog flags, a walk of the structure tree, marked content against page content via `CGPDFScanner`, fonts, and form tooltips. The rest stay manual: reading order, colour contrast, and some media rules.
- **Prototype:** `Tools/AccessibilityCheckPrototype/` (`a11ycheck.swift`). A tagged version of Folio's own searchable PDF plus a small fix-up pass scored **0 fails**.

**MVP (10–14 days).**
- **"Check document" sheet:**
  - grouped like Acrobat, each rule marked pass, fail, manual or not applicable
  - Explain, Fix and Show page on each rule
  - "Fix safe issues" for title, language, show-title, tab order, bookmarks, and OCR for picture-only pages
- **Tagged exports:** `SearchablePDF` writes tags from the IR in reading order, with alt text for figures and equations as Formula. A fix-up pass then adds language and rebuilds the parent tree (Quartz leaves both out).

**Later (L).** Editing alt text and tags in other people's PDFs needs Folio's own object-level PDF writer, because PDFKit can't edit the structure tree.

**Never claim PDF/UA compliance.** Report what passed.

## Okular, MuPDF, LibreOffice Draw, Scribus

- **Licences:**
  - Okular (with Poppler) and Scribus are GPL; MuPDF is AGPL-3 or paid.
  - None can ship inside a closed App Store app.
  - LibreOffice's MPL-2.0 would allow single files, but its code can't practically be lifted out.
- **Verdict:** borrow ideas, not code, as with the earlier OSS review.

**Worth borrowing, in order.**
1. **Scribus-style preflight list:** the "Check document" sheet in area 8. (M)
2. **True redaction, MuPDF-style:** for scans, burn the boxes into the image and drop the OCR words under them. Other PDFs are redrawn as images with a warning. A black box over text is not redaction. (M)
3. **Tagged / PDF/UA export, as LibreOffice does,** from Folio's IR. (L)
4. **Okular's annotation review panel:** marks grouped by page and type, searchable, tap to jump. (S)
5. **Okular's "copy as table":** run Vision's document reader on a region and copy as TSV or HTML. It also feeds Excel export. (M)
6. **LibreOffice's "hybrid PDF":** embed Folio's IR so a Folio PDF reopens fully editable in Folio. (M)
7. **mutool's flatten and compress on export:** PDFKit's burn-in, JPEG and screen-optimise write options. (S)
8. **Okular's reading comfort:** trim margins and read aloud with word highlighting. Folio already has `AVSpeechSynthesizer`. (S)

**Skip.** Any of their code; EPUB, XPS and CBZ; print-shop colour tools. None of the four helps with XFA.

## XFA, the remaining piece

- **Done here:** hybrid forms convert on save, and dynamic forms are detected and explained.
- **Still open:** converting dynamic XFA would mean drawing it with Mozilla's pdf.js (Apache-2.0) in a hidden web view, then printing to PDF.
- **Next step:** a short trial on real government forms, before deciding whether to add pdf.js, which would be Folio's first third-party dependency.

## Merging this branch

- **Order:** stacked on `folio-rebuild-quality` (the OSS-features session's branch). That one merges into `folio` first, then this one. Agreed with that session on 2026-10-11.
- **Shared files changed here:**
  - `HomeView.swift`: "Open a PDF" opens as a PDF; search lists PDFs; `PDFImport.pages` takes an optional password
  - `Library/LibraryHomeView.swift`: the "PDF Files" row
  - `FolioRouter.swift` and `ContentView.swift`: `.pdf` and `.pdfFiles` routes
  - `ScanStartPicker.swift`: labels
  - `project.pbxproj`: the `Documents` group
- **Data model:** none touched.
- **Storage:** these PDFs live in `Application Support/PDFs/`, outside `Originals/`, so the originals pruning never touches them.
- **Palette:** markup on PDFs uses Annotate's `MarkPalette`, so marks look alike on scans and PDFs.
