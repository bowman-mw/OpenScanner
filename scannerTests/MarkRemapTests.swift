//
//  MarkRemapTests.swift
//  Folio (fork of Open Scanner)
//
//  Annotate's marks follow the page under them: a quarter turn is exact, a
//  new crop puts each mark back on the same pixel of the original photo, an
//  unchanged crop leaves marks alone, a mark the crop leaves wholly off the
//  page goes, and a spread split gives each mark, whole, to the half its
//  middle is on — in the pure mapping, and through PageReprocessor's stored
//  marks.
//

import CoreData
import CoreImage
import UIKit
import XCTest
@testable import scanner

@MainActor
final class MarkRemapTests: XCTestCase {

	/// In-memory containers kept alive for the test's contexts.
	private var containers: [NSPersistentContainer] = []

	override func tearDown() {
		containers.removeAll()
		super.tearDown()
	}

	// MARK: Turning

	func testAQuarterTurnSendsAPointWhereItsPixelGoes() throws {
		let mark = PageMark(kind: .pen, points: [CGPoint(x: 0.1, y: 0.2)], color: 0, width: 0.01)
		let turned = try XCTUnwrap(MarkRemap.turned([mark], quarterTurns: 1, pageSize: CGSize(width: 300, height: 200)).first)
		XCTAssertEqual(turned.points, [CGPoint(x: 0.8, y: 0.1)])
		XCTAssertEqual(turned.width, 0.015, accuracy: 1e-12, "a share of the page's width, now its old height")
		XCTAssertEqual(turned.id, mark.id)

		let half = try XCTUnwrap(MarkRemap.turned([mark], quarterTurns: 2, pageSize: CGSize(width: 300, height: 200)).first)
		XCTAssertEqual(half.points, [CGPoint(x: 0.9, y: 0.8)])
		XCTAssertEqual(half.width, 0.01, "a half turn keeps the page's width")
		let back = try XCTUnwrap(MarkRemap.turned([mark], quarterTurns: 3, pageSize: CGSize(width: 300, height: 200)).first)
		XCTAssertEqual(back.points, [CGPoint(x: 0.2, y: 0.9)])
	}

	func testFourQuarterTurnsGiveTheSameMarksBack() {
		let marks = [
			PageMark(kind: .pen, points: [CGPoint(x: 0.1, y: 0.2), CGPoint(x: 0.123_45, y: 0.3), CGPoint(x: 0.4, y: 0.35)], color: 0xD0392B, width: 0.004),
			PageMark(kind: .rectangle, points: [CGPoint(x: 0.6, y: 0.7), CGPoint(x: 0.3, y: 0.55)], color: 0x2463C9, width: 0.003),
			PageMark(kind: .arrow, points: [CGPoint(x: 0.05, y: 0.95), CGPoint(x: 0.5, y: 0.5)], color: 0, width: 0.006),
		]
		var turned = marks
		var size = CGSize(width: 1700, height: 2200)
		for _ in 0..<4 {
			turned = MarkRemap.turned(turned, quarterTurns: 1, pageSize: size)
			size = CGSize(width: size.height, height: size.width)
		}
		XCTAssertEqual(turned.map(\.points), marks.map(\.points))
		XCTAssertEqual(turned.map(\.id), marks.map(\.id))
		for (after, before) in zip(turned, marks) {
			XCTAssertEqual(after.width, before.width, accuracy: 1e-12)
		}
		XCTAssertEqual(MarkRemap.turned(marks, quarterTurns: 4, pageSize: size), marks, "a whole turn is no turn")
	}

	// MARK: Cropping again

	func testAnUnchangedCropAndTurnLeaveMarksWhereTheyAre() throws {
		let crop = PageQuad(topLeft: CGPoint(x: 0.123_456, y: 0.1), topRight: CGPoint(x: 0.9, y: 0.12),
							bottomRight: CGPoint(x: 0.88, y: 0.9), bottomLeft: CGPoint(x: 0.1, y: 0.87))
		let old = PageRecipe(quad: crop, mode: .document, rotation: 1, removeShadows: true, keepMarkerColors: true)
		var new = old
		new.mode = .whiteboard
		new.removeShadows = false
		// The crop as it reads back from the page (five decimals) is the same crop.
		new.quad = try XCTUnwrap(PageQuad(storageString: crop.storageString))
		let marks = [PageMark(kind: .pen, points: [CGPoint(x: 0.333_333, y: 0.5)], color: 0, width: 0.004)]
		XCTAssertEqual(MarkRemap.recropped(marks, from: old, to: new, originalSize: CGSize(width: 4032, height: 3024)), marks)
	}

