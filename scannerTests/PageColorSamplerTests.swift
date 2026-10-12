//
//  PageColorSamplerTests.swift
//  Rescriva (fork of Open Scanner)
//
//  Page colour sampling on synthetic pages drawn with UIKit: a white page with
//  a blue heading and red shapes, a dark slide, plain black-on-white text,
//  text on a coloured panel and mixed-colour text (both left uncoloured),
//  whiteboard and handwritten pages, determinism, the stored-JPEG path through
//  the Rebuilder, and the CIELAB and contrast helpers.
//

import UIKit
import XCTest
@testable import scanner

/// `PageColorSampler` on synthetic pages: background, palette and run colours.
final class PageColorSamplerTests: XCTestCase {

	// MARK: Background and palette

	func testBlueHeadingAndRedShapesGiveBlueAndRedAccentsOnWhitePaper() throws {
		let page = try ColourfulPage()

		let colors = try XCTUnwrap(PageColorSampler.sample(page.image, blocks: page.blocks, source: .typed))

		XCTAssertEqual(colors.background, Sample.white, "near-white paper is written as white")
		let hexes = colors.palette.map(\.hex)
		XCTAssertTrue(colors.palette.contains(where: isBlue), "palette \(hexes) has the heading's blue")
		XCTAssertTrue(colors.palette.contains(where: isRed), "palette \(hexes) has the shapes' red")
		XCTAssertLessThanOrEqual(colors.palette.count, 5)
		for colour in colors.palette {
			XCTAssertGreaterThanOrEqual(LabColor(colour).chroma, 20, "\(colour.hex) is grey, black or white")
		}
	}

	func testADarkSlideHasADarkBackgroundAndItsWhiteTextStaysUncoloured() throws {
		let navy = RGBColor(red: 0.08, green: 0.12, blue: 0.22)
		let canvas = Canvas(size: CGSize(width: 960, height: 540), background: navy.uiColor)
		let title = CGRect(x: 80, y: 60, width: 700, height: 70)
		let body = CGRect(x: 80, y: 180, width: 760, height: 240)
		let image = try canvas.image {
			canvas.text("Roadmap for the year", in: title, points: 48, weight: .bold, colour: .white)
			canvas.text(Sample.body, in: body, points: 24, weight: .regular, colour: .white)
		}
		let blocks = [canvas.heading("Roadmap for the year", in: title), canvas.paragraph(Sample.body, in: body)]

		let colors = try XCTUnwrap(PageColorSampler.sample(image, blocks: blocks, source: .typed))

		let background = try XCTUnwrap(colors.background)
		XCTAssertTrue(isDark(background), "\(background.hex) gets white text in PowerPoint")
		XCTAssertEqual(background.red, navy.red, accuracy: 0.03)
		XCTAssertEqual(background.green, navy.green, accuracy: 0.03)
		XCTAssertEqual(background.blue, navy.blue, accuracy: 0.03)
		XCTAssertTrue(colors.inks.isEmpty, "white text on a dark slide is already automatic")
		XCTAssertTrue(colors.palette.isEmpty, "neither the slide nor its text is an accent: \(colors.palette.map(\.hex))")
	}

	func testPlainBlackOnWhiteHasNoPaletteAndNoRunColours() throws {
		let canvas = Canvas(size: CGSize(width: 612, height: 792), background: .white)
		let title = CGRect(x: 60, y: 60, width: 492, height: 60)
		let body = CGRect(x: 60, y: 150, width: 492, height: 420)
		let text = Sample.body + " " + Sample.body
		let image = try canvas.image {
			canvas.text("Meeting notes", in: title, points: 40, weight: .bold, colour: .black)
			canvas.text(text, in: body, points: 15, weight: .regular, colour: .black)
		}
		let blocks = [canvas.heading("Meeting notes", in: title), canvas.paragraph(text, in: body)]

		let colors = try XCTUnwrap(PageColorSampler.sample(image, blocks: blocks, source: .typed))

		XCTAssertEqual(colors.background, Sample.white)
		XCTAssertTrue(colors.palette.isEmpty, "black text is not an accent: \(colors.palette.map(\.hex))")
		XCTAssertTrue(colors.inks.isEmpty)
	}

