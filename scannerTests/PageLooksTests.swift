//
//  PageLooksTests.swift
//  Folio (fork of Open Scanner)
//
//  The page looks on synthetic pages drawn with UIKit: true black and white
//  (Sauvola) on text under a shadow gradient, the Ink look on a whiteboard of
//  thin and thick marker strokes, the stroke-width estimate, the stored look
//  tokens, and the preview made by the export's own recipe.
//

import UIKit
import XCTest
@testable import scanner

final class PageLooksTests: XCTestCase {

	// MARK: Stored tokens

	func testLookRawValuesAreUnchangedSoExistingScansDecode() {
		XCTAssertEqual(LookFilter.color.rawValue, "color")
		XCTAssertEqual(LookFilter.gray.rawValue, "gray")
		XCTAssertEqual(LookFilter.blackAndWhite.rawValue, "bw")
		XCTAssertEqual(LookFilter.original.rawValue, "original")
		XCTAssertEqual(LookFilter.ink.rawValue, "ink")
		for token in ["color", "gray", "bw", "original", "ink"] {
			XCTAssertEqual(LookFilter(rawValue: token)?.rawValue, token)
		}
		XCTAssertEqual(LookFilter.allCases, [.color, .gray, .blackAndWhite, .ink, .original])
	}

	// MARK: Black and white

	func testSauvolaTurnsShadedPaperWhiteAndKeepsTheText() throws {
		let page = try ShadedTextPage()

		let result = try TestPixels(LookRenderer.apply(.blackAndWhite, to: page.image))

		XCTAssertEqual(result.width, page.mask.width)
		XCTAssertEqual(result.height, page.mask.height)
		var paper = 0, whitePaper = 0, ink = 0, blackInk = 0, levels = Set<UInt8>()
		for index in 0..<(result.width * result.height) {
			let level = result.red(at: index)
			levels.insert(level)
			if page.mask.red(at: index) == 255 {
				paper += 1
				if level > 127 { whitePaper += 1 }
			} else if page.mask.red(at: index) < 60 {
				ink += 1
				if level < 128 { blackInk += 1 }
			}
		}
		XCTAssertGreaterThan(paper, 1_000_000)
		XCTAssertGreaterThan(ink, 10_000)
		XCTAssertGreaterThan(Double(whitePaper) / Double(paper), 0.99, "the shadow is gone")
		XCTAssertGreaterThan(Double(blackInk) / Double(ink), 0.95, "the text keeps its strokes")
		XCTAssertTrue(levels.isSubset(of: [0, 255]), "only black and white: \(levels.sorted().prefix(8))")
	}

	func testABlankShadedPageIsAllWhite() throws {
		let image = try TestDrawing(width: 600, height: 800).image { context, size in
			TestDrawing.shade(context, size: size, from: 0.92, to: 0.5)
		}

		let result = try TestPixels(LookRenderer.apply(.blackAndWhite, to: image))

		let white = (0..<(result.width * result.height)).filter { result.red(at: $0) > 127 }.count
		XCTAssertEqual(white, result.width * result.height, "no speckle on bare paper")
	}

	// MARK: Ink

	func testInkKeepsThinStrokesAndDoesNotHollowThickOnes() throws {
		let board = try Whiteboard()

		let result = try TestPixels(LookRenderer.apply(.ink, to: board.image))

		XCTAssertLessThan(result.luma(at: board.thinStroke), 0.35, "a 3 px line stays dark")
		XCTAssertLessThan(result.luma(at: board.thickBlackCentre), 0.35, "the middle of a 40 px stroke stays dark")
		let red = result.colour(at: board.thickRedCentre)
		XCTAssertGreaterThan(red.red, 0.6, "the red marker keeps its colour: \(red)")
		XCTAssertLessThan(red.green, 0.3)
		XCTAssertLessThan(red.blue, 0.3)
		for point in board.bareBoard {
			XCTAssertGreaterThan(result.luma(at: point), 0.93, "the shaded board at \(point) is white")
		}
	}

