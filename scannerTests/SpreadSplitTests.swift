//
//  SpreadSplitTests.swift
//  Rescriva (fork of Open Scanner)
//
//  Splitting a book spread into two pages: which crops are offered it, the
//  fold found on a synthetic spread (and none on a single page), the split
//  of the crop under its perspective at every rotation, the shared original
//  each half keeps a copy of, and the pages and rebuilt document after a
//  split.
//

import CoreData
import CoreImage
import UIKit
import XCTest
@testable import scanner

@MainActor
final class SpreadSplitTests: XCTestCase {

	/// A wide crop on a landscape photo.
	private let wide = PageQuad(
		topLeft: CGPoint(x: 0.1, y: 0.2),
		topRight: CGPoint(x: 0.9, y: 0.2),
		bottomRight: CGPoint(x: 0.9, y: 0.6),
		bottomLeft: CGPoint(x: 0.1, y: 0.6)
	)
	/// A crop seen in perspective: narrower at the top.
	private let trapezoid = PageQuad(
		topLeft: CGPoint(x: 0.2, y: 0.1),
		topRight: CGPoint(x: 0.8, y: 0.1),
		bottomRight: CGPoint(x: 0.95, y: 0.9),
		bottomLeft: CGPoint(x: 0.05, y: 0.9)
	)
	/// In-memory containers kept alive for the test's contexts.
	private var containers: [NSPersistentContainer] = []

	override func tearDown() {
		containers.removeAll()
		super.tearDown()
	}

	// MARK: Offering the split

	func testOnlyACropMuchWiderThanTallAsShownLooksLikeASpread() {
		let photo = CGSize(width: 4032, height: 3024)
		XCTAssertEqual(SpreadSplit.edgeAspect(of: wide, imageSize: photo), 0.8 * 4032 / (0.4 * 3024), accuracy: 1e-6)
		XCTAssertTrue(SpreadSplit.looksLikeSpread(wide, imageSize: photo, quarterTurns: 0))
		XCTAssertFalse(SpreadSplit.looksLikeSpread(wide, imageSize: photo, quarterTurns: 1), "turned upright, it is tall")
		XCTAssertTrue(SpreadSplit.looksLikeSpread(wide, imageSize: photo, quarterTurns: 2))
		let page = PageQuad(topLeft: CGPoint(x: 0.3, y: 0.05), topRight: CGPoint(x: 0.7, y: 0.05),
							bottomRight: CGPoint(x: 0.7, y: 0.95), bottomLeft: CGPoint(x: 0.3, y: 0.95))
		XCTAssertFalse(SpreadSplit.looksLikeSpread(page, imageSize: photo, quarterTurns: 0), "one portrait page")
		XCTAssertFalse(SpreadSplit.looksLikeSpread(wide, imageSize: .zero, quarterTurns: 0))
	}

	// MARK: Finding the fold

	func testTheFoldIsFoundInTheMiddleOfTheQuietStretchBetweenThePages() throws {
		// Text on both pages, a blank gutter at 160..<186 px with a soft fold shadow down its middle.
		let gray = spread(width: 400, height: 240, gutter: 160..<186)
		let fold = try XCTUnwrap(SpreadSplit.foldPosition(in: gray))
		XCTAssertEqual(fold, 173.0 / 400, accuracy: 0.02)
	}

	func testASinglePageOrABlankOneHasNoFold() {
		XCTAssertNil(SpreadSplit.foldPosition(in: spread(width: 400, height: 240, gutter: 0..<0)), "text all the way across")
		let blank = StyleDetector.Gray(width: 400, height: 240, pixels: [UInt8](repeating: 235, count: 400 * 240))
		XCTAssertNil(SpreadSplit.foldPosition(in: blank))
		XCTAssertNil(SpreadSplit.foldPosition(inEnergy: [1, 2]), "too narrow to search")
	}

