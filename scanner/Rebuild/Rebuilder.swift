//
//  Rebuilder.swift
//  Folio (fork of Open Scanner)
//
//  Turns a scan's pages into a FolioDocument, on the phone:
//    tier 1 — Vision's document reader (iOS 26) for paragraphs, lists and
//             tables, plus the plan's heuristics (line height → heading,
//             leading dashes → bullets, boxes → checkboxes);
//    tier 2 — Apple Intelligence re-ranks the readings of uncertain words on
//             Smart-tier iPhones;
//    tier 3 — bundled Core ML models for diagrams and equations are not
//             shipped yet, so those regions stay in the page image.
//  Uncertain words become flags for the review screen.
//

import Foundation
import CoreData
import UIKit
import Vision

/// The steps the Rebuilding screen shows.
enum RebuildStage: Int, CaseIterable, Comparable {
	case reading, structure, ordering, checking

	static func < (lhs: RebuildStage, rhs: RebuildStage) -> Bool { lhs.rawValue < rhs.rawValue }

	/// Stages for this tier and document, in order.
	static func stages(for tier: DeviceTier, document: FolioDocument?) -> [RebuildStage] {
		tier == .smart ? [.reading, .structure, .ordering, .checking] : [.reading, .structure, .ordering]
	}

	/// Step label; mentions the equation and diagram when the document has them.
	func label(for document: FolioDocument?) -> String {
		let blocks = document?.pages.flatMap(\.blocks) ?? []
		let hasEquation = blocks.contains { if case .equation = $0.content { return true }; return false }
		let hasDiagram = blocks.contains { if case .diagram = $0.content { return true }; return false }
		switch self {
		case .reading:
			return String(localized: "Reading every word")
		case .structure:
			return hasEquation ? String(localized: "Finding headings, lists and the equation") : String(localized: "Finding headings, lists and tables")
		case .ordering:
			return hasDiagram ? String(localized: "Rebuilding the diagram as shapes") : String(localized: "Putting everything in reading order")
		case .checking:
			return String(localized: "Double-checking with Apple Intelligence")
		}
	}
}

/// Builds and caches the rebuilt document for a scan.
@MainActor
struct Rebuilder {
	let tier: DeviceTier

	/// Returns the scan's document, rebuilding only when its pages changed
	/// since the last rebuild. `progress` is called as each stage starts.
	func document(for scan: Scan, progress: @escaping @MainActor (RebuildStage) -> Void) async -> FolioDocument {
		let captureIDs = scan.capturesArray.compactMap(\.id)
		if let existing = scan.rebuiltDocument, existing.sourceCaptureIDs == captureIDs {
			for stage in RebuildStage.stages(for: tier, document: existing) {
				progress(stage)
			}
			return existing
		}

		progress(.reading)
		await recognizeMissingText(in: scan)
		let pages = scan.capturesArray.map { capture in
			PageSnapshot(imageData: capture.imageData, lines: capture.recognizedItemsArray.map(\.recognizedLine),
						 aspect: Double(capture.thumbnail?.aspectRatio ?? 0.75))
		}
		let source = scan.pageSource ?? .typed
		let output = scan.output

		progress(.structure)
		var builtPages: [FolioPage] = []
		for page in pages {
			builtPages.append(await Self.buildPage(page, source: source, output: output))
		}

		progress(.ordering)
		var document = Self.refineWordFlags(FolioDocument(title: scan.displayTitle, pages: builtPages, sourceCaptureIDs: captureIDs))

		if tier == .smart {
			progress(.checking)
			document = await AppleIntelligence.rerankFlags(in: document)
		}

		scan.rebuiltDocument = document
		scan.lastUpdate = Date()
		scan.managedObjectContext?.saveQuietly()
		return document
	}

	/// Runs OCR on pages that don't have text yet (and aren't already being read).
	private func recognizeMissingText(in scan: Scan) async {
		for capture in scan.capturesArray where capture.recognizedItemsArray.isEmpty && !RecognitionTracker.shared.isReading(capture) {
			guard let image = capture.image else { continue }
			await PageOCR.process(capture, image: image)
		}
		while scan.capturesArray.contains(where: { RecognitionTracker.shared.isReading($0) }) {
			try? await Task.sleep(for: .milliseconds(150))
		}
	}

