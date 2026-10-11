//
//  ReadingOrderTests.swift
//  Folio (fork of Open Scanner)
//
//  Column-aware reading order: two columns under a full-width title, a
//  sidebar, a figure inside one column, three columns, a picture spanning
//  both columns, and what keeps its order (one column, a form, a table,
//  overlapping boxes); then the heuristic and document-reader paths and the
//  pass that puts pictures among the blocks.
//

import CoreGraphics
import XCTest
@testable import scanner

final class ReadingOrderTests: XCTestCase {

	/// Median line height used throughout (a share of the page's height).
	private let line = 0.015
	private let aspect = 0.75

	// MARK: Columns

	func testTwoColumnsReadDownEachColumnAfterAFullWidthTitle() throws {
		let title = CGRect(x: 0.1, y: 0.05, width: 0.8, height: 0.03)
		// Baselines line up across the gutter, as typeset columns do.
		let left = lines(x: 0.1...0.48, from: 0.12, count: 20)
		let right = lines(x: 0.52...0.9, from: 0.12, count: 20)
		let order = try XCTUnwrap(ReadingOrder.order([title] + left + right, lineHeight: line, aspect: aspect))
		XCTAssertEqual(order, [0] + Array(1...20) + Array(21...40))
	}

	func testASidebarReadsAfterTheMainColumn() throws {
		let main = lines(x: 0.08...0.65, from: 0.1, count: 40)
		let sidebar = lines(x: 0.7...0.92, from: 0.31, count: 14)
		let order = try XCTUnwrap(ReadingOrder.order(main + sidebar, lineHeight: line, aspect: aspect))
		XCTAssertEqual(order, Array(0..<54))
	}

	func testAFigureInsideOneColumnStaysInThatColumn() throws {
		let boxes = [
			CGRect(x: 0.1, y: 0.05, width: 0.8, height: 0.04),	// 0 title
			CGRect(x: 0.1, y: 0.12, width: 0.38, height: 0.18),	// 1 left, top
			CGRect(x: 0.52, y: 0.12, width: 0.38, height: 0.35),	// 2 right, top
			CGRect(x: 0.12, y: 0.33, width: 0.34, height: 0.2),	// 3 figure, left
			CGRect(x: 0.52, y: 0.5, width: 0.38, height: 0.36),	// 4 right, bottom
			CGRect(x: 0.1, y: 0.56, width: 0.38, height: 0.3),	// 5 left, bottom
		]
		XCTAssertEqual(ReadingOrder.order(boxes, lineHeight: line, aspect: aspect), [0, 1, 3, 5, 2, 4])
	}

	func testThreeColumnsReadLeftToRight() throws {
		let boxes = [
			CGRect(x: 0.05, y: 0.1, width: 0.26, height: 0.3),	// 0 first column
			CGRect(x: 0.36, y: 0.1, width: 0.27, height: 0.5),	// 1 second
			CGRect(x: 0.68, y: 0.12, width: 0.27, height: 0.7),	// 2 third
			CGRect(x: 0.05, y: 0.45, width: 0.26, height: 0.4),	// 3 first
			CGRect(x: 0.36, y: 0.65, width: 0.27, height: 0.2),	// 4 second
		]
		XCTAssertEqual(ReadingOrder.order(boxes, lineHeight: line, aspect: aspect), [0, 3, 1, 4, 2])
	}

	func testAPictureSpanningBothColumnsReadsBetweenTheStretchesAboveAndBelowIt() throws {
		let boxes = [
			CGRect(x: 0.1, y: 0.05, width: 0.8, height: 0.04),	// 0 title
			CGRect(x: 0.1, y: 0.12, width: 0.38, height: 0.25),	// 1 left, above
			CGRect(x: 0.52, y: 0.12, width: 0.38, height: 0.2),	// 2 right, above
			CGRect(x: 0.1, y: 0.4, width: 0.8, height: 0.2),	// 3 picture across both
			CGRect(x: 0.1, y: 0.63, width: 0.38, height: 0.3),	// 4 left, below
			CGRect(x: 0.52, y: 0.63, width: 0.38, height: 0.25),	// 5 right, below
		]
		XCTAssertEqual(ReadingOrder.order(boxes, lineHeight: line, aspect: aspect), [0, 1, 2, 3, 4, 5],
					   "the stretches above and below read left then right, around the picture")
		// Moved so that position alone would read across: the right column starts higher.
		var shifted = boxes
		shifted[2].origin.y = 0.11
		shifted[5].origin.y = 0.62
		XCTAssertEqual(ReadingOrder.order(shifted, lineHeight: line, aspect: aspect), [0, 1, 2, 3, 4, 5])
		// A spanning picture that shares its band with column text can't be cut out cleanly.
		var tangled = boxes
		tangled[3] = CGRect(x: 0.1, y: 0.33, width: 0.8, height: 0.2)
		XCTAssertNil(ReadingOrder.order(tangled, lineHeight: line, aspect: aspect))
	}

	// MARK: Keeping the order

