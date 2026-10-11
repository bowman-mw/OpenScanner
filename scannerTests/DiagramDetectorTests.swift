//
//  DiagramDetectorTests.swift
//  Folio (fork of Open Scanner)
//
//  The classical diagram detector on small synthetic pages drawn with Core
//  Graphics: boxes joined by an arrow, a line with no arrowhead, shape kinds,
//  marker colours, and text, table and blank pages that must not become
//  diagrams. Label text comes from hand-made OCR lines, so no text is drawn.
//

import CoreGraphics
import XCTest
@testable import scanner

/// `DiagramDetector.detect` on synthetic pages: graph, flags, shapes, colour and the quality gate.
final class DiagramDetectorTests: XCTestCase {

	// MARK: Graph

	func testTwoBoxesJoinedByAnArrowBecomeTwoNodesAndADirectedEdge() throws {
		let page = SyntheticPage()
		page.rectangle(CGRect(x: 80, y: 220, width: 200, height: 110))
		page.rectangle(CGRect(x: 520, y: 220, width: 200, height: 110))
		page.line(from: CGPoint(x: 290, y: 275), to: CGPoint(x: 492, y: 275))
		page.filledArrowhead(tip: CGPoint(x: 512, y: 275), from: CGPoint(x: 290, y: 275))
		let lines = [page.ocrLine("Start", in: CGRect(x: 140, y: 260, width: 80, height: 30)),
					 page.ocrLine("Finish", in: CGRect(x: 580, y: 260, width: 80, height: 30))]

		let found = try XCTUnwrap(DiagramDetector.detect(in: try page.image(), lines: lines))

		let diagram = found.diagram
		XCTAssertEqual(diagram.nodes.map(\.label).sorted(), ["Finish", "Start"])
		XCTAssertEqual(diagram.edges.count, 1)
		let edge = try XCTUnwrap(diagram.edges.first)
		XCTAssertNil(edge.flag, "an arrowhead at one end sets the direction")
		XCTAssertEqual(diagram.node(edge.from)?.label, "Start")
		XCTAssertEqual(diagram.node(edge.to)?.label, "Finish")
		XCTAssertEqual(found.consumedLines, IndexSet([0, 1]))
		XCTAssertEqual(diagram.layout, .faithful)
		XCTAssertNil(diagram.caption)
		XCTAssertGreaterThan(diagram.aspect, 1.5, "two boxes side by side make a wide frame")
		for node in diagram.nodes {
			XCTAssertEqual(node.shape, .rectangle)
			XCTAssertTrue(node.box.x >= 0 && node.box.y >= 0 && node.box.x + node.box.width <= 1.0001 && node.box.y + node.box.height <= 1.0001)
		}
		XCTAssertTrue(found.frame.x >= 0 && found.frame.x + found.frame.width <= 1.0001)
	}

	func testALineWithoutAnArrowheadIsFlaggedWithThreeChoices() throws {
		let page = SyntheticPage()
		page.rectangle(CGRect(x: 80, y: 220, width: 200, height: 110))
		page.rectangle(CGRect(x: 520, y: 220, width: 200, height: 110))
		page.line(from: CGPoint(x: 290, y: 275), to: CGPoint(x: 510, y: 275))
		let lines = [page.ocrLine("API", in: CGRect(x: 150, y: 260, width: 60, height: 30)),
					 page.ocrLine("queue", in: CGRect(x: 580, y: 260, width: 80, height: 30))]

		let found = try XCTUnwrap(DiagramDetector.detect(in: try page.image(), lines: lines))

		let edge = try XCTUnwrap(found.diagram.edges.first)
		XCTAssertEqual(found.diagram.node(edge.from)?.label, "API", "undirected edges run in reading order")
		let flag = try XCTUnwrap(edge.flag)
		XCTAssertEqual(flag.kind, .edge)
		XCTAssertNil(flag.resolution)
		XCTAssertEqual(flag.read, "API ↕ queue")
		XCTAssertEqual(flag.options.map(\.label).prefix(2), ["API → queue", "queue → API"])
		XCTAssertEqual(flag.options.map(\.edgeAction), [.keep, .reverse, .remove])
	}

	// MARK: Shapes and colour

	func testEllipseAndDiamondAreRecognized() throws {
		let page = SyntheticPage()
		page.ellipse(CGRect(x: 60, y: 200, width: 240, height: 150))
		page.diamond(CGRect(x: 500, y: 180, width: 240, height: 190))
		page.line(from: CGPoint(x: 310, y: 275), to: CGPoint(x: 490, y: 275))
		let lines = [page.ocrLine("Review", in: CGRect(x: 135, y: 260, width: 90, height: 30)),
					 page.ocrLine("OK?", in: CGRect(x: 590, y: 260, width: 60, height: 30))]

		let found = try XCTUnwrap(DiagramDetector.detect(in: try page.image(), lines: lines))

		let shapes = Dictionary(uniqueKeysWithValues: found.diagram.nodes.map { ($0.label, $0.shape) })
		XCTAssertEqual(shapes["Review"], .ellipse)
		XCTAssertEqual(shapes["OK?"], .diamond)
		XCTAssertEqual(found.diagram.edges.count, 1)
	}