	// MARK: Run colours

	func testTheBlueHeadingIsColouredAndTheBlackBodyIsNot() throws {
		let page = try ColourfulPage()

		let colors = try XCTUnwrap(PageColorSampler.sample(page.image, blocks: page.blocks, source: .typed))

		let ink = try XCTUnwrap(colors.inks[page.heading.id], "the heading's ink was read")
		XCTAssertEqual(ink.red, Sample.blue.red, accuracy: 0.1)
		XCTAssertEqual(ink.green, Sample.blue.green, accuracy: 0.1)
		XCTAssertEqual(ink.blue, Sample.blue.blue, accuracy: 0.1)
		XCTAssertNil(colors.inks[page.body.id], "black body text keeps the default colour")

		let applied = PageColorSampler.applying(colors, to: RescrivaPage(blocks: page.blocks))
		XCTAssertEqual(applied.background, colors.background)
		XCTAssertEqual(applied.palette, colors.palette)
		XCTAssertEqual(runs(of: applied.blocks[0]).map(\.color), [ink])
		XCTAssertTrue(runs(of: applied.blocks[1]).allSatisfy { $0.color == nil })
	}

	func testTextOnAColouredPanelIsLeftUncoloured() throws {
		let canvas = Canvas(size: CGSize(width: 960, height: 540), background: .white)
		let panel = CGRect(x: 60, y: 120, width: 840, height: 300)
		let label = CGRect(x: 100, y: 220, width: 600, height: 70)
		let image = try canvas.image {
			canvas.fill(panel, colour: Sample.blue.uiColor)
			canvas.text("Inside the panel", in: label, points: 48, weight: .bold, colour: .white)
		}
		let block = canvas.heading("Inside the panel", in: label)

		let colors = try XCTUnwrap(PageColorSampler.sample(image, blocks: [block], source: .typed))

		XCTAssertNil(colors.inks[block.id], "the panel is not the text's colour")
		XCTAssertTrue(colors.palette.contains(where: isBlue), "the panel is still an accent")
	}

	func testAParagraphMixingRedAndBlackWordsIsLeftUncoloured() throws {
		let canvas = Canvas(size: CGSize(width: 612, height: 792), background: .white)
		let rect = CGRect(x: 60, y: 100, width: 492, height: 260)
		let font = UIFont.systemFont(ofSize: 18, weight: .semibold)
		let text = NSMutableAttributedString(string: Sample.body, attributes: [.font: font, .foregroundColor: Sample.red.uiColor])
		text.append(NSAttributedString(string: " " + Sample.body, attributes: [.font: font, .foregroundColor: UIColor.black]))
		let image = try canvas.image { text.draw(in: rect) }
		let block = canvas.paragraph(text.string, in: rect)

		let colors = try XCTUnwrap(PageColorSampler.sample(image, blocks: [block], source: .typed))

		XCTAssertNil(colors.inks[block.id], "one colour can't stand for two")
	}

	func testABlackHeadingWithOneSaturatedWordIsLeftUncoloured() throws {
		// Saturated red and blue sit farther from white than black does, so the black words split
		// with the paper and only a second-ink check sees them.
		let rect = CGRect(x: 60, y: 60, width: 492, height: 70)
		for word in [UIColor(red: 1, green: 0, blue: 0, alpha: 1), UIColor(red: 0.88, green: 0, blue: 0, alpha: 1),
					 UIColor(red: 0, green: 0, blue: 1, alpha: 1)] {
			let font = UIFont.systemFont(ofSize: 24, weight: .bold)
			let text = NSMutableAttributedString(string: "Chapter three Results and next ",
												 attributes: [.font: font, .foregroundColor: UIColor.black])
			text.append(NSAttributedString(string: "steps", attributes: [.font: font, .foregroundColor: word]))
			try assertUncoloured(text, in: rect, heading: true)
		}
	}

