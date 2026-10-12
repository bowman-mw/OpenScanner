//
//  TextLayerReconciler.swift
//  Rescriva (fork of Open Scanner)
//
//  Carries Review's fixes into the searchable PDF. The PDF's invisible text
//  layer is drawn from each page's raw OCR lines (one box per line), but a
//  word fixed in Review only changes the rebuilt RescrivaDocument. This lines the
//  two up word by word and writes the rebuilt words back onto the OCR lines,
//  boxes unchanged — after OSS Document Scanner's OCRDataUpdater, which
//  re-aligns edited text onto the old line boxes.
//
//  1. Words: every OCR line, and the rebuilt page's headings, paragraphs,
//     list items, table cells and figure words (the text read inside a
//     picture, then its caption) in reading order, split on white space.
//     Diagrams and equations are left out; their words stay as read.
//  2. Alignment: a word-level edit distance (O(n·m), capped at a million
//     cells) with five steps — keep a word (the same, or fixed), split one
//     word into two, merge two into one, delete, insert. A near miss costs
//     less than a different word, so fixes line up with what they replaced.
//  3. Lines: kept, split and merged words land on their OCR word's line; an
//     inserted word joins the line of its nearest aligned neighbour, unless
//     it's part of a long run the OCR never saw (another reading order, a
//     region it missed), which has no box to go in and is left out. A word
//     deleted in one place and inserted in another was only read in another
//     order (columns, a sidebar), so it stays where the OCR put it. Other
//     deleted words go only when exact matches hem them in on both sides;
//     marks with no letters (bullets, checkboxes, numbers), which the rebuild
//     strips from list items on purpose, always stay.
//  4. Doubt: a page is reconciled only when it was rebuilt from these very
//     lines (a line edited or deleted since changes their fingerprint) and
//     at least half its words match exactly, and a line rewritten only when
//     it aligns well. When unsure, the OCR text stays.
//
//  Foundation only, so it runs in unit tests off-device.
//

import Foundation

/// Writes a rebuilt page's words back onto its OCR lines (see the file header).
enum TextLayerReconciler {
	enum Tuning {
		/// Largest alignment table (OCR words × rebuilt words); bigger pages keep their OCR text.
		static let maxCells = 1_000_000
		/// A page is reconciled only when at least this share of the shorter side's words match exactly.
		static let pageMatchShare = 0.5
		/// A line is rewritten only when its words align better than this on average.
		static let lineSimilarity = 0.5
		/// Two words at least this alike (case-insensitive) read as one word misread.
		static let similarWord = 0.5
		/// A split or merge needs the joined words at least this alike.
		static let similarJoin = 0.75
		/// Longest word compared letter by letter; longer words only match exactly.
		static let maxWordLength = 64
		/// Longest run of inserted words put on a line; longer runs are left out.
		static let maxInsertRun = 4
	}

	/// Alignment costs. A fix is cheaper than dropping a word and adding
	/// another, and a near miss cheaper than a different word. A near join
	/// costs more than a gap, so a word that matches on its own is kept and
	/// its stray neighbour dropped rather than glued on.
	private enum Cost {
		static let match = 0
		static let exactJoin = 1
		static let similar = 2
		static let gap = 2
		static let different = 3
		static let nearJoin = 3
	}

	/// One word, and the OCR line it came from.
	struct Word: Hashable {
		let text: String
		/// Lower-cased scalars, compared for similarity.
		let folded: [Unicode.Scalar]
		/// Index of the OCR line; -1 for rebuilt words.
		let line: Int
		/// No letters: a bullet, checkbox, dash or number.
		let isMark: Bool

		init(_ text: String, line: Int) {
			self.text = text
			self.folded = Array(text.lowercased().unicodeScalars)
			self.line = line
			self.isMark = !text.contains(where: \.isLetter)
		}
	}