	func testANewCropMovesAMarkToWhereItsPixelOfThePhotoNowIs() throws {
		let old = PageRecipe(quad: .fullFrame, mode: .document, rotation: 0, removeShadows: true, keepMarkerColors: true)
		var new = old
		new.quad = PageQuad(topLeft: CGPoint(x: 0.25, y: 0.2), topRight: CGPoint(x: 0.75, y: 0.2),
							bottomRight: CGPoint(x: 0.75, y: 0.8), bottomLeft: CGPoint(x: 0.25, y: 0.8))
		new.rotation = 1
		let mark = PageMark(kind: .pen, points: [CGPoint(x: 0.3, y: 0.5), CGPoint(x: 0.5, y: 0.5)], color: 0, width: 0.01)

		let moved = try XCTUnwrap(MarkRemap.recropped([mark], from: old, to: new, originalSize: CGSize(width: 1000, height: 500)).first)
		// (0.3, 0.5) of the photo is (0.1, 0.5) of the crop, which a quarter turn puts at (0.5, 0.1).
		XCTAssertEqual(moved.points[0].x, 0.5, accuracy: 1e-5)
		XCTAssertEqual(moved.points[0].y, 0.1, accuracy: 1e-5)
		XCTAssertEqual(moved.points[1].x, 0.5, accuracy: 1e-5)
		XCTAssertEqual(moved.points[1].y, 0.5, accuracy: 1e-5)
		// The page was 1000 px wide on the photo; stood on end, the crop is 300 px wide.
		XCTAssertEqual(moved.width, 0.01 * 1000 / 300, accuracy: 1e-9)
		XCTAssertEqual(moved.id, mark.id)
	}

	func testANewPerspectiveCropAndTurnKeepEachMarkOnItsPixel() throws {
		let size = CGSize(width: 1200, height: 900)
		let oldQuad = PageQuad(topLeft: CGPoint(x: 0.1, y: 0.15), topRight: CGPoint(x: 0.85, y: 0.1),
							   bottomRight: CGPoint(x: 0.9, y: 0.9), bottomLeft: CGPoint(x: 0.05, y: 0.85))
		let newQuad = PageQuad(topLeft: CGPoint(x: 0.2, y: 0.2), topRight: CGPoint(x: 0.8, y: 0.25),
							   bottomRight: CGPoint(x: 0.75, y: 0.8), bottomLeft: CGPoint(x: 0.15, y: 0.75))
		let old = PageRecipe(quad: oldQuad, mode: .document, rotation: 1, removeShadows: true, keepMarkerColors: true)
		var new = old
		new.quad = newQuad
		new.rotation = 3
		// Where two spots of the new page were on the old one, through the photo.
		let targets = [CGPoint(x: 0.3, y: 0.4), CGPoint(x: 0.6, y: 0.7)]
		let toPhoto = try XCTUnwrap(Homography(unitSquareTo: newQuad))
		let fromPhoto = try XCTUnwrap(Homography(unitSquareTo: oldQuad)?.inverse)
		let sources = try targets.map { target -> CGPoint in
			let photo = try XCTUnwrap(toPhoto.apply(QuadViewMapping.unrotated(target, quarterTurns: 3)))
			return PageMark.quantized(QuadViewMapping.rotated(try XCTUnwrap(fromPhoto.apply(photo)), quarterTurns: 1))
		}
		let line = PageMark(kind: .line, points: sources, color: 0, width: 0.005)

		let moved = try XCTUnwrap(MarkRemap.recropped([line], from: old, to: new, originalSize: size).first)
		XCTAssertEqual(moved.points.count, 2, "a line keeps its two ends")
		for (point, target) in zip(moved.points, targets) {
			XCTAssertEqual(point.x, target.x, accuracy: 1e-4)
			XCTAssertEqual(point.y, target.y, accuracy: 1e-4)
		}
		// Both pages are stood on end, so each is as wide as its crop's sides are long.
		func sides(_ quad: PageQuad) -> CGFloat {
			let left = hypot((quad.bottomLeft.x - quad.topLeft.x) * size.width, (quad.bottomLeft.y - quad.topLeft.y) * size.height)
			let right = hypot((quad.bottomRight.x - quad.topRight.x) * size.width, (quad.bottomRight.y - quad.topRight.y) * size.height)
			return (left + right) / 2
		}
		XCTAssertEqual(moved.width, 0.005 * Double(sides(oldQuad) / sides(newQuad)), accuracy: 1e-9)
	}

