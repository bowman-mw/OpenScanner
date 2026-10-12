//
//  TextLayerReconcilerTests.swift
//  Rescriva (fork of Open Scanner)
//
//  Unit tests for carrying Review's fixes into the searchable PDF's text
//  layer: the word alignment, how its steps land on OCR lines, when a line or
//  a page is left as read, and how a capture finds its rebuilt page.
//

import CoreGraphics
import XCTest
@testable import scanner

final class TextLayerReconcilerTests: XCTestCase {

	// MARK: Fixtures

	/// OCR lines stacked down the page, each with its own box and readings.
	private func lines(_ texts: [String]) -> [RecognizedLine] {
		texts.enumerated().map { index, text in
			RecognizedLine(text: text, confidence: 0.5 + Float(index) / 100, alternatives: ["alt \(index)"],
						   box: CGRect(x: 0.1 + Double(index) / 100, y: 0.1 + Double(index) * 0.05, width: 0.6, height: 0.03))
		}
	}

	private func words(_ text: String, line: Int = 0) -> [TextLayerReconciler.Word] {
		TextLayerReconciler.words(in: text).map { TextLayerReconciler.Word($0, line: line) }
	}

	private func reconciled(_ texts: [String], with text: [String]) -> [String] {
		TextLayerReconciler.reconcile(lines(texts), with: text).map(\.text)
	}

	// MARK: Unchanged text

	func testUnchangedTextComesBackIdentical() {
		let read = lines(["The enzyme  becomes saturated", "and trial 3 looked odd"])
		// The rebuild joins the lines into one paragraph; the words are the same.
		XCTAssertEqual(TextLayerReconciler.reconcile(read, with: ["The enzyme becomes saturated and trial 3 looked odd"]), read)
		XCTAssertEqual(TextLayerReconciler.reconcile(read, with: []), read)
		XCTAssertEqual(TextLayerReconciler.reconcile([], with: ["Anything"]), [])
		XCTAssertEqual(TextLayerReconciler.textLayer(read, page: nil), read)
	}

	// MARK: Fixes

	func testOneCorrectedWordReachesItsLine() {
		let result = reconciled(["The enzyme becomes saturated", "and trial 3 looked anomolous", "so we will retry it"],
								with: ["The enzyme becomes saturated and trial 3 looked anomalous so we will retry it"])
		XCTAssertEqual(result, ["The enzyme becomes saturated", "and trial 3 looked anomalous", "so we will retry it"])
	}

	func testAFixBetweenExactMatchesIsTrustedEvenWhenUnalike() {
		// A typed fix shares nothing with what was read, but both neighbours match.
		let result = reconciled(["Results are below", "Mehtods", "We ran three trials"],
								with: ["Results are below", "Procedure", "We ran three trials"])
		XCTAssertEqual(result, ["Results are below", "Procedure", "We ran three trials"])
	}

	func testAWordSplitIntoTwo() {
		XCTAssertEqual(reconciled(["we keep a notebook of every run"], with: ["we keep a note book of every run"]),
					   ["we keep a note book of every run"])
		// At the start of a line, both halves stay on that line.
		XCTAssertEqual(reconciled(["results are in the", "notebook today"], with: ["results are in the note book today"]),
					   ["results are in the", "note book today"])
	}

	func testTwoWordsMergedIntoOne() {
		XCTAssertEqual(reconciled(["the data base grows each week", "and so do the backups"],
								  with: ["the database grows each week and so do the backups"]),
					   ["the database grows each week", "and so do the backups"])
		// A word hyphenated across two lines lands whole on the first.
		XCTAssertEqual(reconciled(["we keep a note-", "book of every run"], with: ["we keep a notebook of every run"]),
					   ["we keep a notebook", "of every run"])
		// When the first line stays as read, the second keeps its half, so the word isn't lost.
		XCTAssertEqual(reconciled(["Xq Zv note-", "book of every run in the lab today", "and more words to pad the page out"],
								  with: ["Alpha Beta notebook of every run in the lab today and more words to pad the page out"]),
					   ["Xq Zv note-", "book of every run in the lab today", "and more words to pad the page out"])
	}

