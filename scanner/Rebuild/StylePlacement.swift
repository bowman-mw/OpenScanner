//
//  StylePlacement.swift
//  Folio (fork of Open Scanner)
//
//  Puts StyleDetector's word styles into a rebuilt page. Each OCR line
//  belongs to the one text block holding its centre; the block's run words
//  are matched in order to its lines' words by their letters and digits
//  (the document reader and the line reader can disagree on a word or a
//  bullet), and runs are split where a word's style differs. A style lands
//  only on a word that matched alongside a matching neighbour, so a slipped
//  alignment styles nothing; the run text never changes.
//

import CoreGraphics
import Foundation

extension StyleDetector {
	/// A line word and the styles found on it.
	struct ReadWord: Hashable {
		/// Lower-cased letters and digits, for matching.
		var key: String
		var styles: RunStyles
	}

	/// Words skipped at most, on either side, to find the next match after a mismatch.
	static let maxAlignmentSkip = 3

	// MARK: Lines and blocks

	/// What each line is, from the block holding its centre (`owners`).
	static func roles(for lines: [RecognizedLine], blocks: [FolioBlock]) -> [LineRole] {
		owners(of: lines, in: blocks).map { owner in
			guard let owner, let block = blocks[safe: owner] else { return .skip }
			if case .heading = block.content { return .heading }
			return .body
		}
	}

	/// For each line, the index of the text block (heading, paragraph or list) holding its centre;
	/// nil when no block does, when two do, or when a table, figure, diagram or equation does.
	static func owners(of lines: [RecognizedLine], in blocks: [FolioBlock]) -> [Int?] {
		lines.map { line in
			let centre = CGPoint(x: line.box.midX, y: line.box.midY)
			let holding = blocks.indices.filter { index in blocks[index].box.map { holds($0, centre) } ?? false }
			guard holding.count == 1, let only = holding.first, isStyleable(blocks[only].content) else { return nil }
			return only
		}
	}

	/// Headings, paragraphs and lists. Table cells, figures, diagrams and equations are left alone.
	static func isStyleable(_ content: BlockContent) -> Bool {
		switch content {
		case .heading, .paragraph, .list: return true
		default: return false
		}
	}

	/// `box` (with a little slack) holds `point`.
	static func holds(_ box: NormalizedBox, _ point: CGPoint) -> Bool {
		let slack = 0.005
		return point.x >= box.x - slack && point.x <= box.x + box.width + slack
			&& point.y >= box.y - slack && point.y <= box.y + box.height + slack
	}

	// MARK: Runs

	/// `page` with the styles found on its lines put into its text blocks' runs.
	static func applying(_ found: [LineStyles], lines: [RecognizedLine], to page: FolioPage) -> FolioPage {
		let byLine = Dictionary(found.map { ($0.line, $0) }, uniquingKeysWith: { first, _ in first })
		guard byLine.values.contains(where: { $0.styles.contains { !($0 ?? []).isEmpty } }) else { return page }
		let owners = owners(of: lines, in: page.blocks)
		var result = page
		for blockIndex in result.blocks.indices {
			let members = lines.indices.filter { owners[$0] == blockIndex }.sorted { first, second in
				(lines[first].box.minY, lines[first].box.minX) < (lines[second].box.minY, lines[second].box.minX)
			}
			let read = members.flatMap { readWords(of: lines[$0], found: byLine[$0]) }
			guard read.contains(where: { !$0.styles.isEmpty }) else { continue }
			result.blocks[blockIndex].content = styled(result.blocks[blockIndex].content, read: read)
		}
		return result
	}

	/// The line's words, each with the styles found on it (none where the detector abstained or
	/// didn't read the line).
	static func readWords(of line: RecognizedLine, found: LineStyles?) -> [ReadWord] {
		let words = words(in: line.text)
		guard let found, found.words == words, found.styles.count == words.count else {
			return words.map { ReadWord(key: key(for: $0), styles: []) }
		}
		return zip(words, found.styles).map { ReadWord(key: key(for: $0), styles: $1 ?? []) }
	}

	/// The block's runs with `read` matched onto their words and split where the styles change.
	static func styled(_ content: BlockContent, read: [ReadWord]) -> BlockContent {
		var runWords: [String] = []
		var probe = content
		probe.mapRuns { runs in
			for run in runs {
				runWords.append(contentsOf: words(in: run.text))
			}
			return runs
		}
		let assigned = aligned(runWords.map(key(for:)), to: read)
		guard assigned.count == runWords.count, assigned.contains(where: { !$0.isEmpty }) else { return content }
		var cursor = 0
		var result = content
		result.mapRuns { runs in
			var rewritten: [FolioRun] = []
			for run in runs {
				let count = words(in: run.text).count
				let end = min(assigned.count, cursor + count)
				rewritten.append(contentsOf: splitting(run, styles: Array(assigned[min(cursor, end)..<end])))
				cursor = end
			}
			return rewritten
		}
		return result
	}