	func testAParagraphEndingInAFewColouredWordsIsLeftUncoloured() throws {
		let rect = CGRect(x: 60, y: 150, width: 492, height: 120)
		let font = UIFont.systemFont(ofSize: 18, weight: .semibold)
		for word in [UIColor(red: 1, green: 0, blue: 0, alpha: 1), UIColor(red: 0, green: 0, blue: 1, alpha: 1)] {
			let text = NSMutableAttributedString(string: "Support tickets fell by a third after the help centre relaunch and ",
												 attributes: [.font: font, .foregroundColor: UIColor.black])
			text.append(NSAttributedString(string: "the offline mode shipped", attributes: [.font: font, .foregroundColor: word]))
			try assertUncoloured(text, in: rect, heading: false)
		}
	}

	func testAListWithOnlyItsFirstItemInColourIsLeftUncoloured() throws {
		let canvas = Canvas(size: CGSize(width: 612, height: 792), background: .white)
		let rect = CGRect(x: 60, y: 120, width: 492, height: 120)
		let font = UIFont.systemFont(ofSize: 20, weight: .semibold)
		let text = NSMutableAttributedString(string: "Renew passport\n", attributes: [.font: font, .foregroundColor: Sample.red.uiColor])
		text.append(NSAttributedString(string: "Book flights\nPack the chargers", attributes: [.font: font, .foregroundColor: UIColor.black]))
		let image = try canvas.image { text.draw(in: rect) }
		let items = ["Renew passport", "Book flights", "Pack the chargers"].map { ListItem(runs: [RescrivaRun(text: $0)]) }
		let list = canvas.block(.list(style: .bullet, items: items), in: rect)

		let colors = try XCTUnwrap(PageColorSampler.sample(image, blocks: [list], source: .typed))

		XCTAssertNil(colors.inks[list.id], "the first item's red isn't the whole list's")
	}

	func testASaturatedRedHeadingAloneKeepsItsColourThroughJPEG() throws {
		let canvas = Canvas(size: CGSize(width: 612, height: 792), background: .white)
		let rect = CGRect(x: 60, y: 60, width: 492, height: 60)
		let image = try canvas.image {
			canvas.text("Results and next steps", in: rect, points: 30, weight: .bold, colour: UIColor(red: 1, green: 0, blue: 0, alpha: 1))
		}
		let block = canvas.heading("Results and next steps", in: rect)
		let data = try XCTUnwrap(UIImage(cgImage: image).jpegData(compressionQuality: 0.75))

		let colors = try XCTUnwrap(PageColorSampler.sample(data, blocks: [block], source: .typed))

		let ink = try XCTUnwrap(colors.inks[block.id], "its anti-aliased and JPEG-smeared rims aren't a second ink")
		XCTAssertTrue(isRed(ink), ink.hex)
	}

	func testWhiteboardAndHandwrittenPagesNeverColourRuns() throws {
		let page = try ColourfulPage()
		for source in [PageSource.whiteboard, .handwritten] {
			let colors = try XCTUnwrap(PageColorSampler.sample(page.image, blocks: page.blocks, source: source))

			XCTAssertTrue(colors.inks.isEmpty, "\(source): marker and pen colour aren't styling")
			XCTAssertTrue(colors.palette.contains(where: isRed), "\(source) pages still get a palette")
		}
	}

	// MARK: Determinism and the stored page

	func testTheSamePageGivesTheSameColoursEveryTime() throws {
		let page = try ColourfulPage()

		let first = PageColorSampler.sample(page.image, blocks: page.blocks, source: .typed)
		let second = PageColorSampler.sample(page.image, blocks: page.blocks, source: .typed)

		XCTAssertNotNil(first)
		XCTAssertEqual(first, second)
	}

