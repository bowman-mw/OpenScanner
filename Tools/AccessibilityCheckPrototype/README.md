# Accessibility check prototype

Research code from 2026-10-11 for area 8 of `Docs/Acrobat-Parity-Plan.md`. It isn't part of the app target.

| File | What it does |
|---|---|
| `a11ycheck.swift` | Acrobat-style checks using Core Graphics' `CGPDF*` only: catalog, structure tree, marked content against page content, fonts and form tooltips |
| `gen.swift` | Makes untagged and tagged test PDFs the way Quartz writes them |
| `tagged-searchable.swift` | A tagged version of Folio's searchable-PDF layout |
| `fixup.swift` | An incremental update that adds what Quartz leaves out: catalog `/Lang`, `DisplayDocTitle`, page `/Tabs` and a rebuilt `/ParentTree` |
| `results.txt` | The checker's output. The tagged searchable PDF after `fixup` scored 0 fails |

Build and run on a Mac:

```sh
swiftc -O -o a11ycheck a11ycheck.swift && ./a11ycheck file.pdf
```

Known Quartz tagging gaps:
- **ParentTree:** referenced but never written.
- **Language:** no catalog `/Lang`.
- **Artifacts:** no way to mark content as an artifact.
- **Grouping tags:** they get their own MCIDs.
- **Attributes:** none can be written (TH `/Scope`, ColSpan/RowSpan).

Swift pitfall: pass `CGPDFTagProperty.rawValue` keys, not `[CGPDFTagProperty: String] as CFDictionary`, which silently drops `/Alt` and `/Lang`.