	/// One step of an alignment, in reading order. Indices are word positions.
	enum Step: Hashable {
		/// OCR word `ocr` reads as rebuilt word `rebuilt` (the same word, or a fix).
		case keep(ocr: Int, rebuilt: Int)
		/// OCR word `ocr` became rebuilt words `rebuilt` and `rebuilt + 1`.
		case split(ocr: Int, rebuilt: Int)
		/// OCR words `ocr` and `ocr + 1` became rebuilt word `rebuilt`.
		case merge(ocr: Int, rebuilt: Int)
		/// OCR word `ocr` isn't in the rebuilt text.
		case delete(ocr: Int)
		/// Rebuilt word `rebuilt` isn't in the OCR text.
		case insert(rebuilt: Int)

		/// The OCR word whose line this step's text lands on; nil for gaps.
		var anchor: Int? {
			switch self {
			case .keep(let ocr, _), .split(let ocr, _), .merge(let ocr, _): return ocr
			case .delete, .insert: return nil
			}
		}
	}

	/// A line's first word that a merge joined onto the end of an earlier line.
	struct CarriedWord: Hashable {
		/// The line the merged word landed on.
		var line: Int
		/// The word as read on this line.
		var text: String
	}

	/// What reconciling does to one OCR line: its new words, and how well they align.
	struct LineEdit: Hashable {
		var words: [String] = []
		/// Sum of each unit's similarity: 1 for an exact match, 0 for a gap.
		var score = 0.0
		var units = 0
		/// Goes back at the start of this line if the line it merged into stays as read.
		var carried: CarriedWord?

		/// Average similarity; 0 for a line nothing landed on.
		var similarity: Double { units > 0 ? score / Double(units) : 0 }

		mutating func add(_ similarity: Double, units count: Int = 1) {
			score += similarity * Double(count)
			units += count
		}
	}

	// MARK: Entry points

	/// A capture's OCR lines for the PDF's text layer: reconciled with its
	/// rebuilt page when that page was made from these very lines, exactly as
	/// read otherwise. A line edited or deleted after the rebuild changes the
	/// fingerprint, and the newer edit wins over the older document.
	static func textLayer(_ lines: [RecognizedLine], page: RescrivaPage?) -> [RecognizedLine] {
		guard let page, page.sourceTextDigest == digest(of: lines) else { return lines }
		return reconcile(lines, with: readingText(of: page))
	}

	/// A stable fingerprint of a page's OCR text: the line count and FNV-1a
	/// over the lines' UTF-8, one line per row. It is stored with the rebuilt
	/// document, so it can't use `Hasher`, which changes every launch.
	static func digest(of lines: [RecognizedLine]) -> String {
		var hash: UInt64 = 0xcbf2_9ce4_8422_2325
		for byte in lines.map(\.text).joined(separator: "\n").utf8 {
			hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
		}
		return "\(lines.count)-" + String(hash, radix: 16)
	}

	/// The rebuilt page made from a capture: found by capture ID, or by
	/// position in documents saved before IDs were kept (only when the page
	/// counts agree); nil when no page clearly belongs to it.
	static func page(in document: RescrivaDocument, captureID: UUID?, index: Int, captureCount: Int) -> RescrivaPage? {
		guard let sourceIDs = document.sourceCaptureIDs else {
			return document.pages.count == captureCount ? document.pages[safe: index] : nil
		}
		guard let captureID, sourceIDs.count == document.pages.count,
			  let position = sourceIDs.firstIndex(of: captureID) else { return nil }
		return document.pages[safe: position]
	}