	func testSmoothingAveragesTheNeighbours() {
		XCTAssertEqual(SpreadSplit.smoothed([0, 0, 9, 0, 0], radius: 1), [0, 3, 3, 3, 0])
		XCTAssertEqual(SpreadSplit.smoothed([4, 8], radius: 0), [4, 8])
	}

	func testTheFoldIsFoundOnARenderedSpreadThroughItsCrop() throws {
		// The spread drawn into the middle of a bigger photo (centred, so either origin finds it),
		// cropped with a quad around it.
		let photo = try spreadPhoto(width: 1200, height: 900, page: CGRect(x: 150, y: 200, width: 900, height: 500), foldAt: 0.42)
		let quad = PageQuad(topLeft: CGPoint(x: 0.125, y: 200.0 / 900), topRight: CGPoint(x: 0.875, y: 200.0 / 900),
							bottomRight: CGPoint(x: 0.875, y: 700.0 / 900), bottomLeft: CGPoint(x: 0.125, y: 700.0 / 900))
		let fold = try XCTUnwrap(SpreadSplit.findFold(on: photo, quad: quad, quarterTurns: 0))
		XCTAssertEqual(fold, 0.42, accuracy: 0.03)
		// Turned a half turn, the fold is as far from the other side.
		let turned = try XCTUnwrap(SpreadSplit.findFold(on: photo, quad: quad, quarterTurns: 2))
		XCTAssertEqual(turned, 0.58, accuracy: 0.03)
	}

	// MARK: Splitting the crop

	func testTheCropsPerspectiveMapsThePageOntoTheQuadAndBack() throws {
		for (corner, expected) in zip(SpreadSplit.unitSquare, trapezoid.corners) {
			assertSame(try XCTUnwrap(SpreadSplit.point(in: trapezoid, u: corner.x, v: corner.y)), expected)
		}
		// The middle of the page is where the crop's diagonals cross, not the corners' average.
		let centre = try XCTUnwrap(SpreadSplit.point(in: trapezoid, u: 0.5, v: 0.5))
		XCTAssertEqual(centre.x, 0.5, accuracy: 1e-9)
		XCTAssertEqual(centre.y, 0.1 + 0.8 * (0.6 / 1.5), accuracy: 1e-9)
		let inside = try XCTUnwrap(SpreadSplit.point(in: trapezoid, u: 0.3, v: 0.7))
		assertSame(try XCTUnwrap(SpreadSplit.unitPosition(of: inside, in: trapezoid)), CGPoint(x: 0.3, y: 0.7))
		let flat = PageQuad(topLeft: .zero, topRight: CGPoint(x: 0.5, y: 0.5), bottomRight: CGPoint(x: 1, y: 1), bottomLeft: CGPoint(x: 0.2, y: 0.2))
		XCTAssertNil(SpreadSplit.halves(of: flat, at: 0.5, quarterTurns: 0), "a crop with no area")
	}

	func testTheHalvesMeetOnTheLineAndKeepTheCornerOrder() throws {
		let halves = try XCTUnwrap(SpreadSplit.halves(of: wide, at: 0.5, quarterTurns: 0))
		assertQuad(halves.first, [(0.1, 0.2), (0.5, 0.2), (0.5, 0.6), (0.1, 0.6)])
		assertQuad(halves.second, [(0.5, 0.2), (0.9, 0.2), (0.9, 0.6), (0.5, 0.6)])
		// Under perspective, the halves share the split line, which runs where the line is drawn.
		let split = try XCTUnwrap(SpreadSplit.halves(of: trapezoid, at: 0.4, quarterTurns: 0))
		let line = try XCTUnwrap(SpreadSplit.line(in: trapezoid, at: 0.4, quarterTurns: 0))
		assertSame(split.first.topRight, split.second.topLeft)
		assertSame(split.first.bottomRight, split.second.bottomLeft)
		assertSame(split.first.topRight, line.start)
		assertSame(split.first.bottomRight, line.end)
		XCTAssertTrue(QuadEditing.isAcceptable(split.first) && QuadEditing.isAcceptable(split.second))
		XCTAssertEqual(try XCTUnwrap(SpreadSplit.fraction(of: line.start, in: trapezoid, quarterTurns: 0)), 0.4, accuracy: 1e-9)
		XCTAssertNil(SpreadSplit.halves(of: wide, at: 0.05, quarterTurns: 0), "too close to the edge")
	}

