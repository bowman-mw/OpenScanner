//
//  AnnotationTests.swift
//  Rescriva (fork of Open Scanner)
//
//  Annotate's logic: saving marks, the eraser's reach, shape snapping,
//  stroke thinning, undo/redo, and that marks are drawn — highlights under
//  the words, shapes on top — in previews and the exported PDF.
//

import XCTest
import PDFKit
import UIKit
@testable import scanner

@MainActor
final class AnnotationTests: XCTestCase {
	private var folder: URL!
	private var defaults: UserDefaults!
	private var suiteName = ""

	override func setUp() {
		super.setUp()
		folder = FileManager.default.temporaryDirectory.appendingPathComponent("AnnotationTests-\(UUID().uuidString)", isDirectory: true)
		suiteName = "AnnotationTests-\(UUID().uuidString)"
		defaults = UserDefaults(suiteName: suiteName)
	}

	override func tearDown() {
		try? FileManager.default.removeItem(at: folder)
		defaults.removePersistentDomain(forName: suiteName)
		super.tearDown()
	}

	// MARK: Saving

	func testMarksRoundTripThroughJSON() throws {
		let mark = PageMark(kind: .pen, points: [CGPoint(x: 0.1, y: 0.2), CGPoint(x: 0.35, y: 0.4)], color: 0xD0392B, width: 0.0045)
		let data = try JSONEncoder.rescriva.encode(PageAnnotations(marks: [mark]))
		let decoded = try JSONDecoder.rescriva.decode(PageAnnotations.self, from: data)

		let first = try XCTUnwrap(decoded.marks.first)
		XCTAssertEqual(first.id, mark.id)
		XCTAssertEqual(first.kind, .pen)
		XCTAssertEqual(first.color, 0xD0392B)
		XCTAssertEqual(first.points.count, 2)
		XCTAssertEqual(first.points[1].x, 0.35, accuracy: 0.000_01)
		XCTAssertEqual(first.points[1].y, 0.4, accuracy: 0.000_01)
	}

	func testAMarkThisVersionCannotReadIsSkippedNotThePage() throws {
		let json = """
		{"version": 2, "marks": [
			{"id": "\(UUID().uuidString)", "kind": "stamp", "points": [0.1, 0.1], "color": 0, "width": 0.01},
			{"id": "\(UUID().uuidString)", "kind": "line", "points": [0.1, 0.1, 0.5, 0.5], "color": 0, "width": 0.01}
		]}
		"""
		let decoded = try JSONDecoder.rescriva.decode(PageAnnotations.self, from: Data(json.utf8))
		XCTAssertEqual(decoded.marks.map(\.kind), [.line])
	}

	func testStoreWritesAPageFileAndRemovesItWhenEmpty() throws {
		let store = AnnotationStore(folder: folder)
		let pageID = UUID()
		let mark = PageMark(kind: .rectangle, points: [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.4, y: 0.3)], color: 0x2463C9, width: 0.004)
		let file = folder.appendingPathComponent(pageID.uuidString + ".json")

		try store.save([mark], for: pageID)
		XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
		XCTAssertEqual(AnnotationStore(folder: folder).marks(for: pageID), store.marks(for: pageID))
		XCTAssertEqual(store.marks(for: pageID).first?.kind, .rectangle)