	/// The rebuilt page's text in reading order: headings, paragraphs, list
	/// items (without their markers), table cells, row by row, and a figure's
	/// words (the text read inside it, then its caption: both page text that
	/// moved into the figure).
	static func readingText(of page: RescrivaPage) -> [String] {
		page.blocks.flatMap { block -> [String] in
			switch block.content {
			case .heading(_, let runs), .paragraph(let runs, _):
				return [runs.plainText]
			case .list(_, let items):
				return items.map(\.runs.plainText)
			case .table(let rows):
				return rows.flatMap { $0.map(\.runs.plainText) }
			case .figure(_, let caption, let altText):
				return [altText, caption].compactMap { $0 }.filter { !$0.isEmpty }
			case .equation, .diagram:
				return []
			}
		}
	}

	/// The OCR lines with the rebuilt words written back onto them — boxes,
	/// confidences and alternatives unchanged. `text` is the rebuilt page in
	/// reading order. Lines that don't line up keep their OCR text, and so
	/// does every line of a page that doesn't.
	static func reconcile(_ lines: [RecognizedLine], with text: [String]) -> [RecognizedLine] {
		let ocr = lines.enumerated().flatMap { index, line in words(in: line.text).map { Word($0, line: index) } }
		let rebuilt = text.flatMap(words(in:)).map { Word($0, line: -1) }
		guard ocr.map(\.text) != rebuilt.map(\.text), let steps = align(ocr, rebuilt) else { return lines }
		let exact = steps.filter { isExactMatch($0, ocr: ocr, rebuilt: rebuilt) }.count
		guard Double(exact) >= Double(min(ocr.count, rebuilt.count)) * Tuning.pageMatchShare else { return lines }
		let edits = lineEdits(steps, ocr: ocr, rebuilt: rebuilt, lineCount: lines.count)
		return rewritten(lines, with: edits)
	}

	/// The cheapest alignment of OCR words onto rebuilt words, in reading
	/// order; nil when either side is empty or the table would pass the cap.
	static func align(_ ocr: [Word], _ rebuilt: [Word]) -> [Step]? {
		guard !ocr.isEmpty, !rebuilt.isEmpty, ocr.count * rebuilt.count <= Tuning.maxCells else { return nil }
		return AlignmentTable(ocr: ocr, rebuilt: rebuilt).steps()
	}

	/// Words separated by white space.
	static func words(in text: String) -> [String] {
		text.split(whereSeparator: \.isWhitespace).map(String.init)
	}

	// MARK: Word similarity

	/// 1 − edit distance ÷ the longer length, on folded scalars: 1 for the same
	/// word, 0 for nothing in common. Words past `maxWordLength` only match exactly.
	static func similarity(_ a: [Unicode.Scalar], _ b: [Unicode.Scalar]) -> Double {
		guard a != b else { return 1 }
		let longer = max(a.count, b.count)
		guard !a.isEmpty, !b.isEmpty, longer <= Tuning.maxWordLength else { return 0 }
		var previous = Array(0...b.count)
		var current = Array(repeating: 0, count: b.count + 1)
		for i in 1...a.count {
			current[0] = i
			for j in 1...b.count {
				let replace = previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
				current[j] = min(replace, previous[j] + 1, current[j - 1] + 1)
			}
			swap(&previous, &current)
		}
		return 1 - Double(previous[b.count]) / Double(longer)
	}

	/// False when the lengths alone keep two words below `threshold` (an edit
	/// distance is at least the length difference), so the scalars needn't be compared.
	private static func lengthsAllow(_ a: Int, _ b: Int, _ threshold: Double) -> Bool {
		Double(abs(a - b)) <= Double(max(a, b)) * (1 - threshold)
	}

	/// Cost of reading `word` as `target`: nothing when they're the same, less
	/// for a near miss than for a different word.
	private static func substitutionCost(_ word: Word, _ target: Word) -> Int {
		guard word.text != target.text else { return Cost.match }
		guard lengthsAllow(word.folded.count, target.folded.count, Tuning.similarWord) else { return Cost.different }
		return similarity(word.folded, target.folded) >= Tuning.similarWord ? Cost.similar : Cost.different
	}

