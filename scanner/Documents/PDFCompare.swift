//
//  PDFCompare.swift
//  Rescriva (fork of Open Scanner)
//
//  Two PDFs side by side: whether they're versions of one document (`similarity`) and where
//  their text differs (`changes`). Lines are matched first, and words only inside the stretches
//  of lines that differ, so text that merely moved to another line or page isn't a change.
//  Pure functions over each page's text (`PDFPage.string`), safe off the main thread.
//
//  Power of 10: every loop is bounded by the text it walks, input is capped at `maxPages`
//  pages and `maxWords` words, and the line and word diffs only run below `maxEdits` and
//  `maxStretchWords`, which bound the diff's memory.
//

import Foundation
import PDFKit

/// One PDF's text for comparing: its words, line by line, and where each sits on its page.
struct PDFCompareText: Sendable {
	/// A word (a run of characters between white space) and its place in its page's text, in
	/// UTF-16 units, the way `PDFPage.selection(for:)` counts.
	struct Word: Hashable, Sendable {
		var text: String
		var page: Int
		var range: NSRange
	}

	/// A line of a page's text: its words joined by single spaces, and where they are in `words`.
	struct Line: Hashable, Sendable {
		var key: String
		var words: Range<Int>
	}

	private(set) var words: [Word] = []
	private(set) var lines: [Line] = []
	/// Indices in `words` where a line begins, and where one ends (one past its last word).
	private(set) var lineStarts: Set<Int> = []
	private(set) var lineEnds: Set<Int> = []

	/// Splits each page's text into lines at line breaks and into words at white space, up to
	/// `PDFCompare.maxPages` pages and `PDFCompare.maxWords` words.
	init(pages: [String]) {
		for (page, text) in pages.prefix(PDFCompare.maxPages).enumerated() where words.count < PDFCompare.maxWords {
			add(page: page, text: text)
		}
	}

	private mutating func add(page: Int, text: String) {
		let string = text as NSString
		var wordStart: Int?
		var lineStart = words.count
		// One step past the end, read as a line break, ends the last word and line.
		for index in 0...string.length where words.count < PDFCompare.maxWords {
			let unit = index < string.length ? string.character(at: index) : 0x0A
			let isBreak = Self.lineBreaks.contains(unit)
			let isSpace = isBreak || Self.isSpace(unit)
			if !isSpace, wordStart == nil { wordStart = index }
			if isSpace, let start = wordStart {
				let range = NSRange(location: start, length: index - start)
				words.append(Word(text: string.substring(with: range), page: page, range: range))
				wordStart = nil
			}
			if isBreak, words.count > lineStart {
				lines.append(Line(key: words[lineStart...].map(\.text).joined(separator: " "), words: lineStart..<words.count))
				lineStarts.insert(lineStart)
				lineEnds.insert(words.count)
				lineStart = words.count
			}
		}
	}

	/// Line feed, carriage return, and the Unicode line and paragraph separators.
	private static let lineBreaks: Set<unichar> = [0x0A, 0x0D, 0x2028, 0x2029]

	private static func isSpace(_ unit: unichar) -> Bool {
		guard let scalar = Unicode.Scalar(unit) else { return false }
		return CharacterSet.whitespaces.contains(scalar)
	}
}

/// How two PDFs compare: how alike their text is, and each stretch where it differs.
struct PDFComparison: Sendable {
	var left: PDFCompareText
	var right: PDFCompareText
	var similarity: Double
	var changes: [PDFCompare.Change]

	/// Alike enough to be versions of one document, whose differences are worth showing.
	var isSameDocument: Bool { similarity >= PDFCompare.sameDocumentSimilarity }
	/// Both PDFs have a text layer to compare (a scan without OCR has none).
	var hasText: Bool { !left.words.isEmpty && !right.words.isEmpty }
}

/// Compares two PDFs' text.
enum PDFCompare {
	/// Share of word pairs in common at or above which two PDFs are versions of one document.
	static let sameDocumentSimilarity = 0.5
	/// Most pages of each PDF compared.
	static let maxPages = 2_000
	/// Most words of each PDF compared.
	static let maxWords = 400_000
	/// Most lines that may differ for the line diff to run (its memory grows with the square).
	static let maxEdits = 2_500
	/// Most words in a stretch of changed lines compared word by word; a longer stretch is one change.
	static let maxStretchWords = 2_000
	/// Most unchanged words between two changes on one line that still join them into one.
	static let maxJoinedGap = 2