	func testASingleColumnKeepsItsOrder() {
		let title = CGRect(x: 0.1, y: 0.05, width: 0.6, height: 0.03)
		var boxes = [title] + lines(x: 0.1...0.9, from: 0.12, count: 30)
		// Short last lines of paragraphs and a right-aligned page number don't make columns.
		boxes[10].size.width = 0.2
		boxes[20].size.width = 0.15
		boxes.append(CGRect(x: 0.85, y: 0.95, width: 0.05, height: line))
		XCTAssertNil(ReadingOrder.order(boxes, lineHeight: line, aspect: aspect))
	}

	func testAFormOrATableReadsAcrossNotDown() {
		// Labels and values line up row by row; the labels are short.
		let labels = lines(x: 0.1...0.22, from: 0.1, count: 10, step: 0.04)
		let values = lines(x: 0.3...0.6, from: 0.1, count: 10, step: 0.04)
		XCTAssertNil(ReadingOrder.order(labels + values, lineHeight: line, aspect: aspect), "a form")
		let cells = (0..<3).flatMap { column in
			lines(x: (0.1 + Double(column) * 0.3)...(0.25 + Double(column) * 0.3), from: 0.2, count: 6, step: 0.03)
		}
		XCTAssertNil(ReadingOrder.order(cells, lineHeight: line, aspect: aspect), "a table")
	}

	func testLabelsBesideTheEntriesTheyHeadReadAcrossNotDown() {
		// A CV or an agenda as the document reader gives it: a one-line date beside each three-line
		// entry, starting level with it.
		let tops = (0..<6).map { 0.1 + Double($0) * 0.065 }
		let dates = tops.map { CGRect(x: 0.1, y: $0, width: 0.15, height: line) }
		let entries = tops.map { CGRect(x: 0.32, y: $0, width: 0.58, height: 3 * line) }
		XCTAssertNil(ReadingOrder.order(dates + entries, lineHeight: line, aspect: aspect), "short labels")
		// The same as recognized lines, the labels as wide as prose ("Jan 2019 – Present").
		let longDates = tops.map { CGRect(x: 0.1, y: $0, width: 0.3, height: line) }
		let entryLines = tops.flatMap { lines(x: 0.45...0.9, from: $0, count: 3) }
		XCTAssertNil(ReadingOrder.order(longDates + entryLines, lineHeight: line, aspect: aspect), "wide labels")
		// Columns of prose that end at different heights still read down each column.
		let columns = lines(x: 0.1...0.48, from: 0.12, count: 30) + lines(x: 0.52...0.9, from: 0.12, count: 12)
		XCTAssertEqual(ReadingOrder.order(columns, lineHeight: line, aspect: aspect), Array(0..<42))
	}

	func testTinyGapsAndOverlappingBoxesKeepTheOrder() {
		// Two "columns" a word space apart are one column.
		let left = lines(x: 0.1...0.495, from: 0.1, count: 20)
		let right = lines(x: 0.5...0.9, from: 0.1, count: 20)
		XCTAssertNil(ReadingOrder.order(left + right, lineHeight: line, aspect: aspect))
		// Columns, but two boxes overlap: the layout is unclear.
		let columns = lines(x: 0.1...0.48, from: 0.12, count: 20) + lines(x: 0.52...0.9, from: 0.12, count: 20)
		let overlapping = columns + [CGRect(x: 0.1, y: 0.121, width: 0.3, height: 0.014)]
		XCTAssertNotNil(ReadingOrder.order(columns, lineHeight: line, aspect: aspect))
		XCTAssertNil(ReadingOrder.order(overlapping, lineHeight: line, aspect: aspect))
		XCTAssertNil(ReadingOrder.order(columns, lineHeight: 0, aspect: aspect), "no line height to judge by")
		XCTAssertNil(ReadingOrder.order([CGRect(x: 0.1, y: 0.1, width: 0, height: 0.1), CGRect(x: 0.6, y: 0.1, width: 0.3, height: 0.1)],
										lineHeight: line, aspect: aspect))
	}

	// MARK: The rebuild's paths

	func testTheHeuristicsReadTwoColumnsAsTwoParagraphs() throws {
		var recognized = [RecognizedLine(text: "Reading order in two columns", confidence: 1, alternatives: [],
										 box: CGRect(x: 0.1, y: 0.05, width: 0.8, height: 0.03))]
		for (index, box) in lines(x: 0.1...0.48, from: 0.12, count: 6).enumerated() {
			recognized.append(RecognizedLine(text: "left \(index)", confidence: 1, alternatives: [], box: box))
		}
		for (index, box) in lines(x: 0.52...0.9, from: 0.12, count: 6).enumerated() {
			recognized.append(RecognizedLine(text: "right \(index)", confidence: 1, alternatives: [], box: box))
		}
		let blocks = Rebuilder.heuristicBlocks(recognized.shuffled(), aspect: aspect)
		XCTAssertEqual(blocks.map(\.content.plainText), [
			"Reading order in two columns",
			"left 0 left 1 left 2 left 3 left 4 left 5",
			"right 0 right 1 right 2 right 3 right 4 right 5",
		])
	}