	func testTheSplitFollowsThePageAsShownAtEveryRotation() throws {
		// A quarter turn clockwise: the left of the page as shown is the bottom of the photo's crop.
		let quarter = try XCTUnwrap(SpreadSplit.halves(of: wide, at: 0.25, quarterTurns: 1))
		assertQuad(quarter.first, [(0.1, 0.5), (0.9, 0.5), (0.9, 0.6), (0.1, 0.6)])
		assertQuad(quarter.second, [(0.1, 0.2), (0.9, 0.2), (0.9, 0.5), (0.1, 0.5)])
		// A half turn: the left as shown is the crop's right.
		let half = try XCTUnwrap(SpreadSplit.halves(of: wide, at: 0.25, quarterTurns: 2))
		assertQuad(half.first, [(0.7, 0.2), (0.9, 0.2), (0.9, 0.6), (0.7, 0.6)])
		assertQuad(half.second, [(0.1, 0.2), (0.7, 0.2), (0.7, 0.6), (0.1, 0.6)])
		// Three quarters: the left as shown is the crop's top.
		let threeQuarters = try XCTUnwrap(SpreadSplit.halves(of: wide, at: 0.25, quarterTurns: 3))
		assertQuad(threeQuarters.first, [(0.1, 0.2), (0.9, 0.2), (0.9, 0.3), (0.1, 0.3)])
		assertQuad(threeQuarters.second, [(0.1, 0.3), (0.9, 0.3), (0.9, 0.6), (0.1, 0.6)])
		for turns in 0..<4 {
			let line = try XCTUnwrap(SpreadSplit.line(in: trapezoid, at: 0.35, quarterTurns: turns))
			XCTAssertEqual(try XCTUnwrap(SpreadSplit.fraction(of: line.end, in: trapezoid, quarterTurns: turns)), 0.35, accuracy: 1e-9)
		}
	}

	// MARK: The pages after a split

	func testEachHalfKeepsItsOwnCopyOfTheOriginal() throws {
		let store = makeStore()
		let id = UUID()
		let copyID = UUID()
		try store.save(try XCTUnwrap(OriginalStore.encode(CIImage(cgImage: try spreadPhoto(width: 300, height: 200)))), for: id)
		try store.copy(id, to: copyID)
		store.remove(id)
		XCTAssertFalse(store.contains(id))
		XCTAssertNotNil(store.loadImage(for: copyID), "deleting one page leaves the other's original")
		XCTAssertThrowsError(try store.copy(id, to: UUID()), "no original to copy")
		XCTAssertThrowsError(try store.copy(copyID, to: copyID))
	}

