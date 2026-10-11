//
//  FolioCoreTests.swift
//  Folio (fork of Open Scanner)
//
//  The review edits, uncertain-word flags, layout heuristics and the equation
//  parser — the logic behind Review & fix that doesn't need a device.
//

import XCTest
@testable import scanner

@MainActor
final class FolioCoreTests: XCTestCase {

	// MARK: Review edits

	func testResolvingAWordFlagReplacesTheTextAndClosesTheFlag() throws {
		var document = SampleLibrary.labNotesDocument
		XCTAssertEqual(document.openFlags.count, 3)
		let flag = try XCTUnwrap(document.openFlags.first { $0.flag.read == "saturuted" }?.flag)

		document.resolveFlag(flag.id, option: flag.options[0])

		XCTAssertEqual(document.openFlags.count, 2)
		let paragraph = try XCTUnwrap(document.pages[0].blocks.first { if case .paragraph = $0.content { return true }; return false })
		XCTAssertTrue(paragraph.content.plainText.contains("enzyme is saturated."))
		XCTAssertEqual(document.flag(flag.id)?.resolution, "saturated")
	}

	func testTypedCorrectionWins() throws {
		var document = SampleLibrary.labNotesDocument
		let flag = try XCTUnwrap(document.openFlags.first { $0.flag.read == "Lineweaver–Bunk" }?.flag)
		document.resolveFlag(flag.id, typed: "Lineweaver-Burk plot")
		XCTAssertTrue(document.pages[0].blocks.contains { $0.content.plainText.contains("Plot Lineweaver-Burk plot") })
	}

	func testEdgeFlagCanReverseOrRemoveTheArrow() throws {
		var reversed = SampleLibrary.labNotesDocument
		let flag = try XCTUnwrap(reversed.openFlags.first { $0.flag.kind == .edge }?.flag)
		let reverse = try XCTUnwrap(flag.options.first { $0.edgeAction == .reverse })
		reversed.resolveFlag(flag.id, option: reverse)
		guard case .diagram(let diagram) = reversed.pages[0].blocks.first(where: { if case .diagram = $0.content { return true }; return false })?.content else {
			return XCTFail("no diagram")
		}
		let edge = try XCTUnwrap(diagram.edges.first { $0.id == "e4" })
		XCTAssertEqual(edge.from, "enzyme")
		XCTAssertEqual(edge.to, "product")

		var removed = SampleLibrary.labNotesDocument
		let removedFlag = try XCTUnwrap(removed.openFlags.first { $0.flag.kind == .edge }?.flag)
		let remove = try XCTUnwrap(removedFlag.options.first { $0.edgeAction == .remove })
		removed.resolveFlag(removedFlag.id, option: remove)
		guard case .diagram(let pruned) = removed.pages[0].blocks.first(where: { if case .diagram = $0.content { return true }; return false })?.content else {
			return XCTFail("no diagram")
		}
		XCTAssertFalse(pruned.edges.contains { $0.id == "e4" })
		XCTAssertEqual(removed.openFlags.count, 2)
	}

	func testFormatButtonsStyleTheWholeBlockAndHeadingToggles() {
		var content = BlockContent.paragraph(runs: [FolioRun(text: "Hello "), FolioRun(text: "world", italic: true)], alignment: .leading)
		XCTAssertFalse(content.allRuns(.bold))
		content.setStyle(.bold, to: true)
		XCTAssertTrue(content.allRuns(.bold))
		XCTAssertFalse(content.allRuns(.italic))

		content.toggleHeading()
		XCTAssertTrue(content.isHeading)
		content.toggleHeading()
		XCTAssertFalse(content.isHeading)
		XCTAssertEqual(content.plainText, "Hello world")
	}

	func testCheckboxesTick() throws {
		let item = ListItem(runs: [FolioRun(text: "Repeat trial 3")], checked: false)
		var content = BlockContent.list(style: .checkbox, items: [item])
		content.toggleChecked(item: item.id)
		guard case .list(_, let items) = content else { return XCTFail("not a list") }
		XCTAssertEqual(items.first?.checked, true)
	}

	func testDocumentRoundTripsThroughJSON() throws {
		let document = SampleLibrary.labNotesDocument
		let data = try JSONEncoder.folio.encode(document)
		let decoded = try JSONDecoder.folio.decode(FolioDocument.self, from: data)
		XCTAssertEqual(decoded, document)
	}

	// MARK: Flags from Vision's alternatives

