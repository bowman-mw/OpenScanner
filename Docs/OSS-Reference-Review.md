# What Rescriva can take from OSS Document Scanner, Leptonica and Tesseract

*Code review, 2026-10-11. Sources read at: OSS Document Scanner `83fd6db` (github.com/Akylas/OSS-DocumentScanner, now ossappscollective; MIT), Leptonica `8ad618f` (BSD-2-style), Tesseract `b254445` (Apache-2.0). Rescriva read at the working tree on the same date. "(est.)" marks a starting value to tune, not a measured one.*

**Recommendation.** Take ideas and small algorithms, not code or libraries. Almost everything worth having is short enough to write in Swift on Core Image and Accelerate, which keeps Rescriva at zero dependencies. The one exception worth a dependency is Leptonica's page dewarp, and only if a harness test on real book photos shows it working. Tesseract is not worth bundling for bold, italic or underline: its modern engine reports none of them.

The most valuable things to adopt, in order:

1. **A non-destructive page record from OSS** (keep the original photo, store the quad and cleanup mode, re-crop any time) plus a corner editor. Rescriva keeps only the cleaned 2400 px JPEG, so a bad crop can't be fixed and figure crops can't come from the full-resolution original that the plan calls for.
2. **Palette and background sampling** (OSS's k-means palette). `RescrivaPage.background` and `palette` already drive the PPTX theme and slide fill, but nothing fills them.
3. **Figure regions** (Leptonica's halftone mask, simplified). Photos and charts currently vanish from Word and PowerPoint exports.
4. **Conservative bold, italic and underline** from Leptonica's stroke-width and slant ideas, built to abstain whenever unsure (see the style section).
5. **A stroke-scaled "ink" filter for whiteboards** (OSS's whitepaper filter) and a true black-and-white look (Leptonica's Sauvola).

## What Rescriva has today, for comparison

| Area | Rescriva now | Gap the sources can fill |
|---|---|---|
| Page record | Cleaned JPEG only: quality 0.75, ≤ 2400 px (`DataExtensions.swift:218-222`) | No original, quad or mode kept; no re-crop, re-clean or rotate |
| Crop | Vision segmentation, rectangles fallback, 1% inset (`CaptureCamera.swift:681-724`) | No corner editor |
| Cleanup | Illumination division plus glare subtraction (`PageCleanup.swift:347-417`) | No binarization; whiteboard mode never runs on imports |
| Looks | Color / Gray / B&W / Original; B&W is a contrast boost (`SearchablePDF.swift:108-132`) | No true B&W |
| Rebuild colors | IR fields exist; PPTX uses them (`PPTXRenderer.swift:28,252`) | Never sampled |
| Figures | `.figure` case and both renderers ready | Nothing creates figure blocks or assets |
| Styles | `RescrivaRun` has B/I/U; only manual toggles set them | No detection |
| Reading order | Blocks sorted by (y, x) | No column handling |
| PDF export | One toggle (notes) | No page size, quality, password or B&W option |
| PDF text layer | Drawn from raw OCR lines (`SearchablePDF.swift:41`) | Review fixes never reach the PDF |

## OSS Document Scanner

The app is NativeScript + Svelte over a C++/OpenCV core. Its image code is small: about 1,700 lines in `cpp/src`.

### Worth adopting

**Non-destructive pages** (`app/models/OCRDocument.ts`)
- Each page stores `sourceImagePath` (the original, kept by default), the `crop` quad, a `transforms` string and display-time `rotation`, `colorMatrix`, `brightness` and `contrast`.
- Re-crop and transform changes re-run from the original. Rotation and filters never touch pixels.
- "Delete originals" frees space per page or for everything, with a storage view showing processed vs original sizes. After that, the crop button and transform options are hidden.
- **For Rescriva:** add an original image, the quad, the capture mode (document or whiteboard), the rotation and the look to `Capture`, and rebuild the cleaned page from them.
  - Decide whether originals sync through CloudKit. They roughly double storage (est.). Keeping them local-only is the cheap option.
  - The rebuild should crop figures from the original, not the 2400 px JPEG.

**Crop editor** (`app/components/common/CropView.svelte`, `CropView.kt`)
- A touch grabs whichever is closest: a corner, an edge midpoint (moves two corners) or the centre (moves the whole quad).
- Moves are scaled by a sensitivity setting (0.8). Points are clamped to the image, and any move that would make the quad non-convex is rejected.
- A magnifier loupe, a per-image undo stack, and "reset to full image".
- When no page is detected on a manual shot, the editor opens with a full-frame quad inset by 10 px.

**Palette extraction** (`cpp/src/Utils.cpp` `getPalette`)
- Shrink to 100 px, run k-means with K = 8, drop clusters under 0.1% of pixels, then merge near-duplicates by raising a distance threshold until at most 5 remain.
- The "color" transform then snaps every pixel within a distance of 40 (HSV) to its palette colour, flattening paper and marker shading.
- **For Rescriva:** Core Image's `CIKMeans` gives the clusters without OpenCV. Merge in Lab by colour difference.
  - **Background:** the largest cluster that touches the page border, written to `RescrivaPage.background`.
  - **Palette:** the next 3–5 saturated clusters, written to `RescrivaPage.palette`.
  - **Text colour:** a second k-means inside each text box (darkest cluster that isn't the background), written to the run colour.
  - **Whiteboards:** snapping ink to the palette gives consistent marker colours for diagram strokes, and can be an optional "Markers" look.

**Whitepaper filter** (`WhitePaperTransform.cpp`)
- Six steps:
  1. Difference of Gaussians: a 15 × 15 kernel at sigma 100 (effectively a box blur) minus the image, a high-pass.
  2. Negate.
  3. Per-channel contrast stretch from the 2nd to the 99.5th percentile.
  4. Gaussian blur, 3 px.
  5. Gamma 1.1.
  6. Per-channel colour balance.
- It is a port of an MIT Python script that copies a well-known ImageMagick one-liner, so a Swift rewrite carries no licence baggage.
- **Caveat:** a high-pass removes anything wider than the kernel. Filled shapes, sticky notes and photos go hollow or grey, and thick marker strokes go hollow at full resolution because the kernel is fixed in pixels.
- **For Rescriva:** don't replace the illumination-division cleanup. Add the filter as an "Ink" look for whiteboards and handwriting, with the blur sized from the stroke width `DiagramDetector` already measures, about 4× stroke width (est.).
  - Core Image has every step: `CIGaussianBlur`, `CIColorInvert`, `CIAreaHistogram` for percentiles, a `CIColorPolynomial` or `CIColorCube` stretch, and `CIGammaAdjust`.
- **Bug, if anyone ports it literally:** options are parsed with `as<int>()`, so fractional values like gamma 1.1 are truncated. The app never passes options, so it's latent.

**Book spreads** (`DocumentDetector::detectGutterAndSplit`)
- Sums the horizontal gradient per column, smooths it over ±15 columns, and takes the minimum in the middle 25–75% of the width as the gutter.
- It is only used in the desktop tuner, but it is 80 lines and works as a "split into two pages" action after capture.

**Ink to vector** (`cpp/cpp_test_app/signature_app.cpp`, a Qt prototype that isn't in the app)
- Adaptive threshold, contours, smoothing, then Schneider cubic Bézier fitting, written out as SVG paths.
- Also: an Otsu-based "is this white paper" check, and baseline straightening with `fitLine` plus outlier rejection.
- **For Rescriva:** sketches that aren't diagrams could export as editable freeform shapes (DrawingML `custGeom`) instead of flat crops, and stray marker strokes could survive in a diagram.
  - This needs a new IR case (a freeform path set). Lower priority.

**OCR edits mapped back onto boxes** (`app/components/ocr/OCRDataUpdater.ts`, unit-tested)
- After a free-text edit, it re-aligns the new text onto the old line boxes using anchor matching at line ends and redistributing text across gaps.
- **For Rescriva:** the searchable PDF's text layer comes from raw OCR lines, so word fixes made in Review never reach it. Either draw the text layer from the IR when a rebuilt document exists, or patch the `RecognizedLine` when a flag is resolved. This updater is the reference for arbitrary edits.

**PDF export options** (`DEFAULT_PDF_OPTIONS` in `app/utils/constants.ts`)

| Option | Values or default |
|---|---|
| Paper size | full (image-sized), A4, A3, Letter |
| Orientation | Portrait or landscape |
| Items per page | 1–6, in a 2-column grid |
| Margins | 10 |
| JPEG quality | 80 |
| Max image side | 1500 px |
| Password | iOS: `kCGPDFContextUserPassword` |
| Text layer | On or off |

There's a live preview with "save as default". **For Rescriva:** paper size, quality, max size and password are each small additions to `SearchablePDF`.

### Smaller ideas

- **Edge detection fallback:** threshold and Canny sweeps on each colour channel separately, scored by area plus right-angle-ness, with early exit when a quad is clearly found. Vision is the better primary detector; per-channel thresholds help a white page on a light table if Vision misses.
- **Inverted retry:** if OCR finds nothing, try the inverted image (light text on a dark background). Leptonica's `pixAutoPhotoinvert` does the same per region.
- **Batch re-process:** apply a look or transform to selected pages.
- **Merge:** copy pages from another document into this one.
- **Filename templates:** a date-format template for new scan names.
- **Trash:** soft delete with restore.
- **App lock:** Face ID or passcode, with auto-lock on background.
- **Import PDF:** extract embedded images instead of re-rendering pages.

### Not worth taking

- **OpenCV itself:** Rescriva does the same things with Vision and Core Image.
- **Tesseract OCR as the main engine:** Vision is better on iPhone, and the plan already keeps Tesseract only as an optional language fallback.
- **Sync providers:** WebDAV, Drive, OneDrive and Paperless-ngx. Out of scope next to CloudKit.
- **Android-only entry points:** the scan-for-other-apps activity and the Quick Settings tile.
- **The colour-matrix "B&W" filter:** a hard clamp, no better than Rescriva's.

## Leptonica

Leptonica is a C image library (about 230 files in `src`). It is BSD-2-style licensed: a binary distribution must reproduce its notice.

| Function (file) | What it does | Use in Rescriva |
|---|---|---|
| `pixItalicWords` (`finditalic.c`) | Hit-miss patterns match the slanted right edge of italic strokes, then seed-fill each matching word | Italic cue. As written, one match marks a whole word, which leans toward false positives, so Rescriva needs a density threshold and a second measure |
| `pixFindStrokeWidth` (`strokes.c`) | Stroke width from half the outline length (≈ 2·area / perimeter) or from the distance-transform histogram | Bold cue |
| `lineremoval_reg.c` (example) | Opening with a long horizontal element isolates horizontal lines | Underline and strikethrough cue; table rules |
| `pixGenerateHalftoneMask` / `pixGetRegionsBinary` (`pageseg.c`) | Splits a page into photo regions, text lines and text blocks with morphology at reduced scale | Figure regions without a model |
| `pixDecideIfTable` (`pageseg.c`) | Table likelihood score from -1 to 4; ≥ 3 avoids false positives on CJK text and landscape pages | Gate for "is this a table?" when Vision's grid is uncertain |
| `pixCountTextColumns` (`pageseg.c`) | Number of text columns, worked out at 37–75 ppi | Decides when reading order needs column handling |
| `dewarpSinglePage` (`dewarp*.c`, about 5,800 lines) | Models text-line curvature to flatten curved book pages | Rescriva has no page-curl correction. Too big to port; link it if a harness test justifies it |
| `pixSauvolaBinarize(Tiled)` (`binarize.c`) | Local mean/variance threshold | True B&W look, smaller PDFs, and a clean input for the style cues |
| `pixFindSkew` (`skew.c`) | Skew angle from text lines | Imports with no detectable page edge |

**Figures without a model.** Adapted from Leptonica's idea:
1. Build an ink-density map at about 1/4 scale.
2. Mark tiles with heavy ink or a lot of mid-tone texture.
3. Subtract OCR line boxes, inflated slightly.
4. Close the result.
5. Keep regions above about 2% of the page area (est.).
6. Crop each from the original at full resolution and emit `.figure` blocks plus `RenderOptions.assets`.

This covers the Basic tier now and later becomes the fallback for PP-DocLayoutV3. Line-art charts with few dark pixels will be missed; that's acceptable for a first version.

## Tesseract

**Font attributes are a dead end.**
- `LTRResultIterator::WordFontAttributes` (`src/ccmain/ltrresultiterator.cpp:152-182`) sets `is_underlined = false` unconditionally, with the comment "TODO(rays) fix this!".
- Bold and italic come from `word->fontinfo`, which only the legacy classifier sets. `set_word_fonts` returns early for LSTM words ("Don't try to set the word fonts for an lstm word", `src/ccmain/control.cpp:1922-1926`).
- Getting them means running the slow legacy engine with legacy-capable language data, and the answer is "which training font did this word resemble", a noisy guess.
- The OSS app requests these attributes but barely uses them.

**Layout analysis is the interesting part.**
- `TessBaseAPI::InitForAnalysePage()` sets up layout analysis with no language data, then `AnalyseLayout()` returns blocks typed as: flowing, heading or pull-out text; caption; table; vertical text; flowing, heading or pull-out image; and horizontal or vertical line (`include/tesseract/publictypes.h:52-66`).
- Table finding is on by default. Equation detection is off and needs the legacy classifier.
- The column finder gives column-aware reading order, which Rescriva lacks.
- It is tuned for printed pages and will do little on handwriting or whiteboards.
- Library size is a few MB (est.).
- **Recommendation:** try it in a Mac harness against the test corpus before deciding.
- **Cheaper alternative (not from these repos):** a recursive XY-cut over Vision's block boxes. It splits at the widest vertical whitespace gap first, which fixes most two-column pages with no dependency.

## Bold, italic and underline, built to prefer misses

The rule: a missed style costs one tap in Review, a wrong one makes the export look broken. Each cue therefore returns **yes / no / abstain**, and only "yes" sets a run attribute. Every number below is a starting value to tune (est.).

**When to abstain entirely**
- The page is a whiteboard, or the line looks handwritten: word x-heights in the line vary by more than about 15%.
- The word is shorter than 3 letters.
- The x-height is under about 12 px in the original.
- OCR confidence is below 0.6.
- The word sits in a glare or low-contrast area.
- The page has fewer than about 20 words of body text to set a baseline.

**Setup**
- Binarize each line crop (Sauvola) from the original image.
- Normalize word crops to a fixed x-height, about 32 px.
- Measure every cue *relative to the line median and the page body median*, never as an absolute.

| Style | Measure | Says "yes" only when |
|---|---|---|
| Bold | Stroke width ≈ 2·ink area / outline length, as in Leptonica | ≥ 1.3× the line median **and** ≥ 1.25× the page body median |
| Italic | (a) dominant slant: the shear angle, from -5° to 25°, that makes the vertical projection sharpest; (b) density of slanted-edge hits per letter, as in Leptonica | Slant exceeds the page body median by at least 8° **and** (b) is above its threshold. Both must agree |
| Underline | Opening with a horizontal element 0.6× the word width (`CIMorphologyRectangleMinimum` then `Maximum`) in a band from the baseline to 0.4 x-height below | The run covers ≥ 85% of the word, is thinner than 0.2 x-height, and does not continue across the whole column or meet vertical lines (those are rules or table borders) |
| Strikethrough | Same, in a band around mid x-height | Same coverage and thickness rules |

**Notes**
- **Phrases:** an underline may span several words. Assign it to each word it covers by at least 85%.
- **Whole-line styles:** a fully bold or italic line fails the line-relative test, which is a safe miss. The page-median test then catches it when the page has enough plain body text.
- **Headings:** skip bold on heading blocks, because DOCX heading styles and the PPTX title are bold already.

**How to test**
- Build a synthetic harness like `Tools/GlareFusionHarness`:
  1. Render paragraphs with known styled words using Core Text, across serif, sans and mono fonts.
  2. Apply perspective, blur, noise and JPEG compression.
  3. Score precision and recall per style.
- Set each threshold so precision is at least 95% (est.), and accept whatever recall that leaves.
- Then check on the real corpus.

## Suggested order

| # | Work | Size | Unblocks |
|---|---|---|---|
| 1 | Keep the original; store quad, mode, rotation and look; corner editor with loupe and undo | M | Fixing crops, full-resolution figure crops, re-cleaning in the other mode |
| 2 | Palette, background and text colour sampling (`CIKMeans` + Lab merge) | S | PPTX theme and slide colours that already render |
| 3 | Figure regions → `.figure` blocks + assets | M | Photos and charts in DOCX and PPTX |
| 4 | Draw the PDF text layer from the IR, or patch OCR lines on fix | S | Review fixes in the searchable PDF |
| 5 | Conservative B/I/U with a synthetic harness | M | `RescrivaRun` styling |
| 6 | "Ink" look (stroke-scaled DoG) and true B&W (Sauvola) | S | Whiteboard readability, smaller PDFs |
| 7 | PDF options: paper size, quality, max size, password | S | PDF-scan parity with other apps |
| 8 | Book spreads: gutter split, then a Leptonica dewarp experiment | S, then M | Book and textbook pages |
| 9 | Reading order: XY-cut first; Tesseract layout harness if XY-cut falls short | S / M | Two-column pages |
| 10 | Ink vectorization to freeform shapes (needs a new IR case) | L | Sketches as editable drawings |

## Licences

| Source | Licence | If code is copied or linked |
|---|---|---|
| OSS Document Scanner | MIT, © 2022 Martin Guillon | Keep the notice in acknowledgements |
| Whitepaper origin (santhalakshminarayana/whiteboard-image-enhance) | MIT | Same, only if code is copied |
| Leptonica | BSD-2-style | Reproduce the notice in the app's documentation |
| Tesseract | Apache-2.0 | Include the licence and any NOTICE |

Writing our own Swift from the published algorithms needs no notice, but crediting the sources in acknowledgements costs nothing.