	/// Cost of one word standing for two (`first` then `second`), as in a
	/// split or a merge; nil unless they start alike and join into it. Marks
	/// never join a word.
	private static func joinCost(_ single: Word, _ first: Word, _ second: Word) -> Int? {
		guard !first.isMark, !second.isMark, let start = single.folded.first, start == first.folded.first,
			  lengthsAllow(single.folded.count, first.folded.count + second.folded.count, Tuning.similarJoin) else { return nil }
		let joined = first.folded + second.folded
		guard joined != single.folded else { return Cost.exactJoin }
		return similarity(single.folded, joined) >= Tuning.similarJoin ? Cost.nearJoin : nil
	}

	// MARK: Lines

	/// True for a step that keeps a word exactly as read.
	private static func isExactMatch(_ step: Step?, ocr: [Word], rebuilt: [Word]) -> Bool {
		guard let step, case .keep(let o, let r) = step else { return false }
		return ocr[o].text == rebuilt[r].text
	}

	/// How sure a kept word is: 1 when unchanged, or for a fix wedged between
	/// two exact matches (anchored on both sides); otherwise how alike the
	/// two readings are.
	private static func keepScore(at index: Int, steps: [Step], ocr: [Word], rebuilt: [Word]) -> Double {
		guard case .keep(let o, let r) = steps[index] else { return 0 }
		guard ocr[o].text != rebuilt[r].text else { return 1 }
		let anchored = isExactMatch(steps[safe: index - 1], ocr: ocr, rebuilt: rebuilt)
			&& isExactMatch(steps[safe: index + 1], ocr: ocr, rebuilt: rebuilt)
		return anchored ? 1 : similarity(ocr[o].folded, rebuilt[r].folded)
	}

	/// True when the step at `index` sits between two exact matches.
	private static func isAnchored(_ index: Int, steps: [Step], ocr: [Word], rebuilt: [Word]) -> Bool {
		isExactMatch(steps[safe: index - 1], ocr: ocr, rebuilt: rebuilt)
			&& isExactMatch(steps[safe: index + 1], ocr: ocr, rebuilt: rebuilt)
	}

	/// Hands each step's words to an OCR line (see the file header, step 3).
	private static func lineEdits(_ steps: [Step], ocr: [Word], rebuilt: [Word], lineCount: Int) -> [LineEdit] {
		var edits = Array(repeating: LineEdit(), count: lineCount)
		let homes = insertionLines(steps, ocr: ocr)
		let moved = movedSteps(steps, ocr: ocr, rebuilt: rebuilt)
		for (index, step) in steps.enumerated() {
			switch step {
			case .keep(let o, let r):
				edits[ocr[o].line].words.append(rebuilt[r].text)
				edits[ocr[o].line].add(keepScore(at: index, steps: steps, ocr: ocr, rebuilt: rebuilt))
			case .split(let o, let r):
				edits[ocr[o].line].words += [rebuilt[r].text, rebuilt[r + 1].text]
				edits[ocr[o].line].add(similarity(ocr[o].folded, rebuilt[r].folded + rebuilt[r + 1].folded), units: 2)
			case .merge(let o, let r):
				let alike = similarity(ocr[o].folded + ocr[o + 1].folded, rebuilt[r].folded)
				edits[ocr[o].line].words.append(rebuilt[r].text)
				edits[ocr[o].line].add(alike)
				edits[ocr[o + 1].line].add(alike)
				if ocr[o + 1].line != ocr[o].line {
					edits[ocr[o + 1].line].carried = CarriedWord(line: ocr[o].line, text: ocr[o + 1].text)
				}
			case .delete(let o):
				// Marks and moved words stay as they are; any other deleted word counts against its
				// line, and goes only when exact matches hem it in.
				let kept = ocr[o].isMark || moved.contains(index)
				if kept || !isAnchored(index, steps: steps, ocr: ocr, rebuilt: rebuilt) {
					edits[ocr[o].line].words.append(ocr[o].text)
				}
				edits[ocr[o].line].add(kept ? 1 : 0)
			case .insert(let r):
				guard !moved.contains(index), let line = homes[index] else { continue }
				edits[line].words.append(rebuilt[r].text)
				edits[line].add(0)
			}
		}
		return edits
	}