	func testTheRebuilderColoursPagesFromTheStoredJPEG() async throws {
		let page = try ColourfulPage()
		let data = try XCTUnwrap(UIImage(cgImage: page.image).jpegData(compressionQuality: 0.75))
		let snapshot = Rebuilder.PageSnapshot(imageData: data, lines: [], aspect: 612.0 / 792.0)
		let built = RescrivaPage(source: .typed, blocks: page.blocks)

		let first = await Rebuilder.sampleColors(in: [built], pages: [snapshot])
		let second = await Rebuilder.sampleColors(in: [built], pages: [snapshot])

		XCTAssertEqual(first, second, "a stored page samples the same way every time")
		let coloured = try XCTUnwrap(first.first)
		let background = try XCTUnwrap(coloured.background)
		XCTAssertFalse(isDark(background))
		XCTAssertTrue(coloured.palette.contains(where: isRed), "palette \(coloured.palette.map(\.hex))")
		let headingColour = try XCTUnwrap(runs(of: coloured.blocks[0]).first?.color, "the heading survives JPEG")
		XCTAssertTrue(isBlue(headingColour), headingColour.hex)
		XCTAssertTrue(runs(of: coloured.blocks[1]).allSatisfy { $0.color == nil })
	}

	// MARK: Colour helpers

	func testCIELABConversionsAndContrastRatios() {
		let white = LabColor(Sample.white)
		XCTAssertEqual(white.l, 100, accuracy: 0.01)
		XCTAssertEqual(white.chroma, 0, accuracy: 0.01)
		XCTAssertEqual(LabColor(red: 255, green: 255, blue: 255).distance(to: white), 0, accuracy: 1e-9)
		XCTAssertEqual(LabColor(red: 0, green: 0, blue: 0).l, 0, accuracy: 1e-9)
		let pureRed = LabColor(RGBColor(red: 1, green: 0, blue: 0))
		XCTAssertEqual(pureRed.l, 53.24, accuracy: 0.05)
		XCTAssertEqual(pureRed.a, 80.09, accuracy: 0.1)
		XCTAssertEqual(pureRed.b, 67.20, accuracy: 0.1)
		for colour in [Sample.blue, Sample.red, RGBColor(red: 0.5, green: 0.5, blue: 0.5), RGBColor(hex: 0x5A7A52)] {
			let back = LabColor(colour).rgb
			XCTAssertEqual(back.red, colour.red, accuracy: 1e-4)
			XCTAssertEqual(back.green, colour.green, accuracy: 1e-4)
			XCTAssertEqual(back.blue, colour.blue, accuracy: 1e-4)
		}
		XCTAssertEqual(RGBColor(red: 0, green: 0, blue: 0).contrastRatio(with: Sample.white), 21, accuracy: 0.01)
		XCTAssertEqual(Sample.blue.contrastRatio(with: Sample.blue), 1, accuracy: 1e-9)
	}

	// MARK: Helpers

	/// `text` drawn black-on-white in `rect` as one heading or paragraph block gets no run colour,
	/// as drawn and after the stored page's JPEG round trip.
	private func assertUncoloured(_ text: NSAttributedString, in rect: CGRect, heading: Bool,
								  file: StaticString = #filePath, line: UInt = #line) throws {
		let canvas = Canvas(size: CGSize(width: 612, height: 792), background: .white)
		let image = try canvas.image { text.draw(in: rect) }
		let block = heading ? canvas.heading(text.string, in: rect) : canvas.paragraph(text.string, in: rect)
		let drawn = try XCTUnwrap(PageColorSampler.sample(image, blocks: [block], source: .typed))
		XCTAssertNil(drawn.inks[block.id], "one colour can't stand for two: \(text.string)", file: file, line: line)
		let data = try XCTUnwrap(UIImage(cgImage: image).jpegData(compressionQuality: 0.75))
		let stored = try XCTUnwrap(PageColorSampler.sample(data, blocks: [block], source: .typed))
		XCTAssertNil(stored.inks[block.id], "after JPEG: \(text.string)", file: file, line: line)
	}

	private func isBlue(_ colour: RGBColor) -> Bool {
		colour.blue > colour.red + 0.25 && colour.blue > colour.green + 0.15
	}

	/// The PowerPoint renderer's test for switching to white text.
	private func isDark(_ colour: RGBColor) -> Bool {
		0.2126 * colour.red + 0.7152 * colour.green + 0.0722 * colour.blue < 0.45
	}

