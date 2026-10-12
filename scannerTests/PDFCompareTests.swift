//
//  PDFCompareTests.swift
//  Rescriva (fork of Open Scanner)
//
//  Two PDFs side by side: when they count as versions of one document, which words differ (and
//  that re-wrapped lines and text moved to the next page don't), the cap on long stretches, and
//  that the marks land on the changed words of a real PDF.
//

import PDFKit
import UIKit
import XCTest
@testable import scanner

final class PDFCompareTests: XCTestCase {
	private let fern = """
		Ferns grow in shaded woodland along stream banks
		and on old stone walls each frond unrolls
		from a tight fiddlehead in spring
		"""

	/// The words of `text.words[range]`.
	private func words(_ range: Range<Int>, _ text: PDFCompareText) -> [String] {
		text.words[range].map(\.text)
	}

	func testIdenticalPDFsHaveNoDifferences() {
		let result = PDFCompare.compare(left: [fern, "Moss and lichen"], right: [fern, "Moss and lichen"])
		XCTAssertEqual(result.similarity, 1)
		XCTAssertTrue(result.isSameDocument)
		XCTAssertTrue(result.hasText)
		XCTAssertEqual(result.changes, [])
	}

	func testAChangedWordIsTheOnlyDifference() throws {
		let edited = fern.replacingOccurrences(of: "shaded", with: "sunny")
		let result = PDFCompare.compare(left: ["Title page", fern], right: ["Title page", edited])
		let change = try XCTUnwrap(result.changes.first)
		XCTAssertEqual(result.changes.count, 1)
		XCTAssertEqual(words(change.removed, result.left), ["shaded"])
		XCTAssertEqual(words(change.added, result.right), ["sunny"])

		let span = try XCTUnwrap(PDFCompare.spans(of: change.added, in: result.right).first)
		XCTAssertEqual(span.page, 1)
		XCTAssertEqual((edited as NSString).substring(with: span.range), "sunny")
	}

	func testRewrappedLinesAndTextMovedToTheNextPageAreNotDifferences() {
		let left = ["Ferns grow in shaded woodland\nalong stream banks and on", "old stone walls\nMoss and lichen share the rocks"]
		let right = ["Ferns grow in shaded\nwoodland along stream banks", "and on old stone walls Moss\nand lichen share the rocks"]
		XCTAssertEqual(PDFCompare.compare(left: left, right: right).changes, [])
	}

	func testAnInsertedLineIsOneAdditionShownBesideTheWordItPrecedes() throws {
		let lines = fern.components(separatedBy: "\n")
		let edited = [lines[0], "Spores ripen under the leaves", lines[1], lines[2]].joined(separator: "\n")
		let result = PDFCompare.compare(left: [fern], right: [edited])
		let change = try XCTUnwrap(result.changes.first)
		XCTAssertEqual(result.changes.count, 1)
		XCTAssertTrue(change.removed.isEmpty)
		XCTAssertEqual(words(change.added, result.right), ["Spores", "ripen", "under", "the", "leaves"])

		let anchor = try XCTUnwrap(PDFCompare.spans(of: change.removed, in: result.left).first)
		XCTAssertEqual((fern as NSString).substring(with: anchor.range), "and")
	}

	func testDifferentDocumentsAreOnlyComparedWhenAsked() {
		let other = """
			Battery cells store charge in lithium ion chemistry
			rated capacity three amp hours at room temperature
			"""
		let result = PDFCompare.compare(left: [fern], right: [other])
		XCTAssertLessThan(result.similarity, PDFCompare.sameDocumentSimilarity)
		XCTAssertFalse(result.isSameDocument)
		XCTAssertEqual(result.changes, [])
		XCTAssertFalse(PDFCompare.compare(left: [fern], right: [other], always: true).changes.isEmpty)

		let lightlyEdited = fern.replacingOccurrences(of: "spring", with: "early spring")
		XCTAssertTrue(PDFCompare.compare(left: [fern], right: [lightlyEdited]).isSameDocument)
	}

	func testPDFsWithoutTextHaveNothingToCompare() {
		let result = PDFCompare.compare(left: ["", ""], right: [" \n "])
		XCTAssertFalse(result.hasText)
		XCTAssertEqual(result.similarity, 0)
		XCTAssertEqual(result.changes, [])
	}

	func testAStretchTooLongToCompareWordByWordIsOneDifference() throws {
		let long = (0..<1_200).map { "w\($0)" }.joined(separator: " ")
		let rewritten = (0..<1_200).map { "v\($0)" }.joined(separator: " ")
		let left = PDFCompareText(pages: ["Shared heading", long])
		let right = PDFCompareText(pages: ["Shared heading", rewritten])
		let changes = PDFCompare.changes(from: left, to: right)
		let change = try XCTUnwrap(changes.first)
		XCTAssertEqual(changes.count, 1)
		XCTAssertEqual(change.removed, 2..<1_202)
		XCTAssertEqual(change.added, 2..<1_202)
	}