	func testSplittingAPageReplacesItWithTwoInPlace() async throws {
		let context = try makeContext()
		let store = makeStore()
		let scan = try makeScan(pageCount: 3, in: context)
		let ids = scan.capturesArray.compactMap(\.id)
		let target = try XCTUnwrap(scan.capturesArray[safe: 1])
		try store.save(try XCTUnwrap(OriginalStore.encode(CIImage(cgImage: try spreadPhoto(width: 600, height: 300)))), for: ids[1])
		scan.rebuiltDocument = RescrivaDocument(title: "Spread", pages: ids.map { _ in RescrivaPage(blocks: []) }, sourceCaptureIDs: ids)
		try context.save()
		XCTAssertTrue(PageReprocessor.splicesRebuiltPage(of: target))

		let halves = try XCTUnwrap(SpreadSplit.halves(of: .fullFrame, at: 0.5, quarterTurns: 0))
		var first = try XCTUnwrap(target.recipe)
		first.quad = halves.first
		var second = first
		second.quad = halves.second
		let result = try await PageReprocessor.split(target, first: first, second: second, originals: store)
		let newID = try XCTUnwrap(result.second.id)

		XCTAssertEqual(scan.capturesArray.compactMap(\.id), [ids[0], ids[1], newID, ids[2]], "the halves sit where the page was")
		XCTAssertEqual(scan.capturesArray.map(\.order), [0, 1, 2, 3])
		XCTAssertEqual(target.recipe, first)
		XCTAssertEqual(result.second.recipe, second)
		let left = try XCTUnwrap(target.image)
		let right = try XCTUnwrap(result.second.image)
		XCTAssertEqual(left.size.width, 300, accuracy: 4, "half the spread")
		XCTAssertEqual(right.size.width, 300, accuracy: 4)
		XCTAssertFalse(target.recognizedItemsArray.contains { $0.transcript == "Page 2" }, "what was read from the spread goes")
		XCTAssertTrue(store.contains(newID))
		XCTAssertFalse(context.hasChanges, "saved")

		let document = try XCTUnwrap(scan.rebuiltDocument, "the other pages keep their rebuilt pages")
		XCTAssertEqual(document.sourceCaptureIDs, [ids[0], ids[1], newID, ids[2]])
		XCTAssertEqual(document.pages.count, 4)
		XCTAssertEqual(Set(document.staleCaptureIDs ?? []), [ids[1], newID])
		await result.reading.value
		XCTAssertFalse(try XCTUnwrap(scan.rebuiltDocument).hasStalePages, "both halves rebuilt and spliced in")

		// Deleting one half leaves the other's original.
		XCTAssertTrue(context.saveDeletion(removing: target.deleteWithOriginal(originals: store)))
		XCTAssertFalse(store.contains(ids[1]))
		XCTAssertNotNil(store.loadImage(for: newID))
	}

	func testASpreadScanNotYetRebuiltMovesFromSlidesToWordOnceSplit() async throws {
		let context = try makeContext()
		let store = makeStore()
		let scan = try makeScan(pageCount: 1, in: context)
		scan.output = .pptx
		let target = try XCTUnwrap(scan.capturesArray.first)
		try store.save(try XCTUnwrap(OriginalStore.encode(CIImage(cgImage: try spreadPhoto(width: 600, height: 300)))),
					   for: try XCTUnwrap(target.id))
		XCTAssertTrue(scan.looksLikeSlides, "a spread is wide")
		XCTAssertFalse(PageReprocessor.startsOnWord(scan))

		let halves = try XCTUnwrap(SpreadSplit.halves(of: .fullFrame, at: 0.5, quarterTurns: 0))
		var first = try XCTUnwrap(target.recipe)
		first.quad = halves.first
		var second = first
		second.quad = halves.second
		let result = try await PageReprocessor.split(target, first: first, second: second, originals: store)

		XCTAssertEqual(scan.output, .docx, "two book pages make a document")
		XCTAssertFalse(context.hasChanges, "saved")
		await result.reading.value
	}

	func testTheRebuiltDocumentTakesBothHalvesInPlaceOfThePage() throws {
		let ids = [UUID(), UUID(), UUID()]
		let newID = UUID()
		var document = RescrivaDocument(title: "Book", pages: ids.map { _ in RescrivaPage(blocks: []) }, sourceCaptureIDs: ids)
		document.pages[1].notes = [RescrivaNote(text: "Check the fold", created: Date(timeIntervalSinceReferenceDate: 700_000_000))]
		document.pages[1].sourceTextDigest = "abc"
		let split = try XCTUnwrap(PageSplice.splitting(ids[1], adding: newID, in: document, captureIDs: ids))
		XCTAssertEqual(split.sourceCaptureIDs, [ids[0], ids[1], newID, ids[2]])
		XCTAssertEqual(split.pages.map(\.id), [document.pages[0].id, document.pages[1].id, split.pages[2].id, document.pages[2].id])
		XCTAssertNotEqual(split.pages[2].id, document.pages[1].id)
		XCTAssertEqual(split.pages[1].notes, document.pages[1].notes, "the first half keeps the page's notes")
		XCTAssertTrue(split.pages[2].notes.isEmpty)
		XCTAssertNil(split.pages[1].sourceTextDigest)
		XCTAssertEqual(split.staleCaptureIDs, [ids[1], newID])
		XCTAssertNil(PageSplice.splitting(ids[1], adding: newID, in: document, captureIDs: ids.reversed()), "pages moved since the rebuild")
		XCTAssertNil(PageSplice.splitting(ids[1], adding: ids[2], in: document, captureIDs: ids), "the new page's id is taken")
	}