	private func isRed(_ colour: RGBColor) -> Bool {
		colour.red > colour.green + 0.35 && colour.red > colour.blue + 0.35
	}

	private func runs(of block: RescrivaBlock) -> [RescrivaRun] {
		switch block.content {
		case .heading(_, let runs), .paragraph(let runs, _): return runs
		default: return []
		}
	}
}

/// Colours and text shared by the synthetic pages.
private enum Sample {
	static let white = RGBColor(red: 1, green: 1, blue: 1)
	static let blue = RGBColor(red: 0.10, green: 0.32, blue: 0.80)
	static let red = RGBColor(red: 0.85, green: 0.15, blue: 0.12)
	static let body = "Revenue grew in every region this quarter, led by the new subscription plans. "
		+ "Support tickets fell by a third after the help centre relaunch, and the team shipped "
		+ "the offline mode that customers asked for most."
}

/// A white letter page: a blue heading, black body text and two red shapes.
private struct ColourfulPage {
	let image: CGImage
	let heading: RescrivaBlock
	let body: RescrivaBlock
	var blocks: [RescrivaBlock] { [heading, body] }

	init() throws {
		let canvas = Canvas(size: CGSize(width: 612, height: 792), background: .white)
		let title = CGRect(x: 60, y: 60, width: 492, height: 60)
		let text = CGRect(x: 60, y: 150, width: 492, height: 260)
		image = try canvas.image {
			canvas.text("Quarterly review", in: title, points: 44, weight: .bold, colour: Sample.blue.uiColor)
			canvas.text(Sample.body, in: text, points: 15, weight: .regular, colour: .black)
			canvas.fill(CGRect(x: 60, y: 470, width: 200, height: 140), colour: Sample.red.uiColor)
			canvas.fillEllipse(CGRect(x: 340, y: 470, width: 160, height: 160), colour: Sample.red.uiColor)
		}
		heading = canvas.heading("Quarterly review", in: title)
		body = canvas.paragraph(Sample.body, in: text)
	}
}

/// Draws a page with UIKit at 1 px per point (sRGB, top-left origin) and
/// makes blocks whose boxes are rectangles on it.
private struct Canvas {
	let size: CGSize
	let background: UIColor

	func image(_ draw: () -> Void) throws -> CGImage {
		let format = UIGraphicsImageRendererFormat()
		format.scale = 1
		format.opaque = true
		format.preferredRange = .standard
		let rendered = UIGraphicsImageRenderer(size: size, format: format).image { context in
			background.setFill()
			context.fill(CGRect(origin: .zero, size: size))
			draw()
		}
		return try XCTUnwrap(rendered.cgImage)
	}

	func text(_ string: String, in rect: CGRect, points: CGFloat, weight: UIFont.Weight, colour: UIColor) {
		let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: points, weight: weight),
														 .foregroundColor: colour]
		(string as NSString).draw(in: rect, withAttributes: attributes)
	}

	func fill(_ rect: CGRect, colour: UIColor) {
		colour.setFill()
		UIBezierPath(rect: rect).fill()
	}

	func fillEllipse(_ rect: CGRect, colour: UIColor) {
		colour.setFill()
		UIBezierPath(ovalIn: rect).fill()
	}

	func heading(_ text: String, in rect: CGRect) -> RescrivaBlock {
		RescrivaBlock(content: .heading(level: 1, runs: [RescrivaRun(text: text)]), box: box(rect))
	}

	func paragraph(_ text: String, in rect: CGRect) -> RescrivaBlock {
		RescrivaBlock(content: .paragraph(runs: [RescrivaRun(text: text)], alignment: .leading), box: box(rect))
	}

	func block(_ content: BlockContent, in rect: CGRect) -> RescrivaBlock {
		RescrivaBlock(content: content, box: box(rect))
	}

	private func box(_ rect: CGRect) -> NormalizedBox {
		NormalizedBox(x: rect.minX / size.width, y: rect.minY / size.height,
					  width: rect.width / size.width, height: rect.height / size.height)
	}
}

private extension RGBColor {
	var uiColor: UIColor { UIColor(red: red, green: green, blue: blue, alpha: 1) }
}