	func testAListEndingOneColumnAndAListStartingTheNextStayApart() throws {
		var recognized: [RecognizedLine] = []
		for (index, box) in lines(x: 0.1...0.48, from: 0.12, count: 12).enumerated() {
			recognized.append(RecognizedLine(text: index >= 10 ? "• left item \(index)" : "left \(index)", confidence: 1, alternatives: [], box: box))
		}
		for (index, box) in lines(x: 0.52...0.9, from: 0.12, count: 12).enumerated() {
			recognized.append(RecognizedLine(text: index == 0 ? "• right item" : "right \(index)", confidence: 1, alternatives: [], box: box))
		}
		let blocks = Rebuilder.heuristicBlocks(recognized, aspect: aspect)
		let lists = blocks.filter { block in
			if case .list = block.content { return true }
			return false
		}
		XCTAssertEqual(lists.count, 2, "read one after the other, but a column apart")
		let first = try XCTUnwrap(lists.first?.box)
		let second = try XCTUnwrap(lists.last?.box)
		XCTAssertLessThan(first.x + first.width, 0.5, "the left column's list stays in the left column")
		XCTAssertGreaterThan(second.x, 0.5)
		// Items just below one another still make one list.
		let stacked = [CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.02), CGRect(x: 0.1, y: 0.23, width: 0.5, height: 0.02)]
		XCTAssertTrue(Rebuilder.continuesList(NormalizedBox(stacked[0]), with: NormalizedBox(stacked[1])))
		XCTAssertFalse(Rebuilder.continuesList(NormalizedBox(stacked[1]), with: NormalizedBox(stacked[0])), "above the list")
		XCTAssertFalse(Rebuilder.continuesList(NormalizedBox(stacked[0]), with: NormalizedBox(x: 0.1, y: 0.4, width: 0.5, height: 0.02)),
					   "further down the page")
	}

	func testTheDocumentReadersBlocksReadDownEachColumn() {
		let placed: [(box: NormalizedBox, block: FolioBlock)] = [
			("right, below", NormalizedBox(x: 0.52, y: 0.5, width: 0.38, height: 0.3)),
			("left, below", NormalizedBox(x: 0.1, y: 0.45, width: 0.38, height: 0.35)),
			("left, above", NormalizedBox(x: 0.1, y: 0.12, width: 0.38, height: 0.3)),
			("right, above", NormalizedBox(x: 0.52, y: 0.11, width: 0.38, height: 0.35)),
		].map { text, box in (box, paragraph(text, box)) }
		let ordered = Rebuilder.readingOrdered(placed, lineHeight: line, aspect: aspect)
		XCTAssertEqual(ordered.map(\.content.plainText), ["left, above", "left, below", "right, above", "right, below"])
	}

	func testPicturesFoundLaterReadBetweenTheColumnsAroundThem() throws {
		let blocks = [
			paragraph("left, above", NormalizedBox(x: 0.1, y: 0.12, width: 0.38, height: 0.25)),
			paragraph("left, below", NormalizedBox(x: 0.1, y: 0.63, width: 0.38, height: 0.3)),
			paragraph("right, above", NormalizedBox(x: 0.52, y: 0.12, width: 0.38, height: 0.2)),
			// Placed by position into the columns' order, as FigurePlacement does.
			FolioBlock(content: .figure(assetID: "chart", caption: nil, altText: nil), box: NormalizedBox(x: 0.1, y: 0.4, width: 0.8, height: 0.2)),
			paragraph("right, below", NormalizedBox(x: 0.52, y: 0.63, width: 0.38, height: 0.25)),
		]
		let lines = [RecognizedLine(text: "x", confidence: 1, alternatives: [], box: CGRect(x: 0.1, y: 0.12, width: 0.3, height: line))]
		let snapshot = Rebuilder.PageSnapshot(imageData: nil, lines: lines, aspect: aspect)
		let pictured = FolioPage(blocks: blocks)
		let plain = FolioPage(blocks: blocks.filter { !Rebuilder.isPicture($0) })
		let result = Rebuilder.orderingPictures(in: [pictured, plain], pages: [snapshot, snapshot])
		XCTAssertEqual(result[0].blocks.map(\.content.plainText).map { $0.isEmpty ? "picture" : $0 },
					   ["left, above", "right, above", "picture", "left, below", "right, below"])
		XCTAssertEqual(result[1], plain, "a page without pictures keeps the order it has")
	}

	// MARK: Helpers

	/// `count` lines spanning `x`, `step` apart from `top`, each a line high.
	private func lines(x: ClosedRange<Double>, from top: Double, count: Int, step: Double = 0.02) -> [CGRect] {
		(0..<count).map { index in
			CGRect(x: x.lowerBound, y: top + Double(index) * step, width: x.upperBound - x.lowerBound, height: line)
		}
	}

	private func paragraph(_ text: String, _ box: NormalizedBox) -> FolioBlock {
		FolioBlock(content: .paragraph(runs: [FolioRun(text: text)], alignment: .leading), box: box)
	}
}
