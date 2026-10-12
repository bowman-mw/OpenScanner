//
//  RebuildProgressTests.swift
//  Rescriva (fork of Open Scanner)
//
//  A long rebuild shows where it is and never ends on a blank page: it
//  counts its pages off one at a time, a cancelled rebuild caches nothing,
//  diagrams are numbered on across pages built one at a time, and Apple
//  Intelligence asks about each open word at most once, within its budget.
//

import CoreData
import UIKit
import XCTest
@testable import scanner

@MainActor
final class RebuildProgressTests: XCTestCase {

	/// In-memory containers kept alive for the test's contexts.
	private var containers: [NSPersistentContainer] = []

	override func tearDown() {
		containers.removeAll()
		super.tearDown()
	}

	// MARK: Counting

	func testWholeRebuildCountsEveryPageInOrder() async throws {
		let scan = try makeScan(pageCount: 3, in: try makeContext())
		var steps: [RebuildProgress] = []

		let document = await Rebuilder(tier: .basic).document(for: scan) { steps.append($0) }

		XCTAssertEqual(document.pages.count, 3)
		XCTAssertEqual(scan.rebuiltDocument?.pages.count, 3, "cached for Review")
		let structure = steps.filter { $0.stage == .structure }
		XCTAssertEqual(structure.map(\.done), [0, 1, 2, 3])
		XCTAssertTrue(structure.allSatisfy { $0.total == 3 })
		var firstSeen: [RebuildStage] = []
		for step in steps where !firstSeen.contains(step.stage) {
			firstSeen.append(step.stage)
		}
		XCTAssertEqual(firstSeen, [.reading, .structure, .ordering], "Basic tier never asks Apple Intelligence")
	}

	func testDetailCountsFromOneAndOnlyForCountedSteps() {
		XCTAssertEqual(RebuildProgress(stage: .structure, done: 0, total: 54).detail, "Page 1 of 54")
		XCTAssertEqual(RebuildProgress(stage: .structure, done: 11, total: 54).detail, "Page 12 of 54")
		XCTAssertEqual(RebuildProgress(stage: .structure, done: 54, total: 54).detail, "Page 54 of 54", "never past the last")
		XCTAssertEqual(RebuildProgress(stage: .checking, done: 39, total: 126).detail, "Word 40 of 126")
		XCTAssertNil(RebuildProgress(stage: .structure).detail, "nothing to count yet")
		XCTAssertNil(RebuildProgress(stage: .ordering, done: 1, total: 3).detail)
	}

	// MARK: Cancelling

	func testCancelledRebuildCachesNothing() async throws {
		let scan = try makeScan(pageCount: 3, in: try makeContext())

		let work = Task { @MainActor in await Rebuilder(tier: .basic).document(for: scan) { _ in } }
		work.cancel()
		let document = await work.value

		XCTAssertEqual(document.pages.count, 3, "still one page per scan page")
		XCTAssertNil(scan.rebuiltData, "a half-built document would come back as the scan's for good")
	}

	// MARK: Diagrams a page at a time

	func testDiagramsAreNumberedOnFromEarlierPages() async throws {
		let data = try XCTUnwrap(UIImage(cgImage: try twoBoxDiagram()).jpegData(compressionQuality: 0.9))
		let snapshot = Rebuilder.PageSnapshot(imageData: data, lines: [], aspect: 800.0 / 600.0)

		let pages = await Rebuilder.detectDiagrams(in: [RescrivaPage()], pages: [snapshot], numberingAfter: 2)

		let captions = pages[0].blocks.compactMap { block -> String? in
			guard case .diagram(let diagram) = block.content else { return nil }
			return diagram.caption
		}
		XCTAssertEqual(captions, [Rebuilder.figureCaption(3, source: .typed)])
	}

	// MARK: Apple Intelligence

	func testOnlyOpenWordFlagsAreQuestions() {
		var edge = RescrivaFlag(kind: .edge, title: "Arrow", detail: "", read: "→", options: [])
		edge.resolution = nil
		let page = RescrivaPage(blocks: [
			RescrivaBlock(content: .paragraph(runs: [flaggedRun("saturuted", resolution: nil), RescrivaRun(text: " and "),
												  flaggedRun("enzyme", resolution: "enzyme")], alignment: .leading)),
			RescrivaBlock(content: .list(style: .bullet, items: [ListItem(runs: [flaggedRun("rnass", resolution: nil)])])),
			RescrivaBlock(content: .paragraph(runs: [RescrivaRun(text: "→", flag: edge)], alignment: .leading)),
		])

		XCTAssertEqual(AppleIntelligence.openWordFlags(in: RescrivaDocument(title: "", pages: [page, page])), 4)
		XCTAssertEqual(AppleIntelligence.questions(for: RescrivaDocument(title: "", pages: [page, page])).total, 4)
	}