	func testMarkerColourBecomesTheStrokeWithALightFill() throws {
		let moss = (red: 0x5A, green: 0x7A, blue: 0x52)
		let page = SyntheticPage()
		page.strokeColour = CGColor(srgbRed: CGFloat(moss.red) / 255, green: CGFloat(moss.green) / 255, blue: CGFloat(moss.blue) / 255, alpha: 1)
		page.rectangle(CGRect(x: 80, y: 220, width: 200, height: 110))
		page.rectangle(CGRect(x: 520, y: 220, width: 200, height: 110))
		page.line(from: CGPoint(x: 290, y: 275), to: CGPoint(x: 510, y: 275))

		let found = try XCTUnwrap(DiagramDetector.detect(in: try page.image(), lines: []))

		for node in found.diagram.nodes {
			XCTAssertEqual(node.stroke.red, Double(moss.red) / 255, accuracy: 0.08)
			XCTAssertEqual(node.stroke.green, Double(moss.green) / 255, accuracy: 0.08)
			XCTAssertEqual(node.stroke.blue, Double(moss.blue) / 255, accuracy: 0.08)
			let fill = try XCTUnwrap(node.fill)
			XCTAssertGreaterThan(fill.red, 0.8)
			XCTAssertGreaterThan(fill.green, fill.red, "the tint keeps the marker's hue")
		}
	}

	// MARK: Pages that are not diagrams

	func testTextOnlyPageReturnsNil() throws {
		let page = SyntheticPage()
		var lines: [RecognizedLine] = []
		for row in 0..<14 {
			let bar = CGRect(x: 70, y: 60 + row * 36, width: row % 4 == 3 ? 380 : 640, height: 16)
			page.bar(bar)
			lines.append(page.ocrLine("Line \(row) of a paragraph", in: bar.insetBy(dx: -2, dy: -4)))
		}

		XCTAssertNil(DiagramDetector.detect(in: try page.image(), lines: lines))
		XCTAssertNil(DiagramDetector.detect(in: try page.image(), lines: []), "bars that OCR missed are not shapes either")
	}

	func testRuledTableReturnsNil() throws {
		let page = SyntheticPage()
		let columns: [CGFloat] = [80, 330, 520, 720], rows: [CGFloat] = [120, 190, 260, 330, 400]
		for x in columns {
			page.line(from: CGPoint(x: x, y: rows[0]), to: CGPoint(x: x, y: rows[rows.count - 1]))
		}
		for y in rows {
			page.line(from: CGPoint(x: columns[0], y: y), to: CGPoint(x: columns[columns.count - 1], y: y))
		}
		var lines: [RecognizedLine] = []
		for row in 0..<(rows.count - 1) {
			for column in 0..<(columns.count - 1) {
				lines.append(page.ocrLine("cell", in: CGRect(x: columns[column] + 20, y: rows[row] + 20, width: 70, height: 28)))
			}
		}

		XCTAssertNil(DiagramDetector.detect(in: try page.image(), lines: lines))
	}

	func testBlankPageReturnsNil() throws {
		XCTAssertNil(DiagramDetector.detect(in: try SyntheticPage().image(), lines: []))
	}
}

/// An 800 × 600 white page drawn with Core Graphics in top-left coordinates.
private final class SyntheticPage {
	let width = 800
	let height = 600
	var strokeColour = CGColor(srgbRed: 0.13, green: 0.16, blue: 0.19, alpha: 1)
	private let context: CGContext?

	init() {
		context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
							space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
							bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
		context?.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
		context?.fill(CGRect(x: 0, y: 0, width: width, height: height))
		context?.translateBy(x: 0, y: CGFloat(height))
		context?.scaleBy(x: 1, y: -1)
		context?.setLineWidth(5)
		context?.setLineCap(.round)
		context?.setLineJoin(.round)
	}

	func rectangle(_ rect: CGRect) {
		context?.setStrokeColor(strokeColour)
		context?.stroke(rect)
	}

	func ellipse(_ rect: CGRect) {
		context?.setStrokeColor(strokeColour)
		context?.strokeEllipse(in: rect)
	}

	func diamond(_ rect: CGRect) {
		context?.setStrokeColor(strokeColour)
		context?.beginPath()
		context?.move(to: CGPoint(x: rect.midX, y: rect.minY))
		context?.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
		context?.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
		context?.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
		context?.closePath()
		context?.strokePath()
	}

	func line(from start: CGPoint, to end: CGPoint) {
		context?.setStrokeColor(strokeColour)
		context?.strokeLineSegments(between: [start, end])
	}

	func filledArrowhead(tip: CGPoint, from tail: CGPoint) {
		let angle = atan2(tip.y - tail.y, tip.x - tail.x)
		let size: CGFloat = 28
		context?.setFillColor(strokeColour)
		context?.beginPath()
		context?.move(to: tip)
		context?.addLine(to: CGPoint(x: tip.x - size * cos(angle - 0.45), y: tip.y - size * sin(angle - 0.45)))
		context?.addLine(to: CGPoint(x: tip.x - size * cos(angle + 0.45), y: tip.y - size * sin(angle + 0.45)))
		context?.closePath()
		context?.fillPath()
	}

	/// A filled bar standing in for a line of text.
	func bar(_ rect: CGRect) {
		context?.setFillColor(strokeColour)
		context?.fill(rect)
	}

	/// An OCR line whose (top-left, normalized) box covers `rect` on this page.
	func ocrLine(_ text: String, in rect: CGRect) -> RecognizedLine {
		RecognizedLine(text: text, confidence: 1, alternatives: [],
					   box: CGRect(x: rect.minX / CGFloat(width), y: rect.minY / CGFloat(height),
								   width: rect.width / CGFloat(width), height: rect.height / CGFloat(height)))
	}

	func image() throws -> CGImage {
		try XCTUnwrap(context?.makeImage())
	}
}