	func testABoxKeepsTheBoxAroundItsFourMovedCorners() throws {
		let old = PageRecipe(quad: .fullFrame, mode: nil, rotation: 0, removeShadows: true, keepMarkerColors: true)
		var new = old
		new.rotation = 1
		// Drawn from the bottom-right up to the top-left.
		let box = PageMark(kind: .rectangle, points: [CGPoint(x: 0.6, y: 0.7), CGPoint(x: 0.2, y: 0.1)], color: 0, width: 0.004)
		let moved = try XCTUnwrap(MarkRemap.recropped([box], from: old, to: new, originalSize: CGSize(width: 400, height: 300)).first)
		// x' = 1 − y and y' = x: the box spans x 0.3…0.9 and y 0.2…0.6, kept as [min, max].
		XCTAssertEqual(moved.points.count, 2)
		XCTAssertEqual(moved.points[0].x, 0.3, accuracy: 1e-5)
		XCTAssertEqual(moved.points[0].y, 0.2, accuracy: 1e-5)
		XCTAssertEqual(moved.points[1].x, 0.9, accuracy: 1e-5)
		XCTAssertEqual(moved.points[1].y, 0.6, accuracy: 1e-5)
		XCTAssertEqual(moved.width, 0.004 * 400 / 300, accuracy: 1e-9)
	}

	func testAMarkTheNewCropLeavesWhollyOffThePageGoesButAClippedOneStays() throws {
		let old = PageRecipe(quad: .fullFrame, mode: .document, rotation: 0, removeShadows: true, keepMarkerColors: true)
		var new = old
		new.quad = PageQuad(topLeft: CGPoint(x: 0.25, y: 0.25), topRight: CGPoint(x: 0.75, y: 0.25),
							bottomRight: CGPoint(x: 0.75, y: 0.75), bottomLeft: CGPoint(x: 0.25, y: 0.75))
		let gone = PageMark(kind: .pen, points: [CGPoint(x: 0.05, y: 0.05), CGPoint(x: 0.1, y: 0.1)], color: 0, width: 0.004)
		let clipped = PageMark(kind: .line, points: [CGPoint(x: 0.1, y: 0.5), CGPoint(x: 0.5, y: 0.5)], color: 0, width: 0.004)
		// Both corners land off the page, but the oval's right side crosses it.
		let oval = PageMark(kind: .ellipse, points: [CGPoint(x: 0.3, y: 0.1), CGPoint(x: 0.7, y: 0.9)], color: 0, width: 0.004)

		let moved = MarkRemap.recropped([gone, clipped, oval], from: old, to: new, originalSize: CGSize(width: 1000, height: 1000))
		XCTAssertEqual(moved.map(\.id), [clipped.id, oval.id])
		let line = try XCTUnwrap(moved.first)
		XCTAssertEqual(line.points[0].x, -0.3, accuracy: 1e-5, "kept partly off the page")
		XCTAssertEqual(line.points[1].x, 0.5, accuracy: 1e-5)
		XCTAssertEqual(MarkRemap.recropped([gone], from: old, to: new, originalSize: CGSize(width: 1000, height: 1000)), [])
	}

	// MARK: Splitting a spread