	func testALongDocumentAsksAboutTheFirstWordsOnly() {
		let runs = (0..<(AppleIntelligence.maxQuestions + 10)).map { flaggedRun("w\($0)rd", resolution: nil) }
		let page = RescrivaPage(blocks: [RescrivaBlock(content: .paragraph(runs: runs, alignment: .leading))])

		let questions = AppleIntelligence.questions(for: RescrivaDocument(title: "", pages: [page]))

		XCTAssertEqual(questions.total, AppleIntelligence.maxQuestions, "the count the progress bar fills to")
	}

	func testQuestionsStopAtTheBudgetOrOnceAllAreAsked() {
		let later = ContinuousClock.now + .seconds(60)
		XCTAssertFalse(AppleIntelligence.Questions(total: 2, deadline: later).isSpent)
		XCTAssertTrue(AppleIntelligence.Questions(total: 2, deadline: later, asked: 2).isSpent)
		XCTAssertTrue(AppleIntelligence.Questions(total: 2, deadline: .now - .seconds(1)).isSpent, "out of time")
		XCTAssertTrue(AppleIntelligence.Questions(total: 0, deadline: later).isSpent, "nothing to ask")
	}

	// MARK: Helpers

	private func flaggedRun(_ read: String, resolution: String?) -> RescrivaRun {
		var flag = RescrivaFlag(kind: .word, title: "Did you mean…", detail: "", read: read,
							 options: [RescrivaFlag.Option(label: read, note: "keep as read")])
		flag.resolution = resolution
		return RescrivaRun(text: resolution ?? read, flag: flag)
	}

	/// Two boxes joined by a line, as `DiagramDetector` reads a drawn diagram.
	private func twoBoxDiagram() throws -> CGImage {
		let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
		let context = try XCTUnwrap(CGContext(data: nil, width: 800, height: 600, bitsPerComponent: 8, bytesPerRow: 0,
											  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
		context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
		context.fill(CGRect(x: 0, y: 0, width: 800, height: 600))
		context.setStrokeColor(CGColor(srgbRed: 0.13, green: 0.16, blue: 0.19, alpha: 1))
		context.setLineWidth(5)
		context.setLineCap(.round)
		context.stroke(CGRect(x: 80, y: 270, width: 200, height: 110))
		context.stroke(CGRect(x: 520, y: 270, width: 200, height: 110))
		context.strokeLineSegments(between: [CGPoint(x: 290, y: 325), CGPoint(x: 510, y: 325)])
		return try XCTUnwrap(context.makeImage())
	}

	/// An in-memory library on the app's own model.
	private func makeContext() throws -> NSManagedObjectContext {
		let container = NSPersistentContainer(name: "scanner", managedObjectModel: PersistenceController.shared.container.managedObjectModel)
		let description = NSPersistentStoreDescription()
		description.type = NSInMemoryStoreType
		container.persistentStoreDescriptions = [description]
		var loadError: Error?
		container.loadPersistentStores { _, error in loadError = error }
		if let loadError { throw loadError }
		containers.append(container)
		return container.viewContext
	}

	private func insert<Object: NSManagedObject>(_ type: Object.Type, _ entityName: String, into context: NSManagedObjectContext) throws -> Object {
		try XCTUnwrap(NSEntityDescription.insertNewObject(forEntityName: entityName, into: context) as? Object)
	}

	/// A scan of `pageCount` blank pages, each with one recognized line.
	private func makeScan(pageCount: Int, in context: NSManagedObjectContext) throws -> Scan {
		let scan = try insert(Scan.self, "Scan", into: context)
		scan.id = UUID()
		let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
		let page = try XCTUnwrap(CGContext(data: nil, width: 200, height: 260, bitsPerComponent: 8, bytesPerRow: 0,
										   space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
		page.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
		page.fill(CGRect(x: 0, y: 0, width: 200, height: 260))
		let image = UIImage(cgImage: try XCTUnwrap(page.makeImage()))
		for index in 0..<pageCount {
			let capture = try insert(ScanCapture.self, "ScanCapture", into: context)
			capture.id = UUID()
			capture.order = Int32(index)
			capture.createImage(fullSizedImage: image)
			capture.createThumbnail()
			scan.addToCaptures(capture)
			let item = try insert(ScanRecognizedItem.self, "ScanRecognizedItem", into: context)
			item.transcript = "Page \(index + 1)"
			capture.addToRecognizedItems(item)
		}
		try context.save()
		return scan
	}
}