	func testAnInsertedWordJoinsTheLineOfItsNearestNeighbour() {
		let read = ["the quick fox jumps", "over the lazy dog"]
		XCTAssertEqual(reconciled(read, with: ["the quick brown fox jumps over the lazy dog"]),
					   ["the quick brown fox jumps", "over the lazy dog"])
		// Equally near both lines: the earlier one.
		XCTAssertEqual(reconciled(read, with: ["the quick fox jumps high over the lazy dog"]),
					   ["the quick fox jumps high", "over the lazy dog"])
		// Before the first word: the only neighbour is the line after.
		XCTAssertEqual(reconciled(read, with: ["so the quick fox jumps over the lazy dog"]),
					   ["so the quick fox jumps", "over the lazy dog"])
	}

	func testADeletedWordIsRemoved() {
		XCTAssertEqual(reconciled(["we will will retry it", "after lunch"], with: ["we will retry it after lunch"]),
					   ["we will retry it", "after lunch"])
	}

	func testListMarksTheRebuildStripsStay() {
		let result = reconciled(["Shopping", "• Buy mlik", "1. Call Priya", "☐ Pay rent"],
								with: ["Shopping", "Buy milk", "Call Priya", "Pay rent"])
		XCTAssertEqual(result, ["Shopping", "• Buy milk", "1. Call Priya", "☐ Pay rent"])
	}

	// MARK: Doubt

	func testABadlyAlignedPageIsLeftAsIs() {
		let read = lines(["Quarterly budget review", "Marketing spend rose sharply"])
		XCTAssertEqual(TextLayerReconciler.reconcile(read, with: ["Photosynthesis converts light into chemical energy"]), read)
	}

	func testABadlyAlignedLineIsLeftAsIsWhileTheRestAreFixed() {
		// Diagram labels the rebuild absorbed, and a line it read as something else entirely.
		let result = reconciled(["The enzyme becomes saturated", "Input Process Output", "and trial 3 looked anomolous",
								 "Total units", "so we will retry it"],
								with: ["The enzyme becomes saturated and trial 3 looked anomalous", "Grand shown",
									   "so we will retry it"])
		XCTAssertEqual(result, ["The enzyme becomes saturated", "Input Process Output", "and trial 3 looked anomalous",
								"Total units", "so we will retry it"])
	}

	func testALongRunTheOCRNeverSawIsLeftOut() {
		// The rebuild read a passage the OCR lines lack: it has no box, and the line before keeps its fix.
		XCTAssertEqual(reconciled(["The enzyme becomes", "saturated once every", "site is ocupied"],
								  with: ["The enzyme becomes saturated once every site is occupied and then the rate stops rising"]),
					   ["The enzyme becomes", "saturated once every", "site is occupied"])
	}

	func testWordsReadInAnotherOrderStayPut() {
		// The document reader puts the heading's date first.
		XCTAssertEqual(reconciled(["Minutes 12 March 2024", "Attendees were present"],
								  with: ["12 March 2024", "Minutes", "Attendees were present"]),
					   ["Minutes 12 March 2024", "Attendees were present"])
		// Two columns the line OCR read straight across.
		let columns = ["Plants need light to grow Seeds were sown in May", "and water every day after the first frost"]
		XCTAssertEqual(reconciled(columns, with: ["Plants need light to grow and water every day",
												  "Seeds were sown in May after the first frost"]), columns)
		// A sidebar read between two lines of a paragraph, and after it by the rebuild, with a fix.
		XCTAssertEqual(reconciled(["The report covers the first", "Due Friday", "quarter resluts in detail"],
								  with: ["The report covers the first quarter results in detail", "Due Friday"]),
					   ["The report covers the first", "Due Friday", "quarter results in detail"])
	}

	func testWordsTheRebuildMissedStay() {
		// A caption the rebuild left out: its words aren't hemmed in by matches, so they aren't dropped.
		XCTAssertEqual(reconciled(["The enzyme becomes saturated Fig 2", "and trial 3 looked anomolous"],
								  with: ["The enzyme becomes saturated and trial 3 looked anomalous"]),
					   ["The enzyme becomes saturated Fig 2", "and trial 3 looked anomalous"])
	}