	func testChangesAreNamedByWhatTheyDo() throws {
		let left = ["1. Term. This lease begins on October 1, 2026 and runs for twelve months.\n4. Pets. No pets are permitted on the premises.\n6. Notice. Either party may end this lease with notice."]
		let right = ["1. Term. This lease begins on November 1, 2026 and runs for twelve months.\n4. Pets. One cat is permitted with a $300 pet deposit.\n5. Repairs within 7 days.\n6. Notice. Either party may end this lease with notice."]
		let result = PDFCompare.compare(left: left, right: right, always: true)
		let kinds = result.changes.map(PDFCompare.kind(of:))
		XCTAssertEqual(kinds, [.changed, .rewritten, .added])

		let summaries = result.changes.map { PDFCompare.summary(of: $0, left: result.left, right: result.right) }
		XCTAssertEqual(summaries[0], "October → November")
		XCTAssertTrue(summaries[1].hasPrefix("No pets are permitted on the premises. → One cat is permitted"), summaries[1])
		XCTAssertEqual(summaries[2], String(localized: "Added: 5. Repairs within 7 days."))
		XCTAssertEqual(result.changes.map { PDFCompare.page(of: $0, left: result.left, right: result.right) }, [1, 1, 1])

		let removal = PDFCompare.compare(left: right, right: left, always: true).changes.last
		XCTAssertEqual(removal.map(PDFCompare.kind(of:)), .removed)
	}

	func testALeaseEditedInSixPlacesIsStillAVersionOfItself() {
		let draft = """
			Residential lease Draft - Sep 28
			1. Term. This lease begins on October 1, 2026 and runs for twelve months.
			2. Rent. Tenant pays $1,850 per month, due on the first of each month.
			3. Deposit. A security deposit of $1,850 is held by the landlord.
			4. Pets. No pets are permitted on the premises.
			5. Repairs. Landlord handles major repairs within 14 days of written notice.
			6. Notice. Either party may end this lease with 60 days' written notice.
			"""
		let signed = draft.replacingOccurrences(of: "Draft - Sep 28", with: "Signed - Oct 9")
			.replacingOccurrences(of: "October 1", with: "November 1")
			.replacingOccurrences(of: "$1,850 per month", with: "$1,925 per month")
			.replacingOccurrences(of: "the landlord.", with: "the landlord in a separate interest-bearing account.")
			.replacingOccurrences(of: "No pets are permitted on the premises.", with: "One cat is permitted with a $300 pet deposit.")
			.replacingOccurrences(of: "14 days", with: "7 days")
		let result = PDFCompare.compare(left: [draft], right: [signed])
		XCTAssertTrue(result.isSameDocument, "\(result.similarity)")
		XCTAssertEqual(result.changes.map(PDFCompare.kind(of:)), [.changed, .changed, .changed, .added, .rewritten, .changed])
	}

	func testLongExcerptsAreCutWithAnEllipsis() {
		let text = PDFCompareText(pages: [String(repeating: "word ", count: 40)])
		let excerpt = PDFCompare.excerpt(0..<40, in: text, limit: 22)
		XCTAssertEqual(excerpt.count, 22)
		XCTAssertTrue(excerpt.hasSuffix("…"))
		XCTAssertEqual(PDFCompare.excerpt(0..<2, in: text), "word word")
	}

	func testMarksLandOnTheChangedWordsOfARealPDF() throws {
		let lines = ["Chapter one Woodland notes", "Ferns grow in shaded woodland", "Moss and lichen share the rocks"]
		let left = try XCTUnwrap(pdf([["Field guide"], lines]))
		let right = try XCTUnwrap(pdf([["Field guide"], lines.map { $0.replacingOccurrences(of: "shaded", with: "sunny") }]))
		let result = PDFCompare.compare(left: texts(of: left), right: texts(of: right))
		let change = try XCTUnwrap(result.changes.first)
		XCTAssertEqual(result.changes.count, 1)

		let removed = try XCTUnwrap(PDFCompare.spans(of: change.removed, in: result.left).first)
		let added = try XCTUnwrap(PDFCompare.spans(of: change.added, in: result.right).first)
		XCTAssertEqual(left.page(at: removed.page)?.selection(for: removed.range)?.string, "shaded")
		XCTAssertEqual(right.page(at: added.page)?.selection(for: added.range)?.string, "sunny")
	}

	// MARK: Helpers

	/// A PDF with one page per entry, each line drawn below the last.
	private func pdf(_ pages: [[String]]) -> PDFDocument? {
		let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
		let data = renderer.pdfData { context in
			for lines in pages {
				context.beginPage()
				for (index, line) in lines.enumerated() {
					TestPDF.draw(line, in: context.cgContext, at: CGPoint(x: 72, y: 700 - CGFloat(index) * 24))
				}
			}
		}
		return PDFDocument(data: data)
	}

	private func texts(of document: PDFDocument) -> [String] {
		(0..<document.pageCount).map { document.page(at: $0)?.string ?? "" }
	}
}