	func testWordFlagFindsTheOneWordTheReadingsDisagreeOn() throws {
		let line = RecognizedLine(text: "until the enzyme is saturuted", confidence: 0.3,
								  alternatives: ["until the enzyme is saturated", "until the enzyme is situated"], box: .zero)
		let flag = try XCTUnwrap(Rebuilder.wordFlag(for: line))
		XCTAssertEqual(flag.word, "saturuted")
		XCTAssertEqual(flag.options, ["saturated", "situated"])

		let runs = Rebuilder.flaggedRuns(for: line)
		XCTAssertEqual(runs.map(\.text), ["until the enzyme is ", "saturuted"])
		XCTAssertEqual(runs.last?.flag?.options.last?.label, "saturuted")
	}

	func testCorrectlySpelledReadingsWithOnlyMisspelledAlternativesAreNotFlagged() throws {
		let line = RecognizedLine(text: "queue", confidence: 0.3, alternatives: ["queu", "quee"], box: .zero)
		let page = FolioPage(blocks: [FolioBlock(content: .paragraph(runs: Rebuilder.flaggedRuns(for: line), alignment: .leading))])
		XCTAssertEqual(FolioDocument(title: "t", pages: [page]).openFlags.count, 1)
		let refined = Rebuilder.refineWordFlags(FolioDocument(title: "t", pages: [page]))
		XCTAssertEqual(refined.openFlags.count, 0)

		let misread = RecognizedLine(text: "the enzyme is saturuted", confidence: 0.3, alternatives: ["the enzyme is saturated", "the enzyme is saturuteb"], box: .zero)
		let misreadPage = FolioPage(blocks: [FolioBlock(content: .paragraph(runs: Rebuilder.flaggedRuns(for: misread), alignment: .leading))])
		let kept = try XCTUnwrap(Rebuilder.refineWordFlags(FolioDocument(title: "t", pages: [misreadPage])).openFlags.first?.flag)
		XCTAssertEqual(kept.options.first?.label, "saturated")
		XCTAssertEqual(kept.options.last?.label, "saturuted")
	}

	func testConfidentLinesAndUnalignedAlternativesAreNotFlagged() {
		let confident = RecognizedLine(text: "Plot the data", confidence: 1, alternatives: ["Plot the dota"], box: .zero)
		XCTAssertEqual(Rebuilder.flaggedRuns(for: confident).count, 1)
		XCTAssertNil(Rebuilder.flaggedRuns(for: confident).first?.flag)

		let unaligned = RecognizedLine(text: "Plot the data", confidence: 0.3, alternatives: ["Plotthe data"], box: .zero)
		XCTAssertNil(Rebuilder.wordFlag(for: unaligned))
	}

	// MARK: Layout heuristics

	func testHeuristicsFindHeadingParagraphBulletsAndCheckboxes() {
		func line(_ text: String, y: Double, height: Double = 0.02, x: Double = 0.1) -> RecognizedLine {
			RecognizedLine(text: text, confidence: 1, alternatives: [], box: CGRect(x: x, y: y, width: 0.6, height: height))
		}
		let blocks = Rebuilder.heuristicBlocks([
			line("Week 6 — Enzyme kinetics", y: 0.05, height: 0.04),
			line("Reaction rate rises with substrate", y: 0.12),
			line("concentration until saturation.", y: 0.145),
			line("- steady state", y: 0.25),
			line("- inhibitors", y: 0.28),
			line("☐ repeat trial 3", y: 0.35),
			line("☑ plot Lineweaver–Burk", y: 0.38),
		])
		XCTAssertEqual(blocks.count, 4)
		XCTAssertTrue(blocks[0].content.isHeading)
		guard case .paragraph = blocks[1].content else { return XCTFail("expected paragraph") }
		XCTAssertEqual(blocks[1].content.plainText, "Reaction rate rises with substrate concentration until saturation.")
		guard case .list(.bullet, let bullets) = blocks[2].content else { return XCTFail("expected bullets") }
		XCTAssertEqual(bullets.map(\.runs.plainText), ["steady state", "inhibitors"])
		guard case .list(.checkbox, let boxes) = blocks[3].content else { return XCTFail("expected checklist") }
		XCTAssertEqual(boxes.map(\.checked), [false, true])
	}

	// MARK: Equation typesetting

	func testMathParserHandlesFractionsAndScripts() throws {
		var parser = MathParser("v = \\frac{V_{max}[S]}{K_m + [S]}")
		let node = try XCTUnwrap(parser.parse())
		guard case .row(let parts) = node else { return XCTFail("expected a row") }
		XCTAssertTrue(parts.contains { if case .fraction = $0 { return true }; return false })

		var unsupported = MathParser("\\begin{matrix} a \\end{matrix}")
		XCTAssertNil(unsupported.parse())
	}
}
