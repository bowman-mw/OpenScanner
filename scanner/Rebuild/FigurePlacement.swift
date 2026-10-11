//
//  FigurePlacement.swift
//  Folio (fork of Open Scanner)
//
//  Puts the pictures FigureDetector found into a rebuilt page as figure
//  blocks:
//    - text blocks lying clearly inside a picture (a chart's labels, a sign
//      in a photo) leave the text flow; their words become the figure's alt
//      text, so search and the PDF's text layer still have them. A picture
//      with prose inside it (a block of several lines and many words, or
//      more text than alt text should hold) isn't placed at all: a shaded
//      panel or a wrong box mustn't take a paragraph out of the page;
//    - a short block just below or above it becomes its caption: one that
//      starts like a caption ("Figure 3", "Fig. 2:", "Table 1", "Chart:",
//      "Source:"…) in at most three lines, but not a sentence about the
//      figure ("Figure 2 shows…"), or, below only, a single line of a few
//      words centred under it and no wider. A block with an unconfirmed
//      word stays text, where Review can fix it;
//    - each figure goes where it sits on the page, in reading order.
//  Anything that isn't clearly inside a picture or clearly its caption stays
//  where it was.
//
//  Foundation only, so it runs in unit tests off-device.
//

import CoreGraphics
import Foundation

/// Places detected figures among a page's blocks (see the file header).
enum FigurePlacement {
	enum Tuning {
		/// A block counts as inside a figure when its box is within the figure's grown by this.
		static let insideSlack = 0.005
		/// Furthest a caption sits from its figure, and how far it may overlap it (page shares).
		static let maxCaptionGap = 0.04
		static let maxPlainCaptionGap = 0.025
		static let captionOverlap = 0.01
		/// A caption overlaps its figure horizontally over at least this share of its own width.
		static let minCaptionAlignment = 0.5
		static let maxCaptionLength = 200
		/// A caption without a caption word: a line of at most this many characters …
		static let maxPlainCaptionLength = 120
		/// … with at least this many words and letters …
		static let minPlainCaptionWords = 3
		static let minPlainCaptionLetters = 12
		/// … centred under the figure within this share of its width, and this wide relative to it.
		static let maxPlainCaptionOffset = 0.1
		static let plainCaptionWidth = 0.25...1.05
		/// A caption with a caption word runs at most this many OCR lines.
		static let maxCaptionLines = 3
		/// A figure isn't placed when the text inside it runs longer than this …
		static let maxInsideTextLength = 500
		/// … or one block inside it is prose: at least this many lines and words.
		static let minProseLines = 2
		static let minProseWords = 10
	}

	/// `blocks` with each of `figures` placed as a figure block (see the file header). `lines` are the
	/// page's OCR lines, which tell a one-line caption from a block of several.
	static func placing(_ figures: [DetectedFigure], into blocks: [FolioBlock], lines: [RecognizedLine]) -> [FolioBlock] {
		var result = blocks
		for figure in figures.prefix(FigureDetector.Tuning.maxFigures) {
			result = placing(figure, into: result, lines: lines)
		}
		return result
	}

	/// `blocks` with `figure` placed: the text inside it as its alt text, a caption beside it as its
	/// caption, and the figure block (a fresh asset id) in reading order. `blocks` unchanged when
	/// there is prose inside it (`holdsProse`).
	static func placing(_ figure: DetectedFigure, into blocks: [FolioBlock], lines: [RecognizedLine]) -> [FolioBlock] {
		let inside = blocks.filter { isInside($0, figure.box) }
		guard !holdsProse(inside, lines: lines) else { return blocks }
		var kept = blocks.filter { !isInside($0, figure.box) }
		var caption: String?
		if let index = captionIndex(for: figure.box, in: kept, lines: lines) {
			caption = condensed(kept[index].content.plainText)
			kept.remove(at: index)
		}
		let content = BlockContent.figure(assetID: UUID().uuidString, caption: caption, altText: altText(from: inside))
		let block = FolioBlock(content: content, box: figure.box,
							   provenance: Provenance(engine: "figureDetector", confidence: figure.confidence))
		let insertAt = kept.firstIndex { ($0.box?.y ?? 0) > figure.box.y } ?? kept.endIndex
		kept.insert(block, at: insertAt)
		return kept
	}

	/// True for a heading, paragraph or list whose box lies within `box`.
	static func isInside(_ block: FolioBlock, _ box: NormalizedBox) -> Bool {
		guard let frame = block.box else { return false }
		switch block.content {
		case .heading, .paragraph, .list: break
		case .table, .equation, .figure, .diagram: return false
		}
		let area = box.rect.insetBy(dx: -Tuning.insideSlack, dy: -Tuning.insideSlack)
		return area.contains(frame.rect)
	}

	/// True when the text blocks inside a figure read as prose rather than labels: more text in all
	/// than `maxInsideTextLength`, or one block of `minProseLines` OCR lines and `minProseWords`
	/// words. Its words would leave the page's text for alt text nobody sees, so the picture is
	/// better missed.
	static func holdsProse(_ inside: [FolioBlock], lines: [RecognizedLine]) -> Bool {
		guard !inside.isEmpty else { return false }
		let texts = inside.map { condensed($0.content.plainText) }
		guard texts.joined(separator: " ").count <= Tuning.maxInsideTextLength else { return true }
		return zip(inside, texts).contains { block, text in
			guard let frame = block.box, text.split(separator: " ").count >= Tuning.minProseWords else { return false }
			return lineCount(in: frame, lines: lines) >= Tuning.minProseLines
		}
	}

