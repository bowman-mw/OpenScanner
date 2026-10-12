# Folio vs free PDF software: is a full PDF editor worth building?

*October 2026. Free-tier facts were gathered from vendor pages and 2025–26 reviews (sources at the end). Free tiers change often; re-check before committing to a feature.*

## Bottom line

**Don't build PDF-XChange/Acrobat parity, and least of all on the Mac.**
- On the Mac the free tools already cover almost everything:
  - Preview handles viewing, markup, forms, signing and organizing.
  - PDFgear adds OCR, text editing, Word/PowerPoint conversion, redaction, watermarks, headers/footers and form creation, with no watermark and no account.
  - LibreOffice and Stirling-PDF add PDF/A, compare and batch.
- On iPhone and iPad the free tools stop at view, markup, fill, sign and scan. That is where Folio already stands out and where a few more features would still be rare.

**Recommendation:** keep Folio's lane: private, on-device scanning that rebuilds pages into real Word/PowerPoint documents, plus solid PDF handling. Then add only the handful of features that are cheap on top of what exists and rarely free on iPhone/iPad:
- verified redaction
- outline (bookmark) editing
- headers/footers and Bates numbering
- batch actions through Shortcuts

Ship the Mac as the same app (Catalyst), not as a desktop PDF editor.

## What Folio already has

| Area | Folio today |
|---|---|
| Camera scanning | ✓ edge detection, whiteboard mode (glare, marker colours), photos and PDF import |
| Searchable OCR you can export | ✓ on-device; searchable PDF export |
| Scan → Word / PowerPoint | ✓ structured: headings, lists, tables, equations (editable in Word), diagrams as shapes. **No free tool does this.** |
| PDF viewing, find, markup, form filling | ✓ PDFKit viewer, find bar, real annotations, AcroForm filling; XFA flagged |
| Organize pages | ✓ rotate, reorder, insert, delete, extract |
| Compare two PDFs | ✓ new: marked differences, change list, also scan vs PDF |
| PDF standards | ✓ opens PDF/A, X, E, VT, UA and R; PDF/A-2b export path investigated |
| Library | ✓ folders, tags, smart folders, search across every scanned word |
| iPad / Mac | ✓ iPad workspace; Mac via Catalyst (basic) |
| Apple Intelligence | ✓ double-checks uncertain words, refines equations |
| Signing | ✗ (out of scope by choice) |

## Feature by feature

Key: **Free on Mac** / **Free on iPhone/iPad** gives the best genuinely free option (no watermark, no paywall). **Effort** is a rough size for Folio, given what's already built.

| Feature | Folio | Free on Mac | Free on iPhone/iPad | Build it? |
|---|---|---|---|---|
| View, find, annotate, fill forms | ✓ | Preview, Acrobat Reader, PDFgear | Preview (iOS 26), Acrobat, PDFgear | Done |
| Organize, merge, split | ✓ organize · merge ✗ | Preview, PDFgear | Preview, PDFgear (paid in Acrobat, Foxit, Xodo, PDF Expert) | **Merge: yes**, S. Small, expected, still often paid on iOS |
| Searchable OCR export | ✓ | PDFgear, Stirling | Google Drive (in Drive only); Adobe Scan caps at 5 pages | Done, and a Folio strength |
| Convert to Word/PPT | ✓ (from scans, structured) | PDFgear (from PDFs) | Rarely free | Done for scans. **Text PDFs → Word: maybe later**, M, reusing the rebuilder |
| Compare | ✓ | LibreOffice/Stirling (clunky); paid in Acrobat | **None free** | Done, a differentiator on iPad |
| Redaction (real removal) | ✗ | PDFgear, LibreOffice, Stirling. Preview's has been shown to leave text recoverable | Paid everywhere checked | **Yes**, M. Must remove content, not cover it; verify with text extraction |
| Outline / bookmarks editing | ✗ | PDFgear, Stirling | Paid or missing | **Yes**, S. PDFKit outlines |
| Headers/footers, Bates numbering | ✗ | PDFgear (H/F); Bates rare | **None free** | **Yes**, S–M. Stamp text per page; niche (legal) but nearly free to build |
| Watermarks | ✗ | PDFgear, Automator | Rare | Maybe, S. Same code as headers/footers |
| Stamps | ✗ | Acrobat Reader, PDFgear | PDFgear, Foxit, PDF Expert | Maybe, S. Stamp annotations on the existing markup |
| Batch processing | ✗ | Automator/Shortcuts, Stirling, LibreOffice CLI | **None free** (Shortcuts only) | **Yes, through App Intents**, S–M. "OCR these", "Export as PDF/A" as Shortcuts actions |
| PDF/A export | partial | LibreOffice, Stirling | **None free** | **Finish it**, S–M. Quartz PDF/A-2b path exists; validate with veraPDF |
| AI summary / Q&A | ✗ | PDFgear (online) | PDFgear; others paid | **Maybe**, M. Apple Intelligence on-device makes it cheap and private |
| Edit existing text | ✗ | PDFgear (free), Stirling (paid) | Paid or missing | **No**, L. Hard to do well in PDFKit; PDFgear gives it away |
| Create form fields | ✗ | PDFgear, LibreOffice | Rare | **No**, L. Niche; designer UI is big |
| Measure tools | ✗ | Rare | Paid (PDF Expert) | **No**. Niche (architecture/engineering) |
| Signing | ✗ | Preview, Acrobat, PDFgear | Preview, Acrobat, PDFgear | **No** (excluded) |