	/// Steps that only move a word: a delete and an insert of the same text,
	/// paired in reading order. The word was read the same both times, in
	/// another order (columns, a sidebar, the document reader's regions), so
	/// it stays where the OCR put it and the insert is dropped.
	private static func movedSteps(_ steps: [Step], ocr: [Word], rebuilt: [Word]) -> Set<Int> {
		var deleted: [String: [Int]] = [:]
		var inserted: [String: [Int]] = [:]
		for (index, step) in steps.enumerated() {
			switch step {
			case .delete(let o):
				deleted[ocr[o].text, default: []].append(index)
			case .insert(let r):
				inserted[rebuilt[r].text, default: []].append(index)
			case .keep, .split, .merge:
				continue
			}
		}
		var moved = Set<Int>()
		for (text, deletes) in deleted {
			guard let inserts = inserted[text] else { continue }
			let pairs = min(deletes.count, inserts.count)
			moved.formUnion(deletes.prefix(pairs))
			moved.formUnion(inserts.prefix(pairs))
		}
		return moved
	}

	/// For each insert step, the line of its nearest aligned neighbour (the
	/// earlier one on a tie); nil for other steps, inserts in a run longer than
	/// `maxInsertRun`, or when nothing aligned.
	private static func insertionLines(_ steps: [Step], ocr: [Word]) -> [Int?] {
		let runs = insertRunLengths(steps)
		var before: [(step: Int, line: Int)?] = Array(repeating: nil, count: steps.count)
		var after = before
		var last: (step: Int, line: Int)?
		for (index, step) in steps.enumerated() {
			before[index] = last
			if let anchor = step.anchor { last = (index, ocr[anchor].line) }
		}
		last = nil
		for index in steps.indices.reversed() {
			after[index] = last
			if let anchor = steps[index].anchor { last = (index, ocr[anchor].line) }
		}
		return steps.indices.map { index -> Int? in
			guard case .insert = steps[index], runs[index] <= Tuning.maxInsertRun else { return nil }
			switch (before[index], after[index]) {
			case let (earlier?, later?):
				return index - earlier.step <= later.step - index ? earlier.line : later.line
			case let (earlier?, nil):
				return earlier.line
			case let (nil, later?):
				return later.line
			case (nil, nil):
				return nil
			}
		}
	}

	/// For each step, the length of the run of consecutive inserts it sits in;
	/// 0 for other steps.
	private static func insertRunLengths(_ steps: [Step]) -> [Int] {
		var lengths = Array(repeating: 0, count: steps.count)
		var run = 0
		for (index, step) in steps.enumerated() {
			guard case .insert = step else {
				run = 0
				continue
			}
			run += 1
			lengths[index] = run
		}
		// Backwards, each run's last count spreads over the whole run.
		for index in steps.indices.reversed() where lengths[index] > 0 {
			lengths[index] = max(lengths[index], lengths[safe: index + 1] ?? 0)
		}
		return lengths
	}

	/// Each line rewritten with its edit, in order. A word a merge took from
	/// the start of a line goes back on it when the line it merged into stays
	/// as read, so the word isn't lost from both.
	private static func rewritten(_ lines: [RecognizedLine], with edits: [LineEdit]) -> [RecognizedLine] {
		assert(lines.count == edits.count, "one edit per line")
		var result = lines
		for index in lines.indices {
			var edit = edits[index]
			// A merge only runs forward, so the earlier line is already settled.
			if let carried = edit.carried, carried.line < index, result[carried.line].text == lines[carried.line].text {
				edit.words.insert(carried.text, at: 0)
			}
			result[index] = rewritten(lines[index], with: edit)
		}
		return result
	}