	func testStrokeWidthFollowsTheThickerStrokes() throws {
		let thin = try TestDrawing(width: 1200, height: 900).image { context, size in
			TestDrawing.fill(context, size: size, level: 0.96)
			TestDrawing.lines(context, count: 14, width: 4, from: 80, to: 1100, top: 80, gap: 50)
		}
		let thick = try TestDrawing(width: 1200, height: 900).image { context, size in
			TestDrawing.fill(context, size: size, level: 0.96)
			TestDrawing.lines(context, count: 4, width: 40, from: 80, to: 1100, top: 120, gap: 180)
		}
		let blank = try TestDrawing(width: 1200, height: 900).image { context, size in
			TestDrawing.fill(context, size: size, level: 0.96)
		}

		let thinWidth = try XCTUnwrap(strokeWidth(of: thin))
		let thickWidth = try XCTUnwrap(strokeWidth(of: thick))

		XCTAssertTrue((3...9).contains(thinWidth), "4 px lines measure \(thinWidth)")
		XCTAssertTrue((32...64).contains(thickWidth), "40 px strokes measure \(thickWidth)")
		XCTAssertNil(try strokeWidth(of: blank), "nothing to measure on a bare page")
	}

	func testQuantileReadsTheHistogram() {
		var histogram = [CGFloat](repeating: 0, count: 256)
		histogram[25] = 2
		histogram[200] = 98
		XCTAssertEqual(PageLooks.quantile(histogram, 0.01), 25.5 / 256, accuracy: 1e-9)
		XCTAssertEqual(PageLooks.quantile(histogram, 0.02), 25.5 / 256, accuracy: 1e-9)
		XCTAssertEqual(PageLooks.quantile(histogram, 0.5), 200.5 / 256, accuracy: 1e-9)
		XCTAssertEqual(PageLooks.quantile([CGFloat](repeating: 0, count: 8), 0.5), 0.5, "an empty histogram says nothing")
	}

	// MARK: Renderer and preview

	func testEveryLookKeepsThePageSizeAndOriginalIsUntouched() throws {
		let image = try TestDrawing(width: 300, height: 400).image { context, size in
			TestDrawing.fill(context, size: size, level: 0.9)
			TestDrawing.lines(context, count: 5, width: 3, from: 20, to: 280, top: 40, gap: 60)
		}
		for look in LookFilter.allCases {
			let result = LookRenderer.apply(look, to: image)
			XCTAssertEqual(result.size, image.size, "\(look)")
		}
		XCTAssertTrue(LookRenderer.apply(.original, to: image) === image)
	}

	func testThePreviewIsTheExportsLookScaledForTheScreen() throws {
		let page = try ShadedTextPage()
		let data = try XCTUnwrap(page.image.jpegData(compressionQuality: 0.9))
		let stored = try XCTUnwrap(UIImage(data: data))

		let preview = try XCTUnwrap(LookRenderer.preview(.blackAndWhite, of: data, maxPixels: 800))
		let export = try XCTUnwrap(PDFImageEncoder.scaled(LookRenderer.apply(.blackAndWhite, to: stored), maxPixels: 800))

		XCTAssertEqual(max(preview.size.width, preview.size.height), 800)
		let (shown, written) = (try TestPixels(preview), try TestPixels(export))
		XCTAssertEqual(shown.bytes, written.bytes, "what the preview shows is what the PDF gets")
		XCTAssertNil(LookRenderer.preview(.ink, of: Data("not an image".utf8), maxPixels: 800))
	}

	func testPreviewRequestsNamePageLookAndSize() {
		let data = Data((0..<4096).map { UInt8($0 % 251) })
		let request = LookPreviewRequest(data: data, look: .ink, maxPixels: 1600, page: "a")
		XCTAssertEqual(request.key, "a·ink·1600")
		XCTAssertEqual(request.resized(to: 200).key, "a·ink·200")
		var changed = data
		changed[2048] ^= 0xFF
		XCTAssertNotEqual(LookPreviewRequest.fingerprint(changed), LookPreviewRequest.fingerprint(data), "a re-made page is a new page")
		XCTAssertEqual(LookPreviewRequest.fingerprint(data), LookPreviewRequest.fingerprint(Data(data)))
	}

	// MARK: Helpers

	private func strokeWidth(of image: UIImage) throws -> CGFloat? {
		let input = try XCTUnwrap(CIImage(image: image)).applyingFilter("CILinearToSRGBToneCurve")
		return PageLooks.strokeWidth(of: input, context: CIContext())
	}
}

// MARK: - Synthetic pages

/// Draws test images at one pixel per point, top-left origin.
struct TestDrawing {
	let width: Int
	let height: Int

	func image(_ draw: (CGContext, CGSize) -> Void) throws -> UIImage {
		let format = UIGraphicsImageRendererFormat()
		format.scale = 1
		format.opaque = true
		format.preferredRange = .standard
		let size = CGSize(width: width, height: height)
		let image = UIGraphicsImageRenderer(size: size, format: format).image { draw($0.cgContext, size) }
		XCTAssertEqual(image.size, size)
		return image
	}