	/// What the rebuild needs from one page, copied off Core Data.
	struct PageSnapshot: Sendable {
		var imageData: Data?
		var lines: [RecognizedLine]
		var aspect: Double
	}

	/// Builds one page: Vision's document reader when available, heuristics otherwise.
	nonisolated static func buildPage(_ page: PageSnapshot, source: PageSource, output: OutputKind) async -> FolioPage {
		let size: PageSize = page.aspect > 1
			? PageSize(width: 960, height: 960 / page.aspect)
			: PageSize(width: 612, height: 612 / max(page.aspect, 0.2))
		var blocks: [FolioBlock] = []
		if #available(iOS 26.0, *), let data = page.imageData, let image = UIImage(data: data)?.cgImage {
			blocks = (try? await documentBlocks(image)) ?? []
		}
		if blocks.isEmpty {
			blocks = heuristicBlocks(page.lines)
		}
		return FolioPage(source: source, size: size, blocks: blocks)
	}

	// MARK: Tier 1 — Vision document reader

	@available(iOS 26.0, *)
	nonisolated static func documentBlocks(_ image: CGImage) async throws -> [FolioBlock] {
		var request = RecognizeDocumentsRequest()
		request.textRecognitionOptions.maximumCandidateCount = 3
		request.textRecognitionOptions.useLanguageCorrection = true
		guard let document = try await request.perform(on: image).first?.document else { return [] }

		var placed: [(box: NormalizedBox, block: FolioBlock)] = []
		let medianLine = median(document.paragraphs.flatMap(\.lines).map { Double(box($0.boundingRegion).height) })

		for table in document.tables {
			let rows: [[TableCell]] = table.rows.enumerated().map { rowIndex, row in
				var seenColumns = Set<Int>()
				return row.compactMap { cell in
					// Vision repeats a merged cell in every slot it covers; keep it once, where it starts.
					guard cell.rowRange.lowerBound == rowIndex, seenColumns.insert(cell.columnRange.lowerBound).inserted else { return nil }
					return TableCell(runs: [FolioRun(text: cell.content.text.transcript)],
									 rowSpan: cell.rowRange.count, columnSpan: cell.columnRange.count)
				}
			}
			let frame = box(table.boundingRegion)
			placed.append((frame, FolioBlock(content: .table(rows: rows.filter { !$0.isEmpty }), box: frame, provenance: Provenance(engine: "vision", confidence: 1))))
		}

		for list in document.lists {
			let frame = box(list.boundingRegion)
			guard !placed.contains(where: { contains($0.box, frame) }) else { continue }
			var style: ListStyle = .bullet
			var items: [ListItem] = []
			for item in list.items {
				var text = item.itemString
				var checked: Bool?
				if let mark = checkboxMark(item.markerString + text) {
					style = .checkbox
					checked = mark.checked
					text = mark.remainder
				} else if let marker = item.markerType {
					switch marker {
					case .bullet, .hyphen: style = .bullet
					default: style = .ordered
					}
				}
				items.append(ListItem(runs: runs(for: item.content.text.lines, fallback: text), checked: checked))
			}
			placed.append((frame, FolioBlock(content: .list(style: style, items: items), box: frame, provenance: Provenance(engine: "vision", confidence: 1))))
		}

		if let title = document.title {
			let frame = box(title.boundingRegion)
			placed.append((frame, FolioBlock(content: .heading(level: 1, runs: runs(for: title.lines, fallback: title.transcript)), box: frame, provenance: Provenance(engine: "vision", confidence: 1))))
		}

		for paragraph in document.paragraphs {
			let frame = box(paragraph.boundingRegion)
			if placed.contains(where: { contains($0.box, frame) }) { continue }
			let lineHeight = paragraph.lines.isEmpty ? frame.height : frame.height / Double(paragraph.lines.count)
			let paragraphRuns = runs(for: paragraph.lines, fallback: paragraph.transcript)
			let content: BlockContent
			if let mark = checkboxMark(paragraph.transcript) {
				content = .list(style: .checkbox, items: [ListItem(runs: [FolioRun(text: mark.remainder)], checked: mark.checked)])
			} else if paragraph.lines.count == 1, medianLine > 0, lineHeight > medianLine * 1.35, paragraph.transcript.count < 80 {
				content = .heading(level: 2, runs: paragraphRuns)
			} else {
				content = .paragraph(runs: paragraphRuns, alignment: alignment(paragraph.textAlignment))
			}
			placed.append((frame, FolioBlock(content: content, box: frame, provenance: Provenance(engine: "vision", confidence: 1))))
		}

		return mergeAdjacentChecklists(placed.sorted { ($0.box.y, $0.box.x) < ($1.box.y, $1.box.x) }.map(\.block))
	}

	/// Runs for recognized lines, splitting out uncertain words as flags.
	@available(iOS 26.0, *)
	nonisolated static func runs(for lines: [RecognizedTextObservation], fallback: String) -> [FolioRun] {
		guard !lines.isEmpty else { return [FolioRun(text: fallback)] }
		var result: [FolioRun] = []
		for (index, observation) in lines.enumerated() {
			let candidates = observation.topCandidates(3)
			guard let top = candidates.first else { continue }
			let line = RecognizedLine(text: top.string, confidence: top.confidence,
									  alternatives: candidates.dropFirst().map(\.string), box: .zero)
			result.append(contentsOf: flaggedRuns(for: line))
			if index < lines.count - 1 {
				result.append(FolioRun(text: " "))
			}
		}
		return coalesce(result)
	}

	// MARK: Heuristics (no document reader)

	/// Groups recognized lines into blocks by position and leading markers.
	nonisolated static func heuristicBlocks(_ lines: [RecognizedLine]) -> [FolioBlock] {
		let sorted = lines.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }.sorted { ($0.box.minY, $0.box.minX) < ($1.box.minY, $1.box.minX) }
		let medianHeight = median(sorted.map { Double($0.box.height) })
		var blocks: [FolioBlock] = []
		var paragraph: [RecognizedLine] = []

		func flushParagraph() {
			guard let first = paragraph.first else { return }
			let frame = union(paragraph.map(\.box))
			var runs: [FolioRun] = []
			for (index, line) in paragraph.enumerated() {
				runs.append(contentsOf: flaggedRuns(for: line))
				if index < paragraph.count - 1 { runs.append(FolioRun(text: " ")) }
			}
			let isHeading = paragraph.count == 1 && medianHeight > 0 && Double(first.box.height) > medianHeight * 1.35 && first.text.count < 80
			let content: BlockContent = isHeading
				? .heading(level: blocks.isEmpty ? 1 : 2, runs: coalesce(runs))
				: .paragraph(runs: coalesce(runs), alignment: .leading)
			blocks.append(FolioBlock(content: content, box: frame, provenance: Provenance(engine: "heuristics", confidence: Double(first.confidence))))
			paragraph = []
		}

		for line in sorted {
			if let item = listItem(line) {
				flushParagraph()
				let frame = NormalizedBox(line.box)
				if case .list(let style, var items) = blocks.last?.content, style == item.style {
					items.append(item.item)
					blocks[blocks.count - 1].content = .list(style: style, items: items)
				} else {
					blocks.append(FolioBlock(content: .list(style: item.style, items: [item.item]), box: frame, provenance: Provenance(engine: "heuristics", confidence: Double(line.confidence))))
				}
				continue
			}
			if let previous = paragraph.last {
				let gap = line.box.minY - previous.box.maxY
				let aligned = abs(line.box.minX - paragraph[0].box.minX) < 0.04
				let similar = abs(line.box.height - previous.box.height) < max(line.box.height, previous.box.height) * 0.35
				if gap > previous.box.height * 0.9 || !aligned || !similar {
					flushParagraph()
				}
			}
			paragraph.append(line)
		}
		flushParagraph()
		return blocks
	}

	private nonisolated static func listItem(_ line: RecognizedLine) -> (style: ListStyle, item: ListItem)? {
		let text = line.text.trimmingCharacters(in: .whitespaces)
		if let mark = checkboxMark(text) {
			return (.checkbox, ListItem(runs: flaggedRuns(for: RecognizedLine(text: mark.remainder, confidence: line.confidence, alternatives: [], box: line.box)), checked: mark.checked))
		}
		for bullet in ["• ", "- ", "– ", "* ", "· ", "‣ "] where text.hasPrefix(bullet) {
			let rest = String(text.dropFirst(bullet.count))
			return (.bullet, ListItem(runs: [FolioRun(text: rest)]))
		}
		if let match = text.firstMatch(of: /^(\d{1,2})[.)]\s+(.+)$/) {
			return (.ordered, ListItem(runs: [FolioRun(text: String(match.2))]))
		}
		return nil
	}

	// MARK: Flags

	/// Splits a line into runs, flagging the one word Vision's alternatives
	/// disagree on when its confidence is low.
	nonisolated static func flaggedRuns(for line: RecognizedLine) -> [FolioRun] {
		guard line.confidence < 0.6, let flag = wordFlag(for: line) else {
			return [FolioRun(text: line.text)]
		}
		let words = line.text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
		var runs: [FolioRun] = []
		let before = words[..<flag.index].joined(separator: " ")
		let after = words[(flag.index + 1)...].joined(separator: " ")
		if !before.isEmpty { runs.append(FolioRun(text: before + " ")) }
		let options = flag.options.map { FolioFlag.Option(label: $0) } + [FolioFlag.Option(label: flag.word, note: String(localized: "keep as read"))]
		runs.append(FolioRun(text: flag.word, flag: FolioFlag(kind: .word, title: String(localized: "Did you mean…"),
															  detail: String(localized: "Vision wasn’t sure about this word"),
															  read: flag.word, options: options)))
		if !after.isEmpty { runs.append(FolioRun(text: " " + after)) }
		return runs
	}

	/// The single word where the alternatives differ from the top reading.
	nonisolated static func wordFlag(for line: RecognizedLine) -> (index: Int, word: String, options: [String])? {
		let words = line.text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
		var index: Int?
		var options: [String] = []
		for alternative in line.alternatives {
			let altWords = alternative.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
			guard altWords.count == words.count else { continue }
			let differing = zip(words, altWords).enumerated().filter { $0.element.0 != $0.element.1 }
			guard differing.count == 1, let diff = differing.first else { continue }
			if index == nil { index = diff.offset }
			if diff.offset == index, !options.contains(diff.element.1) { options.append(diff.element.1) }
		}
		guard let index, !options.isEmpty else { return nil }
		return (index, words[index], options)
	}

	/// A correctly spelled reading is only worth a question when Vision also
	/// considered another real word; misspelled alternatives are noise. Runs on
	/// the main actor because the spelling checker lives there.
	static func refineWordFlags(_ document: FolioDocument) -> FolioDocument {
		var refined = document
		for pageIndex in refined.pages.indices {
			for blockIndex in refined.pages[pageIndex].blocks.indices {
				refined.pages[pageIndex].blocks[blockIndex].content.mapRuns { runs in
					runs.map { run in
						guard var flag = run.flag, flag.kind == .word, flag.resolution == nil else { return run }
						var run = run
						let keep = flag.options.first { $0.label == flag.read }
						let alternatives = flag.options.map(\.label).filter { $0 != flag.read }
						let realWords = alternatives.filter(SpellCheck.isWord)
						let ordered: [String]
						if SpellCheck.isWord(flag.read) {
							guard !realWords.isEmpty else {
								run.flag = nil
								return run
							}
							ordered = realWords
						} else {
							ordered = realWords + alternatives.filter { !realWords.contains($0) }
						}
						flag.options = ordered.map { FolioFlag.Option(label: $0) } + (keep.map { [$0] } ?? [])
						run.flag = flag
						return run
					}
				}
			}
		}
		return refined
	}

	// MARK: Geometry helpers

	@available(iOS 26.0, *)
	nonisolated static func box(_ region: NormalizedRegion) -> NormalizedBox {
		let rect = region.normalizedPath.boundingBox
		return NormalizedBox(x: rect.minX, y: 1 - rect.maxY, width: rect.width, height: rect.height)
	}

	@available(iOS 26.0, *)
	nonisolated static func alignment(_ value: DocumentObservation.Container.Text.Alignment?) -> TextAlignment {
		switch value {
		case .center: return .center
		case .trailing: return .trailing
		default: return .leading
		}
	}

	nonisolated static func contains(_ outer: NormalizedBox, _ inner: NormalizedBox) -> Bool {
		let slack = 0.01
		return inner.x >= outer.x - slack && inner.y >= outer.y - slack
			&& inner.x + inner.width <= outer.x + outer.width + slack
			&& inner.y + inner.height <= outer.y + outer.height + slack
	}

	nonisolated static func union(_ rects: [CGRect]) -> NormalizedBox {
		let rect = rects.dropFirst().reduce(rects.first ?? .zero) { $0.union($1) }
		return NormalizedBox(rect)
	}

	nonisolated static func median(_ values: [Double]) -> Double {
		let sorted = values.filter { $0 > 0 }.sorted()
		guard !sorted.isEmpty else { return 0 }
		return sorted[sorted.count / 2]
	}

	/// Leading checkbox glyphs: ☐ □ [ ] (open) and ☑ ☒ ✓ [x] (checked).
	nonisolated static func checkboxMark(_ text: String) -> (checked: Bool, remainder: String)? {
		let trimmed = text.trimmingCharacters(in: .whitespaces)
		for (mark, checked) in [("☐", false), ("□", false), ("[ ]", false), ("☑", true), ("☒", true), ("✓", true), ("[x]", true), ("[X]", true)] where trimmed.hasPrefix(mark) {
			return (checked, String(trimmed.dropFirst(mark.count)).trimmingCharacters(in: .whitespaces))
		}
		return nil
	}

	/// Joins adjacent unflagged runs with identical styling.
	nonisolated static func coalesce(_ runs: [FolioRun]) -> [FolioRun] {
		var result: [FolioRun] = []
		for run in runs {
			if var last = result.last, last.flag == nil, run.flag == nil,
			   last.bold == run.bold, last.italic == run.italic, last.underline == run.underline {
				last.text += run.text
				result[result.count - 1] = last
			} else {
				result.append(run)
			}
		}
		return result
	}

	/// Consecutive one-item checkbox lists become one list.
	nonisolated static func mergeAdjacentChecklists(_ blocks: [FolioBlock]) -> [FolioBlock] {
		var result: [FolioBlock] = []
		for block in blocks {
			if case .list(.checkbox, let items) = block.content, case .list(.checkbox, let previous) = result.last?.content {
				result[result.count - 1].content = .list(style: .checkbox, items: previous + items)
			} else {
				result.append(block)
			}
		}
		return result
	}
}

/// Spelling check for flag candidates, in the user's language.
@MainActor
enum SpellCheck {
	static func isWord(_ token: String) -> Bool {
		let word = token.trimmingCharacters(in: .punctuationCharacters.union(.symbols))
		guard word.contains(where: \.isLetter) else { return true }
		// Acronyms and codes (API, Q3, v2) aren't dictionary words but aren't misreads either.
		if word.count <= 5, word == word.uppercased() || word.contains(where: \.isNumber) { return true }
		let checker = UITextChecker()
		let language = Locale.preferredLanguages.first.map { String($0.prefix(2)) } ?? "en"
		let available = UITextChecker.availableLanguages
		let code = available.first { $0.hasPrefix(language) } ?? "en_US"
		let range = checker.rangeOfMisspelledWord(in: word, range: NSRange(location: 0, length: (word as NSString).length),
												  startingAt: 0, wrap: false, language: code)
		return range.location == NSNotFound
	}
}

extension NormalizedBox {
	init(_ rect: CGRect) {
		self.init(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
	}
}