	/// A stretch where the two differ: words only the left has and words only the right has, as
	/// ranges of each side's `words`. Either may be empty (a pure insertion or deletion).
	struct Change: Hashable, Sendable, Identifiable {
		var id: Int
		var removed: Range<Int>
		var added: Range<Int>
	}

	/// Each page's text, or nothing for a locked PDF or one that won't open.
	static func pageTexts(at url: URL) -> [String] {
		guard let document = PDFDocument(url: url), !document.isLocked else { return [] }
		return (0..<min(document.pageCount, maxPages)).map { document.page(at: $0)?.string ?? "" }
	}

	/// Compares two PDFs' pages; finds their changes only when they're versions of one document
	/// (or `always`), since every line of two different documents differs.
	static func compare(left leftPages: [String], right rightPages: [String], always: Bool = false) -> PDFComparison {
		let left = PDFCompareText(pages: leftPages)
		let right = PDFCompareText(pages: rightPages)
		let similarity = self.similarity(left, right)
		let changes = always || similarity >= sameDocumentSimilarity ? self.changes(from: left, to: right) : []
		return PDFComparison(left: left, right: right, similarity: similarity, changes: changes)
	}

	/// 0–1: the share of word pairs the two have in common (Jaccard); 0 when neither has text. Pairs
	/// rather than longer runs, so a short document edited in several places still reads as a
	/// version of itself, while two different documents share few pairs.
	static func similarity(_ left: PDFCompareText, _ right: PDFCompareText) -> Double {
		let first = shingles(left.words)
		let second = shingles(right.words)
		let all = first.union(second).count
		guard all > 0 else { return 0 }
		return Double(first.intersection(second).count) / Double(all)
	}

	/// Hashes of each pair of neighbouring words (each word, for fewer than two).
	static func shingles(_ words: [PDFCompareText.Word]) -> Set<Int> {
		guard words.count >= 2 else { return Set(words.map { $0.text.hashValue }) }
		var result = Set<Int>()
		for index in 0..<(words.count - 1) {
			var hasher = Hasher()
			hasher.combine(words[index].text)
			hasher.combine(words[index + 1].text)
			result.insert(hasher.finalize())
		}
		return result
	}

	/// Where `right` differs from `left`, in reading order: the stretches of lines that differ,
	/// then the words that differ within each. When too many lines differ to diff them, the two
	/// count as one change.
	static func changes(from left: PDFCompareText, to right: PDFCompareText) -> [Change] {
		let leftKeys = left.lines.map(\.key)
		let rightKeys = right.lines.map(\.key)
		guard estimatedEdits(leftKeys, rightKeys) <= maxEdits else {
			return [Change(id: 0, removed: 0..<left.words.count, added: 0..<right.words.count)]
		}
		var result: [Change] = []
		for stretch in stretches(leftKeys, rightKeys) {
			let removed = wordRange(of: stretch.left, in: left)
			let added = wordRange(of: stretch.right, in: right)
			for change in wordChanges(removed, in: left, added, in: right) {
				result.append(Change(id: result.count, removed: change.removed, added: change.added))
			}
		}
		return result
	}

	/// The words that differ between `left.words[removed]` and `right.words[added]`, a stretch of
	/// changed lines: none when only the line breaks moved, one change when it's too long to diff.
	static func wordChanges(_ removed: Range<Int>, in left: PDFCompareText, _ added: Range<Int>, in right: PDFCompareText) -> [Change] {
		guard removed.count + added.count <= maxStretchWords else { return [Change(id: 0, removed: removed, added: added)] }
		let leftWords = left.words[removed].map { comparable($0.text) }
		let rightWords = right.words[added].map { comparable($0.text) }
		let found = stretches(leftWords, rightWords).map { stretch in
			Change(id: 0, removed: (removed.lowerBound + stretch.left.lowerBound)..<(removed.lowerBound + stretch.left.upperBound),
				   added: (added.lowerBound + stretch.right.lowerBound)..<(added.lowerBound + stretch.right.upperBound))
		}
		return joiningNearby(found, left: left, right: right).flatMap { splittingWholeLines($0, left: left, right: right) }
	}