	func testASplitGivesEachMarkWholeToTheHalfItsMiddleIsOn() throws {
		let spread = PageRecipe(quad: .fullFrame, mode: .document, rotation: 0, removeShadows: true, keepMarkerColors: true)
		let halves = try XCTUnwrap(SpreadSplit.halves(of: .fullFrame, at: 0.5, quarterTurns: 0))
		var first = spread
		first.quad = halves.first
		var second = spread
		second.quad = halves.second
		let left = PageMark(kind: .pen, points: [CGPoint(x: 0.2, y: 0.3), CGPoint(x: 0.3, y: 0.35)], color: 0, width: 0.004)
		// Its middle is just right of the fold.
		let box = PageMark(kind: .rectangle, points: [CGPoint(x: 0.45, y: 0.4), CGPoint(x: 0.6, y: 0.6)], color: 0, width: 0.004)
		let right = PageMark(kind: .line, points: [CGPoint(x: 0.8, y: 0.1), CGPoint(x: 0.9, y: 0.2)], color: 0, width: 0.004)
		// Its middle is just left of the fold.
		let arrow = PageMark(kind: .arrow, points: [CGPoint(x: 0.4, y: 0.5), CGPoint(x: 0.58, y: 0.5)], color: 0, width: 0.004)

		let pages = MarkRemap.split([left, box, right, arrow], from: spread, into: first, second, originalSize: CGSize(width: 1000, height: 500))
		XCTAssertEqual(pages.first.map(\.id), [left.id, arrow.id])
		XCTAssertEqual(pages.second.map(\.id), [box.id, right.id], "each mark on one page only")
		let movedLeft = try XCTUnwrap(pages.first.first)
		XCTAssertEqual(movedLeft.points[0].x, 0.4, accuracy: 1e-5)
		XCTAssertEqual(movedLeft.points[1].x, 0.6, accuracy: 1e-5)
		XCTAssertEqual(movedLeft.points[0].y, 0.3, accuracy: 1e-5)
		XCTAssertEqual(movedLeft.width, 0.008, accuracy: 1e-9, "each half is half as wide")
		let movedBox = try XCTUnwrap(pages.second.first)
		XCTAssertEqual(movedBox.points[0].x, -0.1, accuracy: 1e-5, "kept whole, partly off its page")
		XCTAssertEqual(movedBox.points[1].x, 0.2, accuracy: 1e-5)
		let movedArrow = try XCTUnwrap(pages.first.last)
		XCTAssertEqual(movedArrow.points[1].x, 1.16, accuracy: 1e-5)
	}

	// MARK: Stored marks

	func testRemakingAPageMovesItsStoredMarksAndACleanupChangeMovesNothing() async throws {
		let context = try makeContext()
		let originals = makeOriginals()
		let (annotations, folder) = makeAnnotations()
		let (_, capture) = try makePage(width: 200, height: 100, in: context, originals: originals)
		let id = try XCTUnwrap(capture.id)
		let mark = PageMark(kind: .pen, points: [CGPoint(x: 0.3, y: 0.5), CGPoint(x: 0.5, y: 0.5)], color: 0xD0392B, width: 0.01)
		try annotations.save([mark], for: id)
		let file = folder.appendingPathComponent(id.uuidString).appendingPathExtension("json")
		let written = try modificationDate(of: file)

		var cleaned = try XCTUnwrap(capture.recipe)
		cleaned.mode = .document
		await (try await PageReprocessor.apply(cleaned, to: capture, originals: originals, annotations: annotations)).value
		XCTAssertEqual(annotations.marks(for: id), [mark])
		XCTAssertEqual(try modificationDate(of: file), written, "nothing moved, nothing saved")

		var cropped = cleaned
		cropped.quad = PageQuad(topLeft: CGPoint(x: 0.2, y: 0.2), topRight: CGPoint(x: 0.8, y: 0.2),
								bottomRight: CGPoint(x: 0.8, y: 0.8), bottomLeft: CGPoint(x: 0.2, y: 0.8))
		cropped.rotation = 1
		await (try await PageReprocessor.apply(cropped, to: capture, originals: originals, annotations: annotations)).value
		let moved = try XCTUnwrap(AnnotationStore(folder: folder).marks(for: id).first, "saved")
		// (0.3, 0.5) of the photo is (1/6, 1/2) of the crop, which a quarter turn puts at (1/2, 1/6).
		XCTAssertEqual(moved.points[0].x, 0.5, accuracy: 1e-4)
		XCTAssertEqual(moved.points[0].y, 1.0 / 6, accuracy: 1e-4)
		XCTAssertEqual(moved.points[1].x, 0.5, accuracy: 1e-4)
		XCTAssertEqual(moved.points[1].y, 0.5, accuracy: 1e-4)
		XCTAssertEqual(moved.width, 0.01 * 200 / 60, accuracy: 1e-6, "200 px across before, 60 px once stood on end")
	}

	func testTurningAPageWithoutItsOriginalTurnsItsMarks() async throws {
		let context = try makeContext()
		let (annotations, _) = makeAnnotations()
		let (_, capture) = try makePage(width: 200, height: 100, in: context, originals: nil)
		let id = try XCTUnwrap(capture.id)
		let mark = PageMark(kind: .highlighter, points: [CGPoint(x: 0.1, y: 0.2)], color: 0xF2C94C, width: 0.02)
		try annotations.save([mark], for: id)

		await (try await PageReprocessor.rotateStoredPage(capture, to: 1, annotations: annotations)).value
		let turned = try XCTUnwrap(annotations.marks(for: id).first)
		XCTAssertEqual(turned.points, [CGPoint(x: 0.8, y: 0.1)])
		XCTAssertEqual(turned.width, 0.04, accuracy: 1e-9, "the 200 px page is now 100 px wide")

		await (try await PageReprocessor.rotateStoredPage(capture, to: 0, annotations: annotations)).value
		let back = try XCTUnwrap(annotations.marks(for: id).first)
		XCTAssertEqual(back.points, mark.points)
		XCTAssertEqual(back.width, mark.width, accuracy: 1e-9)
	}