	static func fill(_ context: CGContext, size: CGSize, level: CGFloat) {
		context.setFillColor(gray: level, alpha: 1)
		context.fill(CGRect(origin: .zero, size: size))
	}

	/// Paper lit from the top-left: `from` there, falling to `to` at the bottom-right.
	static func shade(_ context: CGContext, size: CGSize, from light: CGFloat, to dark: CGFloat) {
		let space = CGColorSpaceCreateDeviceGray()
		guard let gradient = CGGradient(colorSpace: space, colorComponents: [light, 1, dark, 1], locations: [0, 1], count: 2) else { return }
		context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
	}

	/// `count` horizontal black lines `width` px thick, `gap` apart from `top`.
	static func lines(_ context: CGContext, count: Int, width: CGFloat, from left: CGFloat, to right: CGFloat, top: CGFloat, gap: CGFloat) {
		context.setFillColor(gray: 0.08, alpha: 1)
		for index in 0..<count {
			context.fill(CGRect(x: left, y: top + CGFloat(index) * gap, width: right - left, height: width))
		}
	}
}

/// Lines of text on paper shaded from 0.95 to 0.45, and the same text alone on white (`mask`).
private struct ShadedTextPage {
	let image: UIImage
	let mask: TestPixels

	init() throws {
		let drawing = TestDrawing(width: 1200, height: 1600)
		let lines = (0..<24).map { "The enzyme becomes saturated as trial \($0) shows, so we retry." }
		let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 26), .foregroundColor: UIColor.black]
		func text(_ context: CGContext) {
			for (index, line) in lines.enumerated() {
				(line as NSString).draw(at: CGPoint(x: 70, y: 110 + CGFloat(index) * 52), withAttributes: attributes)
			}
		}
		image = try drawing.image { context, size in
			TestDrawing.shade(context, size: size, from: 0.95, to: 0.45)
			text(context)
		}
		mask = try TestPixels(try drawing.image { context, size in
			TestDrawing.fill(context, size: size, level: 1)
			text(context)
		})
	}
}

/// A shaded whiteboard with thin lines, a thick black stroke and a thick red one.
private struct Whiteboard {
	let image: UIImage
	let thinStroke = CGPoint(x: 500, y: 801)
	let thickBlackCentre = CGPoint(x: 400, y: 300)
	let thickRedCentre = CGPoint(x: 1150, y: 300)
	let bareBoard = [CGPoint(x: 1500, y: 1100), CGPoint(x: 60, y: 60), CGPoint(x: 1150, y: 700), CGPoint(x: 800, y: 1150)]

	init() throws {
		image = try TestDrawing(width: 1600, height: 1200).image { context, size in
			TestDrawing.shade(context, size: size, from: 0.97, to: 0.8)
			TestDrawing.lines(context, count: 8, width: 3, from: 120, to: 900, top: 800, gap: 40)
			context.setFillColor(gray: 0.1, alpha: 1)
			context.fill(CGRect(x: 120, y: 280, width: 700, height: 40))
			context.fill(CGRect(x: 120, y: 120, width: 40, height: 400))
			context.setFillColor(red: 0.85, green: 0.1, blue: 0.1, alpha: 1)
			context.fill(CGRect(x: 950, y: 280, width: 500, height: 40))
		}
	}
}

/// An image's RGBA8 sRGB pixels, rows top to bottom.
struct TestPixels {
	let width: Int
	let height: Int
	let bytes: [UInt8]

	init(_ image: UIImage) throws {
		let cgImage = try XCTUnwrap(image.cgImage)
		width = cgImage.width
		height = cgImage.height
		let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
		let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
											  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
		context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
		let data = try XCTUnwrap(context.makeImage()?.dataProvider?.data as Data?)
		bytes = [UInt8](data)
		XCTAssertEqual(bytes.count, width * height * 4)
	}

	func red(at index: Int) -> UInt8 { bytes[index * 4] }

	func colour(at point: CGPoint) -> (red: Double, green: Double, blue: Double) {
		let index = (Int(point.y) * width + Int(point.x)) * 4
		return (Double(bytes[index]) / 255, Double(bytes[index + 1]) / 255, Double(bytes[index + 2]) / 255)
	}

	func luma(at point: CGPoint) -> Double {
		let colour = colour(at: point)
		return 0.299 * colour.red + 0.587 * colour.green + 0.114 * colour.blue
	}
}