	/// `word` without the punctuation at its edges, so a full stop or comma that moved to another
	/// word isn't a change ("landlord." → "landlord in … account."); punctuation alone stays.
	static func comparable(_ word: String) -> String {
		let trimmed = word.trimmingCharacters(in: .punctuationCharacters)
		return trimmed.isEmpty ? word : trimmed
	}

	/// Changes on one line with at most `maxJoinedGap` unchanged words between them, as one: a
	/// sentence reworded around a word it kept ("No pets are permitted on the premises") reads as
	/// one change.
	static func joiningNearby(_ changes: [Change], left: PDFCompareText, right: PDFCompareText) -> [Change] {
		var result: [Change] = []
		for change in changes {
			guard let last = result.last, isNear(last, change, left: left, right: right) else {
				result.append(change)
				continue
			}
			result[result.count - 1] = Change(id: 0, removed: last.removed.lowerBound..<change.removed.upperBound,
											  added: last.added.lowerBound..<change.added.upperBound)
		}
		return result
	}

	/// True when `second` follows `first` closely, on the same line on both sides.
	static func isNear(_ first: Change, _ second: Change, left: PDFCompareText, right: PDFCompareText) -> Bool {
		let leftGap = first.removed.upperBound...second.removed.lowerBound
		let rightGap = first.added.upperBound...second.added.lowerBound
		guard leftGap.count - 1 <= maxJoinedGap, rightGap.count - 1 <= maxJoinedGap else { return false }
		return !leftGap.contains(where: left.lineStarts.contains) && !rightGap.contains(where: right.lineStarts.contains)
	}

	/// A change that ends in whole lines one side has and the other doesn't, split so those lines
	/// are a change of their own: a paragraph reworded and one added after it are two changes.
	static func splittingWholeLines(_ change: Change, left: PDFCompareText, right: PDFCompareText) -> [Change] {
		let extra = linesTouched(change.added, in: right) - linesTouched(change.removed, in: left)
		if extra > 0, !change.removed.isEmpty, let start = start(ofLast: extra, linesOf: change.added, in: right) {
			return [Change(id: 0, removed: change.removed, added: change.added.lowerBound..<start),
					Change(id: 0, removed: change.removed.upperBound..<change.removed.upperBound, added: start..<change.added.upperBound)]
		}
		if extra < 0, !change.added.isEmpty, let start = start(ofLast: -extra, linesOf: change.removed, in: left) {
			return [Change(id: 0, removed: change.removed.lowerBound..<start, added: change.added),
					Change(id: 0, removed: start..<change.removed.upperBound, added: change.added.upperBound..<change.added.upperBound)]
		}
		return [change]
	}

	/// How many lines `text.words[range]` reaches into.
	static func linesTouched(_ range: Range<Int>, in text: PDFCompareText) -> Int {
		guard !range.isEmpty else { return 0 }
		return 1 + (range.lowerBound + 1..<range.upperBound).filter(text.lineStarts.contains).count
	}

	/// Where the last `count` whole lines of `text.words[range]` begin, when it ends a line and
	/// holds that many line starts after its first word.
	static func start(ofLast count: Int, linesOf range: Range<Int>, in text: PDFCompareText) -> Int? {
		guard count > 0, !range.isEmpty, text.lineEnds.contains(range.upperBound) else { return nil }
		let starts = (range.lowerBound + 1..<range.upperBound).filter(text.lineStarts.contains)
		guard starts.count >= count else { return nil }
		return starts[starts.count - count]
	}

	/// The stretches where `right` differs from `left`, in order: a range of `left` only it has
	/// and the range of `right` in its place (either may be empty).
	static func stretches(_ left: [String], _ right: [String]) -> [(left: Range<Int>, right: Range<Int>)] {
		var removed = Set<Int>()
		var inserted = Set<Int>()
		for change in right.difference(from: left) {
			switch change {
			case .remove(let offset, _, _): removed.insert(offset)
			case .insert(let offset, _, _): inserted.insert(offset)
			}
		}
		var result: [(left: Range<Int>, right: Range<Int>)] = []
		var leftIndex = 0
		var rightIndex = 0
		// Each step moves past at least one element of either side.
		for _ in 0...(left.count + right.count) where leftIndex < left.count || rightIndex < right.count {
			let leftStart = leftIndex
			let rightStart = rightIndex
			while leftIndex < left.count, removed.contains(leftIndex) { leftIndex += 1 }
			while rightIndex < right.count, inserted.contains(rightIndex) { rightIndex += 1 }
			if leftIndex > leftStart || rightIndex > rightStart {
				result.append((leftStart..<leftIndex, rightStart..<rightIndex))
			} else {
				leftIndex += 1
				rightIndex += 1
			}
		}
		return result
	}

