//
//  StyleDetector.swift
//  Folio (fork of Open Scanner)
//
//  Bold, italic, underline and strikethrough in typed text, built to prefer
//  misses: a missed style costs one tap in Review, a wrong one makes the
//  export look broken. Every cue answers yes, no or abstain, and only a yes
//  styles a word (Docs/OSS-Reference-Review.md, "Bold, italic and underline").
//
//  1. Words: each OCR line's crop of the page is binarized (Sauvola) and cut
//     at the gaps of its vertical projection over the x-height zone (a gap
//     under a T's or an F's bar is a letter gap), without asking PageOCR for
//     word boxes. The cut stands only when it gives exactly the line's word
//     count, word gaps clearly wider than letter gaps; otherwise the line
//     abstains.
//  2. Cues, always relative to the word's line and the page's body text:
//       bold — stroke width (2 · ink area / outline length) on the word
//              scaled to a 32 px x-height: ≥ 1.3× the line median and
//              ≥ 1.25× the page median;
//       italic — the shear from −5° to 25° that makes the word's vertical
//              projection sharpest is ≥ 8° past the page median, and long
//              right-leaning stroke edges (Leptonica's pixItalicWords idea)
//              are dense enough per letter. Both must agree, and long upright
//              edges must be rare: an upright word whose v's and y's lean
//              ("every") still has its stems; so must long edges leaning
//              left as far: an upright word made of diagonals ("was",
//              "savvy", "XXV") leans both ways, a sheared one doesn't;
//       underline — runs at least 0.6× the word's width (a horizontal
//              opening) from the baseline to 0.4 x-height below it, covering
//              ≥ 85% of the word, thinner than 0.2 x-height (plus a pixel, as
//              it's measured at full size), neither running on past the
//              line's text nor meeting a vertical line (rules and table
//              borders aren't underlines); a phrase underline marks each word
//              it covers;
//       strikethrough — the same around mid x-height.
//  3. Abstains on whiteboard and handwritten pages (Rebuilder only calls it
//     for typed ones), handwriting-like lines (word x-heights vary more than
//     15%), words under 3 letters, x-heights under 12 px, lines read with
//     confidence under 0.6, low-contrast (glare) words, tables, figures and
//     text outside a block, bold in headings (they're bold already), and on
//     the whole page when it has fewer than 20 body words to compare with.
//  The thresholds are tuned on StyleDetectorTests' synthetic pages (sans,
//  serif and mono, blurred, compressed, rotated and noised) for at least 95%
//  precision per style, accepting lower recall.
//
//  StyleMeasure.swift holds the pixel work, StylePlacement.swift puts the
//  styles into the rebuilt page's runs. Foundation, CoreGraphics and ImageIO
//  only; every step is a pure function of its inputs, so it runs on a
//  background task.
//

import CoreGraphics
import Foundation
import ImageIO

/// Styles found on one word.
struct RunStyles: OptionSet, Hashable, Sendable {
	let rawValue: Int

	static let bold = RunStyles(rawValue: 1 << 0)
	static let italic = RunStyles(rawValue: 1 << 1)
	static let underline = RunStyles(rawValue: 1 << 2)
	static let strikethrough = RunStyles(rawValue: 1 << 3)
}

/// What an OCR line is on the page, from the block it sits in.
enum LineRole: Hashable, Sendable {
	/// Paragraph or list text: styled, and part of the page's body baseline.
	case body
	/// Heading text: styled except bold, and not part of the body baseline.
	case heading
	/// Tables, figures, diagrams, equations and text outside any block: left alone.
	case skip
}

/// What the detector read on one OCR line.
struct LineStyles: Hashable, Sendable {
	/// Index of the line among the page's lines.
	var line: Int
	/// The line's words, split from its text at spaces.
	var words: [String]
	/// Per word: the styles found (empty for plain text), or nil where the detector abstained.
	var styles: [RunStyles?]
}

/// Finds bold, italic, underlined and struck-through words on a typed page
/// (see the file header). Stateless; safe to call from any thread.
enum StyleDetector {
	/// Reads stored page data (the cleaned JPEG). Returns only the lines it could read; empty when
	/// the page abstains as a whole.
	static func detect(_ data: Data, lines: [RecognizedLine], roles: [LineRole]) -> [LineStyles] {
		guard !data.isEmpty, lines.count == roles.count,
			  candidateBodyWords(lines, roles: roles) >= Tuning.minPageBodyWords,
			  let image = workingImage(data) else { return [] }
		return detect(image, lines: lines, roles: roles)
	}