	/// For each run word (by key), the styles of the line word it matched: words are matched in
	/// order, skipping at most `maxAlignmentSkip` words on either side to resync after a mismatch,
	/// and a match counts only when a neighbour matched too (or both sides are one word).
	static func aligned(_ keys: [String], to read: [ReadWord]) -> [RunStyles] {
		var matches = [Int?](repeating: nil, count: keys.count)
		var runIndex = 0, readIndex = 0
		for _ in 0..<(keys.count + read.count) {
			guard runIndex < keys.count, readIndex < read.count else { break }
			if keys[runIndex] == read[readIndex].key {
				matches[runIndex] = readIndex
				runIndex += 1
				readIndex += 1
			} else if let skip = resync(keys, from: runIndex, with: read, from: readIndex) {
				runIndex += skip.run
				readIndex += skip.read
			} else {
				runIndex += 1
				readIndex += 1
			}
		}
		return keys.indices.map { index in
			guard let match = matches[index], isAnchored(index, match: match, matches: matches, single: keys.count == 1 && read.count == 1),
				  let word = read[safe: match] else { return [] }
			return word.styles
		}
	}

	/// The smallest skip (run words, line words) after which the two sides match again.
	static func resync(_ keys: [String], from runIndex: Int, with read: [ReadWord], from readIndex: Int) -> (run: Int, read: Int)? {
		guard runIndex < keys.count, readIndex < read.count else { return nil }
		for total in 1...(2 * maxAlignmentSkip) {
			for run in 0...min(total, maxAlignmentSkip) where total - run <= maxAlignmentSkip {
				guard let key = keys[safe: runIndex + run], let word = read[safe: readIndex + total - run] else { continue }
				if key == word.key { return (run, total - run) }
			}
		}
		return nil
	}

	/// The word before or after matched the line words next to `match` as well.
	static func isAnchored(_ index: Int, match: Int, matches: [Int?], single: Bool) -> Bool {
		guard !single else { return true }
		let before = index > 0 && matches[index - 1] == match - 1
		let after = index + 1 < matches.count && matches[index + 1] == match + 1
		return before || after
	}

	/// `run` cut where its words' styles change, each piece keeping the run's own styling; the
	/// spaces between two words take the styles both share, so an underlined phrase stays one run.
	/// A flagged run (one word Review will ask about) stays whole and takes the styles all its words share.
	static func splitting(_ run: FolioRun, styles: [RunStyles]) -> [FolioRun] {
		guard styles.contains(where: { !$0.isEmpty }) else { return [run] }
		guard run.flag == nil else {
			let shared = styles.dropFirst().reduce(styles.first ?? []) { $0.intersection($1) }
			return [adding(shared, to: run)]
		}
		var pieces: [(text: String, styles: RunStyles)] = []
		let parts = textPieces(run.text)
		var wordIndex = 0
		for (index, part) in parts.enumerated() {
			var partStyles: RunStyles = []
			if part.isWord {
				partStyles = styles[safe: wordIndex] ?? []
				wordIndex += 1
			} else if index > 0, index + 1 < parts.count {
				partStyles = (styles[safe: wordIndex - 1] ?? []).intersection(styles[safe: wordIndex] ?? [])
			}
			if let last = pieces.last, last.styles == partStyles {
				pieces[pieces.count - 1].text += part.text
			} else {
				pieces.append((part.text, partStyles))
			}
		}
		return pieces.enumerated().map { index, piece in
			var cut = run
			cut.id = index == 0 ? run.id : UUID()
			cut.text = piece.text
			return adding(piece.styles, to: cut)
		}
	}

	/// `text` as alternating words and spaces, in order; joined they give `text` back.
	static func textPieces(_ text: String) -> [(text: String, isWord: Bool)] {
		var parts: [(text: String, isWord: Bool)] = []
		for character in text {
			let isWord = !character.isWhitespace
			if let last = parts.last, last.isWord == isWord {
				parts[parts.count - 1].text.append(character)
			} else {
				parts.append((String(character), isWord))
			}
		}
		return parts
	}

	/// `run` with `styles` turned on (styles it already has stay on).
	static func adding(_ styles: RunStyles, to run: FolioRun) -> FolioRun {
		var run = run
		run.bold = run.bold || styles.contains(.bold)
		run.italic = run.italic || styles.contains(.italic)
		run.underline = run.underline || styles.contains(.underline)
		run.strikethrough = run.strikethrough || styles.contains(.strikethrough)
		return run
	}

	/// Lower-cased letters and digits: "Review," and "review" match; a bullet or a dash alone has an
	/// empty key, which matches only other punctuation (and never carries a style).
	static func key(for word: String) -> String {
		String(word.filter { $0.isLetter || $0.isNumber }).lowercased()
	}
}