	// MARK: The editor

	func testTheEditorOffersTheSplitOnAWideCropAndSetsTheLineOnTheFold() async throws {
		let context = try makeContext()
		let store = makeStore()
		let scan = try makeScan(pageCount: 1, in: context)
		let capture = try XCTUnwrap(scan.capturesArray.first)
		capture.recipe = PageRecipe(quad: .fullFrame, mode: .document, rotation: 0, removeShadows: true, keepMarkerColors: false)
		let photo = try spreadPhoto(width: 800, height: 400, foldAt: 0.45)
		try store.save(try XCTUnwrap(OriginalStore.encode(CIImage(cgImage: photo))), for: try XCTUnwrap(capture.id))
		let model = PageEditorModel(capture: capture, originals: store)
		await model.load()
		XCTAssertTrue(model.canOfferSplit)
		model.rotate(by: 1)
		XCTAssertFalse(model.canOfferSplit, "turned upright, the crop is tall")
		model.undo()
		model.setMode(.whiteboard)
		XCTAssertFalse(model.canOfferSplit, "whiteboards are wide by nature")
		model.undo()

		await model.beginSplit()
		XCTAssertTrue(model.isSplitting)
		XCTAssertTrue(model.foundFold)
		let fraction = try XCTUnwrap(model.splitFraction)
		XCTAssertEqual(fraction, 0.45, accuracy: 0.03)
		model.nudgeSplit(by: 0.05)
		XCTAssertEqual(try XCTUnwrap(model.splitFraction), fraction + 0.05, accuracy: 1e-9)
		model.nudgeSplit(by: 1)
		XCTAssertEqual(model.splitFraction, SpreadSplit.Tuning.lineRange.upperBound, "kept off the edge")
		let line = try XCTUnwrap(model.splitLine)
		model.moveSplit(toward: CGPoint(x: 0.3, y: line.start.y))
		XCTAssertEqual(try XCTUnwrap(model.splitFraction), 0.3, accuracy: 1e-6)
		let recipes = try XCTUnwrap(model.splitRecipes)
		XCTAssertEqual(recipes.first.quad.topRight.x, 0.3, accuracy: 1e-6)
		XCTAssertEqual(recipes.second.quad.topLeft.x, 0.3, accuracy: 1e-6)
		XCTAssertEqual(recipes.first.mode, .document)
		XCTAssertEqual(recipes.second.rotation, 0)
		XCTAssertFalse(recipes.second.keepMarkerColors, "the page's own switches carry over")

		model.cancelSplit()
		XCTAssertNil(model.splitFraction)
		XCTAssertFalse(model.isSplitting)
		XCTAssertNil(model.splitRecipes)
		XCTAssertFalse(model.hasChanges, "looking for the fold changes nothing")
	}

	// MARK: Helpers

	private func assertQuad(_ quad: PageQuad, _ expected: [(Double, Double)], file: StaticString = #filePath, line: UInt = #line) {
		for (corner, point) in zip(quad.corners, expected) {
			XCTAssertEqual(corner.x, point.0, accuracy: 1e-9, file: file, line: line)
			XCTAssertEqual(corner.y, point.1, accuracy: 1e-9, file: file, line: line)
		}
	}