	func testALineThatAlignsOnlyHalfWayIsLeftAsIs() {
		// One word matches and one is dropped: an even split isn't enough to rewrite the line.
		XCTAssertEqual(reconciled(["alpha beta gamma delta", "epsilon xq", "zeta eta theta iota"],
								  with: ["alpha beta gamma delta epsilon zeta eta theta iota"]),
					   ["alpha beta gamma delta", "epsilon xq", "zeta eta theta iota"])
	}

	func testAnOversizedPageIsNotAligned() {
		let ocr = words(Array(repeating: "word", count: 1_001).joined(separator: " "))
		let rebuilt = words(Array(repeating: "word", count: 1_000).joined(separator: " "))
		XCTAssertNil(TextLayerReconciler.align(ocr, rebuilt))
		XCTAssertNil(TextLayerReconciler.align([], rebuilt))
	}

	// MARK: Lines and boxes

	func testMultiLineParagraphKeepsEachLinesOwnBox() {
		let read = lines(["Teh enzyme becomes", "saturated once every", "site is ocupied"])
		let result = TextLayerReconciler.reconcile(read, with: ["The enzyme becomes saturated once every site is occupied"])
		XCTAssertEqual(result.map(\.text), ["The enzyme becomes", "saturated once every", "site is occupied"])
		XCTAssertEqual(result.map(\.box), read.map(\.box))
		XCTAssertEqual(result.map(\.confidence), read.map(\.confidence))
		XCTAssertEqual(result.map(\.alternatives), read.map(\.alternatives))
	}

	// MARK: Alignment

	func testAlignmentSplitsAndMerges() {
		XCTAssertEqual(TextLayerReconciler.align(words("a notebook b"), words("a note book b")),
					   [.keep(ocr: 0, rebuilt: 0), .split(ocr: 1, rebuilt: 1), .keep(ocr: 2, rebuilt: 3)])
		XCTAssertEqual(TextLayerReconciler.align(words("the data base grows"), words("the database grows")),
					   [.keep(ocr: 0, rebuilt: 0), .merge(ocr: 1, rebuilt: 1), .keep(ocr: 3, rebuilt: 2)])
		XCTAssertEqual(TextLayerReconciler.align(words("a b"), words("a x b")),
					   [.keep(ocr: 0, rebuilt: 0), .insert(rebuilt: 1), .keep(ocr: 1, rebuilt: 2)])
	}

	func testWordSimilarity() {
		func folded(_ text: String) -> [Unicode.Scalar] { TextLayerReconciler.Word(text, line: 0).folded }
		XCTAssertEqual(TextLayerReconciler.similarity(folded("Word"), folded("word")), 1)
		XCTAssertEqual(TextLayerReconciler.similarity(folded("anomolous"), folded("anomalous")), 8.0 / 9, accuracy: 1e-9)
		XCTAssertEqual(TextLayerReconciler.similarity(folded("cat"), folded("dog")), 0)
		XCTAssertEqual(TextLayerReconciler.similarity(folded(""), folded("dog")), 0)
	}

	// MARK: The rebuilt page