	/// `line` with the edit's words, when they differ from what was read and
	/// align well enough; otherwise `line` untouched.
	private static func rewritten(_ line: RecognizedLine, with edit: LineEdit) -> RecognizedLine {
		guard !edit.words.isEmpty, edit.similarity > Tuning.lineSimilarity,
			  edit.words != words(in: line.text) else { return line }
		var fixed = line
		fixed.text = edit.words.joined(separator: " ")
		return fixed
	}

	// MARK: Alignment table

	/// The edit-distance table: for each cell (i, j), the cheapest way to turn
	/// the first i OCR words into the first j rebuilt words, and its last move.
	private struct AlignmentTable {
		enum Move: UInt8 {
			case keep, split, merge, delete, insert
		}

		let ocr: [Word]
		let rebuilt: [Word]
		private let width: Int
		private var cost: [Int]
		private var move: [Move]

		init(ocr: [Word], rebuilt: [Word]) {
			self.ocr = ocr
			self.rebuilt = rebuilt
			width = rebuilt.count + 1
			cost = Array(repeating: 0, count: (ocr.count + 1) * width)
			move = Array(repeating: .keep, count: (ocr.count + 1) * width)
			for j in 1..<width {
				cost[j] = j * Cost.gap
				move[j] = .insert
			}
			for i in 1..<(ocr.count + 1) {
				cost[i * width] = i * Cost.gap
				move[i * width] = .delete
				for j in 1..<width {
					let best = cheapest(i, j)
					cost[i * width + j] = best.cost
					move[i * width + j] = best.move
				}
			}
		}

		/// The cheapest last move into cell (i, j), both at least 1. Ties go
		/// to the earlier move in `Move`'s order.
		private func cheapest(_ i: Int, _ j: Int) -> (cost: Int, move: Move) {
			guard i > 0, j > 0 else { return (Int.max, .keep) }
			let word = ocr[i - 1]
			let target = rebuilt[j - 1]
			var best = (cost: cost[(i - 1) * width + j - 1] + TextLayerReconciler.substitutionCost(word, target), move: Move.keep)
			if j >= 2, let join = TextLayerReconciler.joinCost(word, rebuilt[j - 2], target) {
				let split = cost[(i - 1) * width + j - 2] + join
				if split < best.cost { best = (split, .split) }
			}
			if i >= 2, let join = TextLayerReconciler.joinCost(target, ocr[i - 2], word) {
				let merge = cost[(i - 2) * width + j - 1] + join
				if merge < best.cost { best = (merge, .merge) }
			}
			let delete = cost[(i - 1) * width + j] + Cost.gap
			if delete < best.cost { best = (delete, .delete) }
			let insert = cost[i * width + j - 1] + Cost.gap
			if insert < best.cost { best = (insert, .insert) }
			return best
		}

		/// The moves back from the last cell, in reading order.
		func steps() -> [Step] {
			var steps: [Step] = []
			var i = ocr.count
			var j = rebuilt.count
			// Every move consumes at least one word, so this many turns reach (0, 0).
			for _ in 0..<(ocr.count + rebuilt.count) {
				guard i > 0 || j > 0 else { break }
				switch move[i * width + j] {
				case .keep:
					steps.append(.keep(ocr: i - 1, rebuilt: j - 1))
					i -= 1
					j -= 1
				case .split:
					steps.append(.split(ocr: i - 1, rebuilt: j - 2))
					i -= 1
					j -= 2
				case .merge:
					steps.append(.merge(ocr: i - 2, rebuilt: j - 1))
					i -= 2
					j -= 1
				case .delete:
					steps.append(.delete(ocr: i - 1))
					i -= 1
				case .insert:
					steps.append(.insert(rebuilt: j - 1))
					j -= 1
				}
			}
			return steps.reversed()
		}
	}
}