	/// Reads a page image whose pixels line up with the lines' boxes.
	static func detect(_ image: CGImage, lines: [RecognizedLine], roles: [LineRole]) -> [LineStyles] {
		guard lines.count == roles.count, candidateBodyWords(lines, roles: roles) >= Tuning.minPageBodyWords,
			  let page = Gray(image: image, maxSide: Tuning.workingMaxSide) else { return [] }
		var readings: [LineReading] = []
		for index in lines.indices where isReadable(lines[index], role: roles[index]) {
			guard let reading = LineReader.read(index, lines: lines, page: page, role: roles[index]) else { continue }
			readings.append(reading)
		}
		return decide(readings)
	}

	/// Decodes stored image data without EXIF rotation, so pixels line up with
	/// the boxes Vision read off the same unrotated image; full size up to `workingMaxSide`.
	static func workingImage(_ data: Data) -> CGImage? {
		guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
		let options: [CFString: Any] = [
			kCGImageSourceCreateThumbnailFromImageAlways: true,
			kCGImageSourceThumbnailMaxPixelSize: Tuning.workingMaxSide,
			kCGImageSourceCreateThumbnailWithTransform: false,
			kCGImageSourceShouldCacheImmediately: true,
		]
		return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
	}

	/// Body or heading text read with enough confidence.
	static func isReadable(_ line: RecognizedLine, role: LineRole) -> Bool {
		guard role != .skip, line.confidence >= Tuning.minLineConfidence else { return false }
		return line.box.width > 0 && line.box.height > 0
	}

	/// Words of 3 letters or more on readable body lines: an upper bound on the page's body
	/// baseline, so a page that can't reach it isn't decoded at all.
	static func candidateBodyWords(_ lines: [RecognizedLine], roles: [LineRole]) -> Int {
		guard lines.count == roles.count else { return 0 }
		var count = 0
		for (line, role) in zip(lines, roles) where role == .body && isReadable(line, role: role) {
			count += words(in: line.text).filter { letterCount($0) >= Tuning.minLetters }.count
		}
		return count
	}

	// MARK: Decisions

	/// Each read line's styles, judged against its own words and the page's body words; nothing
	/// when the page has too few body words to judge by.
	static func decide(_ readings: [LineReading]) -> [LineStyles] {
		let body = readings.filter { $0.role == .body }.flatMap { $0.words.compactMap { $0 } }
		guard body.count >= Tuning.minPageBodyWords,
			  let strokeWidth = median(body.map(\.strokeWidth)), strokeWidth > 0,
			  let slant = median(body.map(\.slant)) else { return [] }
		let page = Baseline(strokeWidth: strokeWidth, slant: slant)
		return readings.map { reading in
			let measured = reading.words.compactMap { $0 }
			// A median of one or two words would compare a word with itself.
			let lineStroke = measured.count >= Tuning.minLineWords ? median(measured.map(\.strokeWidth)) : nil
			let judged = reading.words.map { word in
				word.map { styles(of: $0, role: reading.role, lineStroke: lineStroke, page: page) }
			}
			return LineStyles(line: reading.index, words: reading.tokens, styles: judged)
		}
	}

	/// The styles one measured word earns.
	static func styles(of word: WordReading, role: LineRole, lineStroke: Double?, page: Baseline) -> RunStyles {
		assert(page.strokeWidth > 0, "the page baseline has a stroke width")
		var found: RunStyles = []
		if role != .heading, let lineStroke, isBold(word.strokeWidth, line: lineStroke, page: page.strokeWidth) {
			found.insert(.bold)
		}
		if isItalic(word, pageSlant: page.slant) {
			found.insert(.italic)
		}
		if word.underline {
			found.insert(.underline)
		}
		if word.strikethrough {
			found.insert(.strikethrough)
		}
		return found
	}

	/// Clearly heavier than both its line and the page's body text.
	static func isBold(_ strokeWidth: Double, line: Double, page: Double) -> Bool {
		guard line > 0, page > 0 else { return false }
		return strokeWidth >= Tuning.boldOverLine * line && strokeWidth >= Tuning.boldOverPage * page
	}

	/// Clearly more slanted than the page's body text, with the long slanted edges to show for it,
	/// few upright ones (an upright word with diagonals, like "every", has its stems) and few
	/// leaning the other way (an upright word made of diagonals, like "was" or "savvy", has as many
	/// \ edges as / ones; a sheared one has few).
	static func isItalic(_ word: WordReading, pageSlant: Double) -> Bool {
		guard word.slant <= Tuning.maxItalicSlant, word.slant - pageSlant >= Tuning.italicOverPage else { return false }
		guard word.edgeHits >= Tuning.minEdgeHitsPerLetter, word.uprightHits <= Tuning.maxUprightHitShare * word.edgeHits else { return false }
		return word.mirroredHits <= Tuning.maxMirroredHitShare * word.edgeHits
	}

	// MARK: Words

	/// The words of `text`: its runs of non-space characters, in order.
	static func words(in text: String) -> [String] {
		text.split(whereSeparator: \.isWhitespace).map(String.init)
	}