	func testReadingTextSkipsDiagramsAndEquationsButKeepsFigureWords() {
		let node = Diagram.Node(id: "a", label: "Input", shape: .rectangle,
								box: NormalizedBox(x: 0, y: 0, width: 0.3, height: 0.2), stroke: RGBColor(hex: 0x333333))
		var page = RescrivaPage(blocks: [
			RescrivaBlock(content: .heading(level: 1, runs: [RescrivaRun(text: "Lab notes")])),
			RescrivaBlock(content: .paragraph(runs: [RescrivaRun(text: "The enzyme "), RescrivaRun(text: "saturated")], alignment: .leading)),
			RescrivaBlock(content: .equation(latex: "E = mc^2", linear: "E = mc^2", display: true)),
			RescrivaBlock(content: .list(style: .bullet, items: [ListItem(runs: [RescrivaRun(text: "Buy milk")]),
															  ListItem(runs: [RescrivaRun(text: "Call Priya")])])),
			RescrivaBlock(content: .figure(assetID: nil, caption: "Figure 1", altText: "Q1 Q2")),
			RescrivaBlock(content: .table(rows: [[TableCell(runs: [RescrivaRun(text: "Trial")]), TableCell(runs: [RescrivaRun(text: "Rate")])],
											  [TableCell(runs: [RescrivaRun(text: "1")]), TableCell(runs: [RescrivaRun(text: "0.42")])]])),
			RescrivaBlock(content: .diagram(Diagram(nodes: [node], edges: []))),
		])
		XCTAssertEqual(TextLayerReconciler.readingText(of: page),
					   ["Lab notes", "The enzyme saturated", "Buy milk", "Call Priya", "Q1 Q2", "Figure 1", "Trial", "Rate", "1", "0.42"],
					   "a figure's words (read inside it, then its caption) were page text")
		let read = lines(["Lab notes", "The enzyme saturaled"])
		page.sourceTextDigest = TextLayerReconciler.digest(of: read)
		XCTAssertEqual(TextLayerReconciler.textLayer(read, page: page).map(\.text), ["Lab notes", "The enzyme saturated"])
	}

	func testAPageRebuiltFromOtherLinesIsLeftAsIs() {
		// Rebuilt while the line read "Teh quick fox"; the user has fixed it in Recognized text since.
		var page = RescrivaPage(blocks: [RescrivaBlock(content: .paragraph(runs: [RescrivaRun(text: "Teh quick fox")], alignment: .leading))])
		page.sourceTextDigest = TextLayerReconciler.digest(of: lines(["Teh quick fox"]))
		let edited = lines(["The quick fox"])
		XCTAssertEqual(TextLayerReconciler.textLayer(edited, page: page), edited)
		// So does a deleted line, whose words would otherwise come back from the document.
		page.blocks.append(RescrivaBlock(content: .paragraph(runs: [RescrivaRun(text: "jumps xq")], alignment: .leading)))
		page.sourceTextDigest = TextLayerReconciler.digest(of: lines(["The quick fox", "jumps xq"]))
		XCTAssertEqual(TextLayerReconciler.textLayer(edited, page: page), edited)
		// Documents rebuilt before fingerprints were kept: the OCR text as read.
		page.sourceTextDigest = nil
		XCTAssertEqual(TextLayerReconciler.textLayer(edited, page: page), edited)
	}

	func testTheFingerprintFollowsTheLinesText() {
		let digest = TextLayerReconciler.digest(of: lines(["a b", "c"]))
		XCTAssertEqual(digest, TextLayerReconciler.digest(of: lines(["a b", "c"])))
		XCTAssertNotEqual(digest, TextLayerReconciler.digest(of: lines(["a", "b c"])))
		XCTAssertNotEqual(digest, TextLayerReconciler.digest(of: lines(["a b", "C"])))
		XCTAssertNotEqual(TextLayerReconciler.digest(of: []), TextLayerReconciler.digest(of: lines([""])))
		// Stable across launches: it's stored with the document.
		XCTAssertEqual(TextLayerReconciler.digest(of: []), "0-cbf29ce484222325")
	}

	func testACaptureFindsItsRebuiltPage() {
		let pages = [RescrivaPage(), RescrivaPage()]
		let ids = [UUID(), UUID()]
		var document = RescrivaDocument(title: "Notes", pages: pages, sourceCaptureIDs: ids)
		// By capture ID, wherever the capture now sits.
		XCTAssertEqual(TextLayerReconciler.page(in: document, captureID: ids[1], index: 0, captureCount: 2)?.id, pages[1].id)
		XCTAssertNil(TextLayerReconciler.page(in: document, captureID: UUID(), index: 0, captureCount: 2))
		XCTAssertNil(TextLayerReconciler.page(in: document, captureID: nil, index: 0, captureCount: 2))
		// Older documents without IDs: by position, only when the page counts agree.
		document.sourceCaptureIDs = nil
		XCTAssertEqual(TextLayerReconciler.page(in: document, captureID: ids[0], index: 1, captureCount: 2)?.id, pages[1].id)
		XCTAssertNil(TextLayerReconciler.page(in: document, captureID: ids[0], index: 1, captureCount: 3))
	}
}