	func testSplittingASpreadSharesItsMarksBetweenTheTwoPages() async throws {
		let context = try makeContext()
		let originals = makeOriginals()
		let (annotations, folder) = makeAnnotations()
		let (_, capture) = try makePage(width: 600, height: 300, in: context, originals: originals)
		let id = try XCTUnwrap(capture.id)
		let left = PageMark(kind: .pen, points: [CGPoint(x: 0.1, y: 0.5), CGPoint(x: 0.2, y: 0.5)], color: 0, width: 0.004)
		let right = PageMark(kind: .ellipse, points: [CGPoint(x: 0.7, y: 0.2), CGPoint(x: 0.9, y: 0.4)], color: 0, width: 0.004)
		try annotations.save([left, right], for: id)
		let halves = try XCTUnwrap(SpreadSplit.halves(of: .fullFrame, at: 0.5, quarterTurns: 0))
		var first = try XCTUnwrap(capture.recipe)
		first.quad = halves.first
		var second = first
		second.quad = halves.second

		let result = try await PageReprocessor.split(capture, first: first, second: second, originals: originals, annotations: annotations)
		let newID = try XCTUnwrap(result.second.id)
		XCTAssertEqual(annotations.marks(for: id).map(\.id), [left.id], "the page, now the first half, keeps its own")
		let moved = try XCTUnwrap(AnnotationStore(folder: folder).marks(for: newID).first, "saved")
		XCTAssertEqual(moved.id, right.id)
		XCTAssertEqual(moved.points[0].x, 0.4, accuracy: 1e-4)
		XCTAssertEqual(moved.points[1].x, 0.8, accuracy: 1e-4)
		XCTAssertEqual(moved.points[1].y, 0.4, accuracy: 1e-4)
		await result.reading.value
	}

	// MARK: Helpers

	/// A temporary originals folder, removed after the test.
	private func makeOriginals() -> OriginalStore {
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FolioMarkOriginals-\(UUID().uuidString)", isDirectory: true)
		addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
		return OriginalStore(directory: directory)
	}

	/// A store in a temporary annotations folder, removed after the test, and the folder.
	private func makeAnnotations() -> (store: AnnotationStore, folder: URL) {
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FolioMarks-\(UUID().uuidString)", isDirectory: true)
		addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
		return (AnnotationStore(folder: directory), directory)
	}

	private func modificationDate(of url: URL) throws -> Date {
		try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
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

	/// A one-page scan whose page has a full-frame recipe and a stored image of `width` × `height`,
	/// and the same picture as its original in `originals` (none when nil).
	private func makePage(width: Int, height: Int, in context: NSManagedObjectContext,
						  originals: OriginalStore?) throws -> (Scan, ScanCapture) {
		let scan = try XCTUnwrap(NSEntityDescription.insertNewObject(forEntityName: "Scan", into: context) as? Scan)
		scan.id = UUID()
		let capture = try XCTUnwrap(NSEntityDescription.insertNewObject(forEntityName: "ScanCapture", into: context) as? ScanCapture)
		capture.id = UUID()
		let image = try makeImage(width: width, height: height)
		capture.createImage(fullSizedImage: UIImage(cgImage: image))
		capture.createThumbnail()
		capture.recipe = PageRecipe(quad: .fullFrame, mode: nil, rotation: 0, removeShadows: true, keepMarkerColors: true)
		scan.addToCaptures(capture)
		if let originals {
			try originals.save(try XCTUnwrap(OriginalStore.encode(CIImage(cgImage: image))), for: try XCTUnwrap(capture.id))
		}
		try context.save()
		return (scan, capture)
	}

	/// A white image with a dark block in its top-left corner.
	private func makeImage(width: Int, height: Int) throws -> CGImage {
		let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
		let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
											  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
		context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
		context.fill(CGRect(x: 0, y: 0, width: width, height: height))
		context.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1))
		context.fill(CGRect(x: 0, y: height - height / 4, width: width / 5, height: height / 4))
		return try XCTUnwrap(context.makeImage())
	}
}