	static func letterCount(_ word: String) -> Int {
		word.reduce(0) { $0 + ($1.isLetter ? 1 : 0) }
	}

	/// The middle value (the upper middle for an even count); nil for none.
	static func median(_ values: [Double]) -> Double? {
		guard !values.isEmpty else { return nil }
		return values.sorted()[values.count / 2]
	}
}

// MARK: - Working types

extension StyleDetector {
	/// The page's body text, for judging each word against.
	struct Baseline: Hashable {
		/// Median stroke width, at the normalized x-height.
		var strokeWidth: Double
		/// Median dominant slant, degrees.
		var slant: Double
	}

	/// One OCR line as measured.
	struct LineReading: Hashable {
		var index: Int
		var role: LineRole
		var tokens: [String]
		/// Per token; nil where the word wasn't measured (too short, low contrast).
		var words: [WordReading?]
	}

	/// One word's cues.
	struct WordReading: Hashable {
		/// 2 · ink area / outline length on the word scaled to the normalized x-height.
		var strokeWidth: Double
		/// Shear angle that makes the vertical projection sharpest, degrees (right-leaning positive).
		var slant: Double
		/// Long right-leaning stroke edges per letter at that slant.
		var edgeHits: Double
		/// Long upright stroke edges per letter (counted only when the word leans).
		var uprightHits: Double
		/// Long stroke edges per letter leaning left as far as the word leans right (counted only
		/// when it leans): the other arm of an upright v, w, x or y.
		var mirroredHits: Double = 0
		var underline: Bool
		var strikethrough: Bool
	}

	/// Every threshold in one place. Lengths are in x-heights unless named otherwise.
	enum Tuning {
		// Page.
		static let workingMaxSide = 3200
		static let minLineConfidence: Float = 0.6
		static let minPageBodyWords = 20
		static let maxWordsPerLine = 40

		// Words and lines.
		static let minLetters = 3
		static let minXHeight = 12.0
		static let normalizedXHeight = 32.0
		/// Interquartile spread of a line's word x-heights over their median past which it looks handwritten.
		static let maxXHeightSpread = 0.15
		static let minLineWords = 3

		// Crop around each line, as shares of its box's height.
		static let topMargin = 0.2
		static let bottomMargin = 0.4
		static let sideMargin = 0.6
		static let minCropSide = 8

		// Binarization: grey-level shares, Sauvola's k and range, contrasts in grey levels.
		static let linePaperShare = 0.9
		static let lineInkShare = 0.02
		static let wordPaperShare = 0.8
		static let wordInkShare = 0.03
		static let sauvolaK = 0.3
		static let sauvolaRange = 128.0
		static let minLineContrast = 60
		static let minWordContrastShare = 0.5

		// Bands: rows at least this share of the busiest row make the x-height zone.
		static let bandShare = 0.3

		// Cutting a line into words.
		static let minWordGap = 0.15
		static let maxLetterGapShare = 0.7
		static let maxSingleWordGap = 0.6
		static let minWidthPerLetter = 0.3
		static let maxWidthPerLetter = 2.4
		static let wordPad = 2
		/// A gap under a capital's bar (T, F) is a letter gap: the bar, at least this long, spans
		/// this share of it, somewhere in the cap zone this far above the x-height zone.
		static let minBridgeBar = 0.35
		static let minBridgeCover = 0.6
		static let capitalReach = 0.8
		/// How far above the baseline a word's crop reaches: the x-height zone and the ascenders.
		static let ascenderReach = 1.8

		// Bold.
		static let boldOverLine = 1.3
		static let boldOverPage = 1.25
		static let minStrokeInk = 40

		// Italic: the shear search (degrees), its coarse step, and the slanted-edge sel.
		static let minSlant = -5
		static let maxSlant = 25
		static let coarseSlantStep = 3
		static let maxItalicSlant = 24.0
		static let italicOverPage = 8.0
		static let minHitSlant = 5.0
		static let edgeStep = 5
		static let edgeSamples = 3
		static let edgeGap = 2
		static let minEdgeHitsPerLetter = 12.0
		static let maxUprightHitShare = 0.3
		/// Upright diagonal words measure 0.64 or more, italics almost all 0.44 or less (sans, serif and mono).
		static let maxMirroredHitShare = 0.45
		static let minSlantRuns = 20

		// Underline and strikethrough. Thickness is measured on the full-size line, so it gets a
		// pixel of slack over `maxStrokeThickness` for the binarized edge.
		static let minStrokeShare = 0.6
		static let minStrokeCoverage = 0.85
		static let maxStrokeThickness = 0.2
		static let underlineGap = 0.06
		static let underlineDepth = 0.4
		static let strikeLow = 0.2
		static let strikeHigh = 0.75
		static let maxStrokeOverhang = 0.6
		static let verticalLineLength = 1.8
		static let verticalLineReach = 2
	}
}