	/// A floor on how many lines must be removed or inserted: the lines one side has more often
	/// than the other.
	static func estimatedEdits(_ left: [String], _ right: [String]) -> Int {
		var counts: [String: Int] = [:]
		for key in left { counts[key, default: 0] += 1 }
		for key in right { counts[key, default: 0] -= 1 }
		return counts.values.reduce(0) { $0 + abs($1) }
	}

	// MARK: Describing a change

	/// What a change does, which sets how it's marked.
	enum Kind: Sendable {
		/// A few words read differently (a date, an amount): marked on both sides.
		case changed
		/// Words only the right has.
		case added
		/// Words only the left has.
		case removed
		/// A longer passage worded differently: struck out on the left, added on the right.
		case rewritten
	}

	/// Most words on either side of a change that still count as a few words read differently.
	static let maxChangedWords = 4
	/// Longest excerpt of either side in a change's summary, in characters.
	static let maxExcerptLength = 48

	static func kind(of change: Change) -> Kind {
		if change.removed.isEmpty { return .added }
		if change.added.isEmpty { return .removed }
		return max(change.removed.count, change.added.count) <= maxChangedWords ? .changed : .rewritten
	}

	/// "October 1, 2026 → November 1, 2026", "Added: …" or "Removed: …".
	static func summary(of change: Change, left: PDFCompareText, right: PDFCompareText) -> String {
		let old = excerpt(change.removed, in: left)
		let new = excerpt(change.added, in: right)
		switch kind(of: change) {
		case .added: return String(localized: "Added: \(new)")
		case .removed: return String(localized: "Removed: \(old)")
		case .changed, .rewritten: return "\(old) → \(new)"
		}
	}

	/// The page, from 1, a change is on: where its words went, or for a removal where they were.
	static func page(of change: Change, left: PDFCompareText, right: PDFCompareText) -> Int {
		let word = change.added.isEmpty ? left.words[safe: change.removed.lowerBound] : right.words[safe: change.added.lowerBound]
		return (word?.page ?? 0) + 1
	}

	/// `text.words[range]` joined, cut to `limit` characters.
	static func excerpt(_ range: Range<Int>, in text: PDFCompareText, limit: Int = maxExcerptLength) -> String {
		assert(limit > 1, "room for at least one character and the ellipsis")
		let joined = text.words[range.clamped(to: 0..<text.words.count)].prefix(limit).map(\.text).joined(separator: " ")
		guard joined.count > limit else { return joined }
		return String(joined.prefix(limit - 1)) + "…"
	}

	/// The words of `text.lines[lines]`.
	static func wordRange(of lines: Range<Int>, in text: PDFCompareText) -> Range<Int> {
		guard let first = text.lines[safe: lines.lowerBound], let last = text.lines[safe: lines.upperBound - 1], !lines.isEmpty else {
			// No lines: an empty range where the next line's words start.
			let at = text.lines[safe: lines.lowerBound]?.words.lowerBound ?? text.words.count
			return at..<at
		}
		return first.words.lowerBound..<last.words.upperBound
	}

	/// Where `text.words[range]` sits on each page: one span per page, from its first word there
	/// to its last. An empty range gives the word it comes before (or the last word), to show where
	/// the other side's words would go.
	static func spans(of range: Range<Int>, in text: PDFCompareText) -> [(page: Int, range: NSRange)] {
		guard !range.isEmpty else {
			let index = min(range.lowerBound, text.words.count - 1)
			return text.words[safe: index].map { [($0.page, $0.range)] } ?? []
		}
		var result: [(page: Int, range: NSRange)] = []
		for word in text.words[range.clamped(to: 0..<text.words.count)] {
			if let last = result.last, last.page == word.page {
				let end = word.range.location + word.range.length
				result[result.count - 1].range = NSRange(location: last.range.location, length: end - last.range.location)
			} else {
				result.append((word.page, word.range))
			}
		}
		return result
	}
}