		try store.save([], for: pageID)
		XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
		XCTAssertTrue(AnnotationStore(folder: folder).marks(for: pageID).isEmpty)
	}

	// MARK: Eraser

	func testEraserReachesAStrokeByItsInkNotFurther() {
		let size = CGSize(width: 400, height: 500)
		let stroke = PageMark(kind: .pen, points: [CGPoint(x: 0.1, y: 0.5), CGPoint(x: 0.9, y: 0.5)], color: 0, width: 0.01)
		// The stroke runs along y = 250 and is 4 pt thick.
		XCTAssertTrue(MarkGeometry.eraser(at: CGPoint(x: 200, y: 262), radius: 12, hits: stroke, in: size))
		XCTAssertFalse(MarkGeometry.eraser(at: CGPoint(x: 200, y: 270), radius: 12, hits: stroke, in: size))
		XCTAssertFalse(MarkGeometry.eraser(at: CGPoint(x: 10, y: 250), radius: 12, hits: stroke, in: size))
	}

	func testEraserTakesShapesByTheirOutlineNotTheirMiddle() {
		let size = CGSize(width: 400, height: 400)
		let box = PageMark(kind: .rectangle, points: [CGPoint(x: 0.25, y: 0.25), CGPoint(x: 0.75, y: 0.75)], color: 0, width: 0.005)
		let ring = PageMark(kind: .ellipse, points: [CGPoint(x: 0.75, y: 0.75), CGPoint(x: 0.25, y: 0.25)], color: 0, width: 0.005)

		XCTAssertTrue(MarkGeometry.eraser(at: CGPoint(x: 200, y: 102), radius: 8, hits: box, in: size))
		XCTAssertFalse(MarkGeometry.eraser(at: CGPoint(x: 200, y: 200), radius: 8, hits: box, in: size))
		XCTAssertTrue(MarkGeometry.eraser(at: CGPoint(x: 300, y: 200), radius: 8, hits: ring, in: size))
		XCTAssertFalse(MarkGeometry.eraser(at: CGPoint(x: 200, y: 200), radius: 8, hits: ring, in: size))
		XCTAssertFalse(MarkGeometry.eraser(at: CGPoint(x: 290, y: 290), radius: 8, hits: ring, in: size), "The ring's corner gap is not ink")
	}

	// MARK: Shapes and strokes

	func testLinesSnapToLevelOnlyWhenNearlyLevel() {
		let start = CGPoint(x: 0, y: 0)
		let nearlyLevel = CGPoint(x: 100, y: 5)    // ≈ 2.9°
		let snapped = MarkGeometry.snappedEnd(for: .line, from: start, to: nearlyLevel)
		XCTAssertEqual(snapped.y, 0, accuracy: 0.001)
		XCTAssertEqual(snapped.x, hypot(100, 5), accuracy: 0.001)

		let slanted = CGPoint(x: 100, y: 18)       // ≈ 10°
		XCTAssertEqual(MarkGeometry.snappedEnd(for: .arrow, from: start, to: slanted), slanted)

		let nearlyDiagonal = CGPoint(x: 100, y: 95)
		let diagonal = MarkGeometry.snappedEnd(for: .line, from: start, to: nearlyDiagonal)
		XCTAssertEqual(diagonal.x, diagonal.y, accuracy: 0.001)
	}

	func testNearlyEvenShapesBecomeSquaresAndCircles() {
		let start = CGPoint(x: 50, y: 50)
		let square = MarkGeometry.snappedEnd(for: .rectangle, from: start, to: CGPoint(x: 150, y: 145))
		XCTAssertEqual(square, CGPoint(x: 150, y: 150))
		let circleUpLeft = MarkGeometry.snappedEnd(for: .ellipse, from: start, to: CGPoint(x: -46, y: -50))
		XCTAssertEqual(circleUpLeft, CGPoint(x: -50, y: -50))
		let wide = CGPoint(x: 150, y: 120)
		XCTAssertEqual(MarkGeometry.snappedEnd(for: .rectangle, from: start, to: wide), wide)
		XCTAssertEqual(MarkGeometry.snappedEnd(for: .pen, from: start, to: CGPoint(x: 150, y: 149)), CGPoint(x: 150, y: 149))
	}

	func testStrokeThinningKeepsTheEndsAndCorners() {
		let straight = (0...50).map { CGPoint(x: CGFloat($0) * 2, y: 10) }
		XCTAssertEqual(MarkGeometry.simplified(straight, tolerance: 0.3), [CGPoint(x: 0, y: 10), CGPoint(x: 100, y: 10)])

		let elbow = (0...20).map { CGPoint(x: CGFloat($0) * 5, y: 0) } + (1...20).map { CGPoint(x: 100, y: CGFloat($0) * 5) }
		let thinned = MarkGeometry.simplified(elbow, tolerance: 0.3)
		XCTAssertEqual(thinned, [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 100)])
	}

	// MARK: Editing

	func testHistoryUndoesAndRedoesAndStaysBounded() {
		var history = MarkHistory()
		let mark = PageMark(kind: .line, points: [.zero, CGPoint(x: 1, y: 1)], color: 0, width: 0.004)
		history.record([])
		XCTAssertEqual(history.undo(from: [mark]), [])
		XCTAssertEqual(history.redo(from: []), [mark])
		XCTAssertNil(history.redo(from: [mark]))

		for _ in 0..<(MarkHistory.limit + 25) {
			history.record([mark])
		}
		XCTAssertEqual(history.undoStack.count, MarkHistory.limit)
		XCTAssertFalse(history.canRedo)
	}

	func testSessionEditsUndoesAndSavesOnlyOnDone() throws {
		let store = AnnotationStore(folder: folder)
		let pages = [AnnotationSession.Page(id: UUID()) { nil }, AnnotationSession.Page(id: UUID()) { nil }]
		let session = AnnotationSession(pages: pages, store: store, defaults: defaults)
		let ink = PageMark(kind: .pen, points: [CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.3, y: 0.3)], color: 0, width: 0.004)
		let box = PageMark(kind: .rectangle, points: [CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.6, y: 0.6)], color: 0, width: 0.004)

		session.add(ink)
		session.add(box)
		session.erase([ink.id])
		XCTAssertEqual(session.currentMarks, [box])
		session.undo()
		XCTAssertEqual(session.currentMarks, [ink, box])
		XCTAssertTrue(session.hasChanges)
		XCTAssertTrue(store.marks(for: pages[0].id).isEmpty, "Nothing is written before Done")

		session.showPage(1)
		XCTAssertTrue(session.currentMarks.isEmpty)
		XCTAssertFalse(session.canUndo, "Each page keeps its own history")

		try session.save()
		XCTAssertEqual(AnnotationStore(folder: folder).marks(for: pages[0].id), [ink, box])
		XCTAssertTrue(AnnotationStore(folder: folder).marks(for: pages[1].id).isEmpty)
	}

	func testClearPageIsOneUndoableStep() {
		let pageID = UUID()
		let session = AnnotationSession(pages: [AnnotationSession.Page(id: pageID) { nil }], store: AnnotationStore(folder: folder), defaults: defaults)
		let marks = (0..<3).map { PageMark(kind: .line, points: [CGPoint(x: 0.1, y: Double($0) / 10), CGPoint(x: 0.9, y: 0.5)], color: 0, width: 0.004) }
		marks.forEach(session.add)

		session.clearPage()
		XCTAssertTrue(session.currentMarks.isEmpty)
		session.undo()
		XCTAssertEqual(session.currentMarks, marks)
	}

	func testAPageShowsAsStoredUntilItsLookIsRendered() async throws {
		let images = [UIColor.white, .black, .red, .blue, .green].map { solidImage(size: CGSize(width: 30, height: 40), color: $0) { _ in } }
		let pages = [AnnotationSession.Page(id: UUID(), loadImage: { images[0] }, loadLooked: { images[1] }),
					 AnnotationSession.Page(id: UUID(), loadImage: { images[2] }, loadLooked: { images[3] }),
					 AnnotationSession.Page(id: UUID()) { images[4] }]
		let session = AnnotationSession(pages: pages, store: AnnotationStore(folder: folder), defaults: defaults)

		XCTAssertTrue(session.currentImage === images[0], "the page as stored shows at once")
		await session.renderLook()
		XCTAssertTrue(session.currentImage === images[1], "then the page with its look")

		session.showPage(1)
		XCTAssertTrue(session.currentImage === images[2])
		await session.renderLook()
		XCTAssertTrue(session.currentImage === images[3])
		session.showPage(0)
		XCTAssertTrue(session.currentImage === images[0], "a page visited again shows as stored until its look is back")
		await session.renderLook()
		XCTAssertTrue(session.currentImage === images[1])

		session.showPage(2)
		await session.renderLook()
		XCTAssertTrue(session.currentImage === images[4], "a page without a look stays as stored")
	}

	func testTheWholePageLookKeepsThePageSize() async throws {
		let page = solidImage(size: CGSize(width: 120, height: 160), color: .white) { context in
			UIColor.darkGray.setFill()
			context.fill(CGRect(x: 20, y: 20, width: 40, height: 10))
		}
		let data = try XCTUnwrap(page.jpegData(compressionQuality: 0.9))
		let renderer = LookPreviewRenderer()

		let rendered = await renderer.page(.gray, of: data)
		let looked = try XCTUnwrap(rendered)

		XCTAssertEqual(looked.size, page.size, "the same page in the canvas, with no relayout as the look arrives")
	}

	func testToolStylesAreRememberedPerGroup() {
		let page = AnnotationSession.Page(id: UUID()) { nil }
		let first = AnnotationSession(pages: [page], store: AnnotationStore(folder: folder), defaults: defaults)
		XCTAssertEqual(first.brush.color, MarkPalette.ink[0].rgb, "Pens start black")
		first.selectTool(.highlighter)
		first.selectColor(2)
		first.selectSize(0)
		first.selectTool(.rectangle)
		XCTAssertEqual(first.brush.color, MarkPalette.ink[1].rgb, "Shapes start red")

		let second = AnnotationSession(pages: [page], store: AnnotationStore(folder: folder), defaults: defaults)
		XCTAssertEqual(second.tool, .rectangle)
		second.selectTool(.highlighter)
		XCTAssertEqual(second.brush.color, MarkPalette.highlighter[2].rgb)
		XCTAssertEqual(second.brush.width, MarkPalette.widths(for: .highlighter)[0])
		second.selectTool(.eraser)
		XCTAssertNil(second.currentStyle)
	}

	// MARK: Drawing

	func testHighlightsMultiplySoWordsStayDarkAndShapesDrawOnTop() throws {
		let page = solidImage(size: CGSize(width: 200, height: 200), color: .white) { context in
			UIColor.black.setFill()
			context.fill(CGRect(x: 90, y: 90, width: 20, height: 20))   // a "word"
		}
		let highlight = PageMark(kind: .highlighter, points: [CGPoint(x: 0.1, y: 0.5), CGPoint(x: 0.9, y: 0.5)], color: 0xFFE14D, width: 0.1)
		let box = PageMark(kind: .rectangle, points: [CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.8, y: 0.8)], color: 0xD0392B, width: 0.02)
		// The box is listed first but still draws over the highlight.
		let flattened = MarkRenderer.flattened(page, marks: [box, highlight])

		let word = try pixel(flattened, at: CGPoint(x: 100, y: 100))
		XCTAssertLessThan(word.r + word.g + word.b, 30, "Text under a highlight stays dark")
		let paper = try pixel(flattened, at: CGPoint(x: 60, y: 100))
		XCTAssertGreaterThan(paper.r, 240)
		XCTAssertGreaterThan(paper.g, 200)
		XCTAssertLessThan(paper.b, 120, "Highlighted paper turns yellow")
		let edge = try pixel(flattened, at: CGPoint(x: 40, y: 100))
		XCTAssertGreaterThan(edge.r, 180)
		XCTAssertLessThan(edge.g, 90, "The box's red edge sits on top of the highlight")
		let outside = try pixel(flattened, at: CGPoint(x: 100, y: 20))
		XCTAssertGreaterThan(outside.r + outside.g + outside.b, 740, "Untouched paper stays white")
	}

	func testSearchablePDFCarriesThePageMarks() throws {
		let image = solidImage(size: CGSize(width: 612, height: 792), color: .white) { _ in }
		let arrow = PageMark(kind: .arrow, points: [CGPoint(x: 0.1, y: 0.5), CGPoint(x: 0.9, y: 0.5)], color: 0x2463C9, width: 0.02)
		let data = SearchablePDF.render([SearchablePDF.Page(image: image, lines: [], marks: [arrow])], title: "Marked")
		let page = try XCTUnwrap(PDFDocument(data: data)?.page(at: 0))
		let bounds = page.bounds(for: .mediaBox)
		let rendered = page.thumbnail(of: bounds.size, for: .mediaBox)

		let shaft = try pixel(rendered, at: CGPoint(x: bounds.width * 0.5, y: bounds.height * 0.5))
		XCTAssertLessThan(shaft.r, 90)
		XCTAssertGreaterThan(shaft.b, 150, "The blue arrow is drawn into the PDF page")
		let blank = try pixel(rendered, at: CGPoint(x: bounds.width * 0.5, y: bounds.height * 0.2))
		XCTAssertGreaterThan(blank.r + blank.g + blank.b, 740)
	}

	// MARK: Helpers

	private func solidImage(size: CGSize, color: UIColor, draw: (CGContext) -> Void) -> UIImage {
		let format = UIGraphicsImageRendererFormat()
		format.scale = 1
		format.opaque = true
		return UIGraphicsImageRenderer(size: size, format: format).image { context in
			color.setFill()
			context.fill(CGRect(origin: .zero, size: size))
			draw(context.cgContext)
		}
	}

	/// The RGB value at `point` (in points, top-left origin).
	private func pixel(_ image: UIImage, at point: CGPoint) throws -> (r: Int, g: Int, b: Int) {
		let cgImage = try XCTUnwrap(image.cgImage)
		var bytes = [UInt8](repeating: 0, count: 4)
		let context = try XCTUnwrap(CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
											  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
		let scale = image.scale
		let x = point.x * scale
		let y = point.y * scale
		// Shift the image so the wanted pixel lands on the 1×1 canvas (CG's origin is bottom-left).
		context.draw(cgImage, in: CGRect(x: -x, y: y - CGFloat(cgImage.height) + 1, width: CGFloat(cgImage.width), height: CGFloat(cgImage.height)))
		return (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]))
	}
}