## Why the Mac isn't the place to compete

- **PDF-XChange Editor** is still Windows-only, with no Mac version announced.
- **PDFgear for Mac** is free, unwatermarked and needs no account. It already covers the "pro" list.
- **Preview** covers the everyday list, and has been a standalone app on iPhone/iPad too since iOS/iPadOS 26.
- **Skim, LibreOffice and Stirling-PDF** are free (Skim and LibreOffice are open source) and cover the specialist bits: notes, PDF/A, compare, batch.

A Mac Folio earns its place with what's unique: the scan library synced from the iPhone, rebuilding scans into Word/PowerPoint, and compare. Desktop PDF-editor features add little there.

## Watch list

- **PDFgear:** the main free competitor. It adds features fast: redaction, OCR, certificate signing (2025) and eSign (2026). Its scanner is a separate paid app, and its iOS PDF app is thinner than its Mac app.
- **Microsoft Lens:** retired in Dec 2025. Its replacement (Scan in the Microsoft 365 Copilot app) dropped direct save to Word and OneNote, which leaves an opening for scan → Word.
- **Adobe Scan:** the free tier caps OCR at 5 pages and moved more features behind the paywall in 2026.

## Suggested order

1. **Merge PDFs** (S). The page organizer already does the hard part.
2. **Outline editing** (S).
3. **Finish PDF/A export** (S–M), validated with veraPDF.
4. **Verified redaction** (M). Headline feature; must pass a text-extraction check.
5. **Shortcuts actions** for batch OCR/export (S–M).
6. **Headers/footers and Bates numbering, watermarks** (S–M).
7. *Later, if wanted:* on-device AI summary/Q&A; text-PDF → Word through the rebuilder.

Skip: text editing, form design, measuring, signing.

## Sources

- PDF-XChange Editor (Windows only): https://www.pdf-xchange.com/product/pdf-xchange-editor
- PDFgear (Mac, iOS, what's new): https://www.pdfgear.com/ · https://pdfgear.com/pdfgear-for-mac/ · https://www.pdfgear.com/pdfgear-for-ios · https://www.pdfgear.com/whats-new
- Acrobat Reader free features: https://www.adobe.com/acrobat/pdf-reader.html
- Adobe Scan (App Store): https://apps.apple.com/us/app/adobe-scan-pdf-ocr-scanner/id1199564834
- Preview on iPhone/iPad (iOS 26): https://www.apple.com/newsroom/2025/06/ipados-26-introduces-powerful-new-features-that-push-ipad-even-further/
- Preview redaction test: https://eclecticlight.co/2020/12/11/how-effective-and-safe-is-previews-redaction-tool/
- Microsoft Lens retirement: https://support.microsoft.com/en-gb/topic/retirement-of-microsoft-lens-fc965de7-499d-4d38-aeae-f6e48271652d
- Xodo plans: https://xodo.com/blog/xodo-plans-explained · Foxit iOS: https://apps.apple.com/us/app/foxit-mobilepdf-pdf-reader/id507040546
- UPDF free vs paid: https://updf.com/comparison/updf-free-vs-paid/ · PDF Expert pricing: https://pdfexpert.com/pricing
- Stirling-PDF: https://github.com/Stirling-Tools/Stirling-PDF · Skim: https://skim-app.sourceforge.io/
- LibreOffice PDF/A export: https://help.libreoffice.org/7.2/en-US/text/shared/01/ref_pdf_export_general.html