	private func assertSame(_ first: CGPoint, _ second: CGPoint, file: StaticString = #filePath, line: UInt = #line) {
		XCTAssertEqual(first.x, second.x, accuracy: 1e-9, file: file, line: line)
		XCTAssertEqual(first.y, second.y, accuracy: 1e-9, file: file, line: line)
	}

	/// Paper (235) with rows of dark dashes standing in for text, blank in `gutter` but for a soft
	/// shadow down its middle.
	private func spread(width: Int, height: Int, gutter: Range<Int>) -> StyleDetector.Gray {
		var pixels = [UInt8](repeating: 235, count: width * height)
		let middle = Double(gutter.lowerBound + gutter.upperBound) / 2
		let half = Double(gutter.count) / 2
		for y in 0..<height {
			let inLine = y % 9 < 4 && y > 8 && y < height - 8
			for x in 0..<width {
				if gutter.contains(x) {
					let shade = 60 * max(0, 1 - abs(Double(x) - middle) / max(half, 1))
					pixels[y * width + x] = UInt8(235 - shade)
				} else if inLine, x >= 16, x < width - 16, (x / 3 + y) % 4 != 0 {
					pixels[y * width + x] = 40
				}
			}
		}
		return StyleDetector.Gray(width: width, height: height, pixels: pixels)
	}

	/// A photo: a dark table with a spread of two pages of "text" in `page`, the fold `foldAt` across it.
	private func spreadPhoto(width: Int, height: Int, page: CGRect? = nil, foldAt fold: CGFloat = 0.5) throws -> CGImage {
		let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
		let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
											  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
		let paper = page ?? CGRect(x: 0, y: 0, width: width, height: height)
		context.setFillColor(CGColor(red: 0.2, green: 0.15, blue: 0.1, alpha: 1))
		context.fill(CGRect(x: 0, y: 0, width: width, height: height))
		context.setFillColor(CGColor(red: 0.95, green: 0.94, blue: 0.9, alpha: 1))
		context.fill(paper)
		context.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1))
		let foldX = paper.minX + paper.width * fold
		let margin = paper.width * 0.05
		let lineHeight = max(2, paper.height / 60)
		for row in stride(from: paper.minY + margin, to: paper.maxY - margin, by: lineHeight * 2.2) {
			for (start, end) in [(paper.minX + margin, foldX - margin), (foldX + margin, paper.maxX - margin)] where end > start {
				for word in stride(from: start, to: end, by: lineHeight * 4) {
					context.fill(CGRect(x: word, y: row, width: min(lineHeight * 3, end - word), height: lineHeight))
				}
			}
		}
		return try XCTUnwrap(context.makeImage())
	}

	/// A temporary originals folder, removed after the test.
	private func makeStore() -> OriginalStore {
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RescrivaSpread-\(UUID().uuidString)", isDirectory: true)
		addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
		return OriginalStore(directory: directory)
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

	/// A scan of `pageCount` pages, each with a recipe, a stored image and one recognized line.
	private func makeScan(pageCount: Int, in context: NSManagedObjectContext) throws -> Scan {
		let scan = try insert(Scan.self, "Scan", into: context)
		scan.id = UUID()
		for index in 0..<pageCount {
			let capture = try insert(ScanCapture.self, "ScanCapture", into: context)
			capture.id = UUID()
			capture.order = Int32(index)
			capture.createImage(fullSizedImage: UIImage(cgImage: try spreadPhoto(width: 200, height: 100)))
			capture.createThumbnail()
			capture.recipe = PageRecipe(quad: .fullFrame, mode: nil, rotation: 0, removeShadows: true, keepMarkerColors: true)
			scan.addToCaptures(capture)
			let item = try insert(ScanRecognizedItem.self, "ScanRecognizedItem", into: context)
			item.transcript = "Page \(index + 1)"
			capture.addToRecognizedItems(item)
		}
		try context.save()
		return scan
	}
}