	/// The words of `blocks`, in order, white space collapsed; nil when there are none. Never cut
	/// short: removing the figure in Review restores the page's text from it (`holdsProse` keeps it
	/// to labels).
	static func altText(from blocks: [FolioBlock]) -> String? {
		let text = condensed(blocks.map(\.content.plainText).joined(separator: " "))
		return text.isEmpty ? nil : text
	}

	/// How many of `lines` have their centre in `frame` (grown by `insideSlack`).
	static func lineCount(in frame: NormalizedBox, lines: [RecognizedLine]) -> Int {
		let area = frame.rect.insetBy(dx: -Tuning.insideSlack, dy: -Tuning.insideSlack)
		return lines.filter { area.contains(CGPoint(x: $0.box.midX, y: $0.box.midY)) }.count
	}

	// MARK: Captions

	/// The block that captions `box`: one starting like a caption just below it, else just above it,
	/// else a plain one-line caption just below it; the nearest on a tie. Nil when none qualifies.
	static func captionIndex(for box: NormalizedBox, in blocks: [FolioBlock], lines: [RecognizedLine]) -> Int? {
		var best: (index: Int, rank: Int, gap: Double)?
		for (index, block) in blocks.enumerated() {
			guard let rank = captionRank(block, figure: box, lines: lines), let frame = block.box else { continue }
			let gap = max(frame.y - (box.y + box.height), box.y - (frame.y + frame.height))
			if let current = best, (current.rank, current.gap) <= (rank, gap) { continue }
			best = (index, rank, gap)
		}
		return best?.index
	}

	/// 0 for a caption-worded block below `figure`, 1 for one above it, 2 for a plain one-line caption
	/// below it; nil for anything else.
	static func captionRank(_ block: FolioBlock, figure: NormalizedBox, lines: [RecognizedLine]) -> Int? {
		guard let frame = block.box, block.content.flags.allSatisfy({ $0.resolution != nil }) else { return nil }
		let isParagraph: Bool
		switch block.content {
		case .paragraph: isParagraph = true
		case .heading: isParagraph = false
		case .list, .table, .equation, .figure, .diagram: return nil
		}
		let text = condensed(block.content.plainText)
		guard !text.isEmpty, text.count <= Tuning.maxCaptionLength, alignedHorizontally(frame, figure) else { return nil }
		let below = frame.y - (figure.y + figure.height)
		let above = figure.y - (frame.y + frame.height)
		if startsLikeCaption(text) {
			guard !readsAsSentence(text), lineCount(in: frame, lines: lines) <= Tuning.maxCaptionLines else { return nil }
			if (-Tuning.captionOverlap...Tuning.maxCaptionGap).contains(below) { return 0 }
			if (-Tuning.captionOverlap...Tuning.maxCaptionGap).contains(above) { return 1 }
			return nil
		}
		guard isParagraph, (-Tuning.captionOverlap...Tuning.maxPlainCaptionGap).contains(below),
			  isPlainCaption(text, frame: frame, figure: figure, lines: lines) else { return nil }
		return 2
	}

	/// "Figure 3", "Fig. 2:", "Table IV –", "Plate B.", "Chart:", "Source: …", "Photo: …": a caption
	/// word, then a number, a roman numeral, a letter with a stop, or punctuation. ("Table salt
	/// is…" and "Chart a course…" don't count.)
	static func startsLikeCaption(_ text: String) -> Bool {
		let pattern = /^(figure|fig|table|tab|chart|graph|exhibit|plate|diagram|illustration|map|sources?|photo|image|credit)\b\.?\s*(\d|[ivxlc]+\b|[a-z][:.)]|[:.\-–—])/
		return text.firstMatch(of: pattern.ignoresCase()) != nil
	}

	/// "Figure 2 shows…", "Table 1 lists…": a caption word and its number, then a word in lower case.
	/// That's body text about the figure; a caption goes on with punctuation or a capital
	/// ("Figure 2: Revenue", "Figure 2. Revenue", "Table 1 Summary").
	static func readsAsSentence(_ text: String) -> Bool {
		let pattern = /^(?:figure|fig|table|tab|chart|graph|exhibit|plate|diagram|illustration|map)\b\.?\s*(?:\d+[a-z]?|[ivxlc]+)\s+(\S)/
		guard let match = text.firstMatch(of: pattern.ignoresCase()) else { return false }
		return match.1.first?.isLowercase ?? false
	}

	/// A caption with no caption word: one OCR line of a few real words, centred under the figure
	/// and no wider than it.
	static func isPlainCaption(_ text: String, frame: NormalizedBox, figure: NormalizedBox, lines: [RecognizedLine]) -> Bool {
		let words = text.split(whereSeparator: \.isWhitespace)
		guard text.count <= Tuning.maxPlainCaptionLength, words.count >= Tuning.minPlainCaptionWords,
			  text.filter(\.isLetter).count >= Tuning.minPlainCaptionLetters, figure.width > 0 else { return false }
		let offset = abs((frame.x + frame.width / 2) - (figure.x + figure.width / 2))
		guard offset <= Tuning.maxPlainCaptionOffset * figure.width,
			  Tuning.plainCaptionWidth.contains(frame.width / figure.width) else { return false }
		return lineCount(in: frame, lines: lines) == 1
	}

	/// True when at least `minCaptionAlignment` of `frame`'s width lies over `figure`.
	static func alignedHorizontally(_ frame: NormalizedBox, _ figure: NormalizedBox) -> Bool {
		let overlap = min(frame.x + frame.width, figure.x + figure.width) - max(frame.x, figure.x)
		return frame.width > 0 && overlap >= Tuning.minCaptionAlignment * frame.width
	}

	/// `text` with runs of white space as single spaces, trimmed.
	static func condensed(_ text: String) -> String {
		text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
	}
}
