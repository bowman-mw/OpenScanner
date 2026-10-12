//
//  DiagramEditorTests.swift
//  Rescriva (fork of Open Scanner)
//
//  The drawing editor without a screen: the pure diagram edits, resize
//  handles, smart guides, labels taken from the page under a traced shape,
//  cropping the original, writing a drawing back into its block, the shared
//  connector geometry, and the editor model's gestures, undo and zoom.
//

import CoreGraphics
import UIKit
import XCTest
@testable import scanner

@MainActor
final class DiagramEditingTests: XCTestCase {

	private let ink = RGBColor(hex: 0x2E3A4A)

	private func box(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> NormalizedBox {
		NormalizedBox(x: x, y: y, width: w, height: h)
	}

	// MARK: Edits

	func testNewIDsFillTheFirstGap() {
		XCTAssertEqual(Diagram.unusedID(prefix: "n", among: []), "n1")
		XCTAssertEqual(Diagram.unusedID(prefix: "n", among: ["n1", "n3"]), "n2")
		XCTAssertEqual(Diagram.unusedID(prefix: "e", among: ["e1", "e2"]), "e3")
	}

	func testRemovingANodeTakesItsEdgesWithIt() throws {
		var diagram = Diagram(nodes: [], edges: [])
		let a = try XCTUnwrap(diagram.addNode(shape: .rectangle, box: box(0, 0, 0.2, 0.2), label: "A", stroke: ink, fill: nil))
		let b = try XCTUnwrap(diagram.addNode(shape: .ellipse, box: box(0.5, 0, 0.2, 0.2), label: "B", stroke: ink, fill: nil))
		let c = try XCTUnwrap(diagram.addNode(shape: .diamond, box: box(0.5, 0.5, 0.2, 0.2), label: "C", stroke: ink, fill: nil))
		XCTAssertNotNil(diagram.connect(a, b, direction: .forward))
		XCTAssertNotNil(diagram.connect(b, c, direction: .none))

		diagram.removeNode(b)

		XCTAssertEqual(diagram.nodes.map(\.id), [a, c])
		XCTAssertTrue(diagram.edges.isEmpty)
	}

	func testConnectingRefusesLoopsDuplicatesAndUnknownNodes() throws {
		var diagram = Diagram(nodes: [], edges: [])
		let a = try XCTUnwrap(diagram.addNode(shape: .rectangle, box: box(0, 0, 0.2, 0.2), label: "A", stroke: ink, fill: nil))
		let b = try XCTUnwrap(diagram.addNode(shape: .rectangle, box: box(0.5, 0, 0.2, 0.2), label: "B", stroke: ink, fill: nil))
		XCTAssertEqual(diagram.connect(a, b, direction: .both), "e1")
		XCTAssertNil(diagram.connect(a, a, direction: .forward), "no loops")
		XCTAssertNil(diagram.connect(b, a, direction: .forward), "a pair is joined once, either way round")
		XCTAssertNil(diagram.connect(a, "missing", direction: .forward))
		XCTAssertEqual(diagram.edges.first?.direction, .both)
	}

	func testEditingAnUncertainArrowSettlesItsFlag() throws {
		var diagram = SampleLibrary.labNotesDiagram
		let edge = try XCTUnwrap(diagram.edges.first { $0.flag != nil })
		XCTAssertNil(edge.flag?.resolution)

		diagram.reverseEdge(edge.id)

		let edited = try XCTUnwrap(diagram.edges.first { $0.id == edge.id })
		XCTAssertEqual([edited.from, edited.to], [edge.to, edge.from])
		XCTAssertEqual(edited.flag?.resolution, "Enzyme → Product")
	}

	func testDuplicatesSitOffsetAndInsideTheFrame() throws {
		var diagram = Diagram(nodes: [], edges: [])
		let a = try XCTUnwrap(diagram.addNode(shape: .parallelogram, box: box(0.85, 0.1, 0.15, 0.2), label: "In", stroke: ink, fill: nil))
		let copy = try XCTUnwrap(diagram.duplicateNode(a, offset: 0.05))
		let node = try XCTUnwrap(diagram.node(copy))
		XCTAssertEqual(node.box.x, 0.85, accuracy: 1e-9, "pushed back inside the right edge")
		XCTAssertEqual(node.box.y, 0.15, accuracy: 1e-9)
		XCTAssertEqual(node.shape, .parallelogram)
		XCTAssertEqual(diagram.nodes.last?.id, copy, "copies go on top")

		diagram.reorderNode(copy, toFront: false)
		XCTAssertEqual(diagram.nodes.first?.id, copy)
	}

	// MARK: Handles and guides

	func testResizeHandlesMoveOnlyTheirEdgesAndKeepAMinimumSide() {
		let rect = CGRect(x: 100, y: 100, width: 80, height: 40)
		XCTAssertEqual(ResizeHandle.bottomTrailing.resized(rect, by: CGSize(width: 20, height: 10), minimum: 16),
					   CGRect(x: 100, y: 100, width: 100, height: 50))
		XCTAssertEqual(ResizeHandle.leading.resized(rect, by: CGSize(width: 200, height: 99), minimum: 16),
					   CGRect(x: 164, y: 100, width: 16, height: 40), "the left edge stops a minimum short of the right")
		XCTAssertEqual(ResizeHandle.top.point(in: rect), CGPoint(x: 140, y: 100))
	}

	func testMovingNearAnotherShapesCentreSnapsToItAndShowsAGuide() throws {
		let other = CGRect(x: 0, y: 200, width: 100, height: 50)
		let moving = CGRect(x: 4, y: 0, width: 100, height: 50)

		let snap = DiagramSnapping.snapMove(moving, others: [other], canvas: CGSize(width: 500, height: 400), threshold: 6)

		XCTAssertEqual(snap.rect.minX, 0, accuracy: 1e-9)
		let guide = try XCTUnwrap(snap.guides.first { $0.axis == .vertical && $0.position == 50 })
		XCTAssertEqual(guide.from, 0)
		XCTAssertEqual(guide.to, 250)
		XCTAssertEqual(DiagramSnapping.snapMove(moving, others: [other], canvas: CGSize(width: 500, height: 400), threshold: 3).rect, moving,
					   "out of reach: no snap")
	}

	func testResizingSnapsTheDraggedEdgeOnly() {
		let other = CGRect(x: 200, y: 0, width: 60, height: 60)
		let resized = CGRect(x: 100, y: 100, width: 97, height: 40)

		let snap = DiagramSnapping.snapResize(resized, handle: .trailing, others: [other], canvas: CGSize(width: 600, height: 400),
											  threshold: 6, minimum: 16)

		XCTAssertEqual(snap.rect, CGRect(x: 100, y: 100, width: 100, height: 40))
		XCTAssertTrue(snap.guides.contains { $0.axis == .vertical && $0.position == 200 })
	}

	// MARK: Tracing the original

	func testATracedShapeTakesThePageTextUnderIt() {
		let lines = [
			RecognizedLine(text: "ES", confidence: 1, alternatives: [], box: CGRect(x: 0.12, y: 0.6, width: 0.06, height: 0.05)),
			RecognizedLine(text: "complex", confidence: 1, alternatives: [], box: CGRect(x: 0.1, y: 0.66, width: 0.1, height: 0.05)),
			RecognizedLine(text: "Product", confidence: 1, alternatives: [], box: CGRect(x: 0.7, y: 0.6, width: 0.12, height: 0.05)),
		]
		XCTAssertEqual(TraceLabels.label(in: box(0.05, 0.55, 0.25, 0.2), lines: lines), "ES complex")
		XCTAssertEqual(TraceLabels.label(in: box(0.3, 0.1, 0.2, 0.2), lines: lines), "")
	}

	func testPageLinesAreReExpressedInTheBlocksFrame() throws {
		let page = [
			RecognizedLine(text: "inside", confidence: 1, alternatives: [], box: CGRect(x: 0.3, y: 0.4, width: 0.1, height: 0.02)),
			RecognizedLine(text: "outside", confidence: 1, alternatives: [], box: CGRect(x: 0.05, y: 0.9, width: 0.1, height: 0.02)),
		]
		let framed = TraceLabels.lines(page, in: box(0.2, 0.3, 0.5, 0.2))
		let line = try XCTUnwrap(framed.first)
		XCTAssertEqual(framed.count, 1)
		XCTAssertEqual(line.text, "inside")
		XCTAssertEqual(line.box.minX, 0.2, accuracy: 1e-9)
		XCTAssertEqual(line.box.minY, 0.5, accuracy: 1e-9)
		XCTAssertEqual(line.box.width, 0.2, accuracy: 1e-9)
	}

	func testTheOriginalIsCroppedToTheBlock() throws {
		XCTAssertEqual(RecreateSource.pixelRect(box(0.25, 0.5, 0.5, 0.25), width: 400, height: 800),
					   CGRect(x: 100, y: 400, width: 200, height: 200))
		XCTAssertEqual(RecreateSource.pixelRect(box(0.9, 0.9, 0.5, 0.5), width: 100, height: 100),
					   CGRect(x: 90, y: 90, width: 10, height: 10), "clipped to the image")
		let format = UIGraphicsImageRendererFormat()
		format.scale = 1
		let page = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 100), format: format).image { context in
			UIColor.white.setFill()
			context.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
		}
		let crop = try XCTUnwrap(RecreateSource.crop(page, to: box(0.5, 0, 0.5, 0.5)))
		XCTAssertEqual(crop.size, CGSize(width: 100, height: 50))
	}

	// MARK: Writing back

	func testRecreatingAFigureKeepsItsCaption() throws {
		var block = RescrivaBlock(content: .figure(assetID: "fig-7", caption: "Figure 2", altText: "Flowchart"),
							   box: box(0.1, 0.2, 0.8, 0.3))
		var drawing = try XCTUnwrap(RecreateSource.startingDiagram(for: block.content, aspect: 2))
		XCTAssertEqual(drawing.caption, "Figure 2")
		XCTAssertEqual(drawing.aspect, 2)
		XCTAssertTrue(drawing.nodes.isEmpty)
		RecreateSource.apply(drawing, to: &block)
		guard case .figure = block.content else { return XCTFail("an empty drawing changes nothing") }

		_ = drawing.addNode(shape: .rectangle, box: box(0.1, 0.1, 0.3, 0.3), label: "Start", stroke: ink, fill: nil)
		RecreateSource.apply(drawing, to: &block)

		guard case .diagram(let diagram) = block.content else { return XCTFail("not a diagram") }
		XCTAssertEqual(diagram.nodes.map(\.label), ["Start"])
		XCTAssertEqual(diagram.caption, "Figure 2")
		XCTAssertEqual(block.box, box(0.1, 0.2, 0.8, 0.3))
		XCTAssertEqual(block.provenance?.engine, "user")
		XCTAssertFalse(RecreateSource.canRecreate(.paragraph(runs: [], alignment: .leading)))
	}

	// MARK: Geometry

	func testConnectorsLeaveEachShapeAtItsOutline() throws {
		let size = CGSize(width: 400, height: 200)
		let ellipse = Diagram.Node(id: "a", label: "", shape: .ellipse, box: box(0, 0.25, 0.25, 0.5), stroke: ink)
		let diamond = Diagram.Node(id: "b", label: "", shape: .diamond, box: box(0.75, 0.25, 0.25, 0.5), stroke: ink)
		let line = try XCTUnwrap(DiagramGeometry.connector(from: ellipse, to: diamond, direction: .none, in: size, gap: 0, headRoom: 0))
		XCTAssertEqual(line.start.x, 100, accuracy: 1e-6, "the ellipse's right edge")
		XCTAssertEqual(line.end.x, 300, accuracy: 1e-6, "the diamond's left point")
		XCTAssertEqual(line.start.y, 100, accuracy: 1e-6)

		let inner = Diagram.Node(id: "c", label: "", shape: .rectangle, box: box(0.05, 0.3, 0.1, 0.4), stroke: ink)
		XCTAssertNil(DiagramGeometry.connector(from: ellipse, to: inner, direction: .forward, in: size), "overlapping shapes draw no line")
		XCTAssertEqual(DiagramGeometry.exitFraction(.diamond, in: CGRect(x: 0, y: 0, width: 100, height: 100), toward: CGVector(dx: 100, dy: 100)),
					   0.25, accuracy: 1e-9)
	}
}

/// The editor model driven like a finger would drive it.
@MainActor
final class DiagramEditorModelTests: XCTestCase {

	/// A 2:1 canvas in a 432 × 232 view: 400 × 200 at (16, 16).
	private func model(_ diagram: Diagram = Diagram(nodes: [], edges: [], aspect: 2), lines: [RecognizedLine] = []) -> DiagramEditorModel {
		let model = DiagramEditorModel(diagram: diagram, traceLines: lines)
		model.layout(in: CGSize(width: 432, height: 232))
		return model
	}

	private func drag(_ model: DiagramEditorModel, from start: CGPoint, to end: CGPoint) {
		model.touchChanged(start: start, location: start)
		model.touchChanged(start: start, location: CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2))
		model.touchChanged(start: start, location: end)
		model.touchEnded(start: start, location: end)
	}

	private func tap(_ model: DiagramEditorModel, at point: CGPoint) {
		model.touchChanged(start: point, location: point)
		model.touchEnded(start: point, location: point)
	}

	func testTheCanvasFitsTheViewAtTheDiagramsAspect() {
		let editor = model()
		XCTAssertEqual(editor.canvasSize, CGSize(width: 400, height: 200))
		XCTAssertEqual(editor.origin, CGPoint(x: 16, y: 16))
		XCTAssertEqual(editor.toCanvas(CGPoint(x: 216, y: 116)), CGPoint(x: 200, y: 100))
	}

	func testDraggingWithAShapeToolDrawsItLabelledFromThePage() throws {
		let label = RecognizedLine(text: "Start", confidence: 1, alternatives: [], box: CGRect(x: 0.15, y: 0.3, width: 0.1, height: 0.1))
		let editor = model(lines: [label])
		editor.selectTool(.shape(.roundedRectangle))

		drag(editor, from: CGPoint(x: 56, y: 56), to: CGPoint(x: 176, y: 116))

		let node = try XCTUnwrap(editor.diagram.nodes.first)
		XCTAssertEqual(node.shape, .roundedRectangle)
		XCTAssertEqual(node.label, "Start")
		XCTAssertEqual(node.box.x, 0.1, accuracy: 1e-9)
		XCTAssertEqual(node.box.width, 0.3, accuracy: 1e-9)
		XCTAssertEqual(node.box.height, 0.3, accuracy: 1e-9)
		XCTAssertEqual(editor.selection, .node(node.id))
		XCTAssertEqual(editor.tool, .select, "back to selecting after each shape, like Google Drawings")
		XCTAssertEqual(editor.labelRequest, 0, "the page gave it a label, so the keyboard stays down")
		XCTAssertTrue(editor.hasChanges)
	}

	func testAnUnlabelledTapDropsADefaultShapeAndAsksForALabel() throws {
		let editor = model()
		editor.selectTool(.shape(.ellipse))
		tap(editor, at: CGPoint(x: 216, y: 116))
		let node = try XCTUnwrap(editor.diagram.nodes.first)
		XCTAssertEqual(node.shape, .ellipse)
		XCTAssertEqual(editor.rect(of: node).midX, 200, accuracy: 1e-6)
		XCTAssertEqual(editor.labelRequest, 1)
	}

	func testDraggingAShapeMovesItAndUndoPutsItBack() throws {
		var diagram = Diagram(nodes: [], edges: [], aspect: 2)
		let id = try XCTUnwrap(diagram.addNode(shape: .rectangle, box: NormalizedBox(x: 0.1, y: 0.1, width: 0.2, height: 0.2),
											   label: "A", stroke: RGBColor(hex: 0x222222), fill: nil))
		let editor = model(diagram)

		drag(editor, from: CGPoint(x: 96, y: 56), to: CGPoint(x: 196, y: 106))

		let moved = try XCTUnwrap(editor.diagram.node(id))
		XCTAssertEqual(moved.box.x, 0.35, accuracy: 1e-9)
		XCTAssertEqual(moved.box.y, 0.35, accuracy: 1e-9)
		XCTAssertEqual(editor.history.count, 1, "a whole drag is one undo step")
		editor.undo()
		XCTAssertEqual(editor.diagram.node(id)?.box.x ?? 0, 0.1, accuracy: 1e-9)
		editor.redo()
		XCTAssertEqual(editor.diagram.node(id)?.box.x ?? 0, 0.35, accuracy: 1e-9)
	}

	func testDraggingFromAConnectionPointJoinsTwoShapes() throws {
		var diagram = Diagram(nodes: [], edges: [], aspect: 2)
		let ink = RGBColor(hex: 0x222222)
		let a = try XCTUnwrap(diagram.addNode(shape: .rectangle, box: NormalizedBox(x: 0.1, y: 0.4, width: 0.2, height: 0.2), label: "A", stroke: ink, fill: nil))
		let b = try XCTUnwrap(diagram.addNode(shape: .rectangle, box: NormalizedBox(x: 0.7, y: 0.4, width: 0.2, height: 0.2), label: "B", stroke: ink, fill: nil))
		let editor = model(diagram)
		tap(editor, at: CGPoint(x: 96, y: 116))
		XCTAssertEqual(editor.selection, .node(a))

		// A's right-hand connection point sits 24 pt past its right side (x = 120 + 24 on the canvas).
		drag(editor, from: CGPoint(x: 16 + 144, y: 116), to: CGPoint(x: 16 + 320, y: 116))

		let edge = try XCTUnwrap(editor.diagram.edges.first)
		XCTAssertEqual([edge.from, edge.to], [a, b])
		XCTAssertEqual(edge.direction, .forward)
		XCTAssertEqual(editor.selection, .edge(edge.id))
		editor.setDirection(.both)
		XCTAssertEqual(editor.diagram.edges.first?.direction, .both)
		editor.deleteSelection()
		XCTAssertTrue(editor.diagram.edges.isEmpty)
		XCTAssertNil(editor.selection)
	}

	func testTypingALabelIsOneUndoStep() throws {
		var diagram = Diagram(nodes: [], edges: [], aspect: 2)
		let id = try XCTUnwrap(diagram.addNode(shape: .diamond, box: NormalizedBox(x: 0.4, y: 0.4, width: 0.2, height: 0.2),
											   label: "", stroke: RGBColor(hex: 0x222222), fill: nil))
		let editor = model(diagram)
		editor.selection = .node(id)
		editor.beginLabelEdit()
		editor.setLabel("O")
		editor.setLabel("OK?")
		editor.endLabelEdit()
		XCTAssertEqual(editor.diagram.node(id)?.label, "OK?")
		XCTAssertEqual(editor.history.count, 1)
		editor.undo()
		XCTAssertEqual(editor.diagram.node(id)?.label, "")
	}

	func testPinchingZoomsAroundTheFingersAndStaysInBounds() {
		let editor = model()
		let anchor = CGPoint(x: 216, y: 116)
		editor.pinchChanged(scale: 2, anchor: anchor)
		XCTAssertEqual(editor.zoom, 2)
		XCTAssertEqual(editor.toCanvas(anchor).x, 200, accuracy: 1e-6, "the point under the fingers stays put")
		editor.pinchChanged(scale: 10, anchor: anchor)
		XCTAssertEqual(editor.zoom, DiagramEditorModel.maxZoom)
		editor.pinchEnded()
		editor.touchEnded(start: anchor, location: anchor)
		XCTAssertTrue(editor.diagram.nodes.isEmpty, "the pinch's lift isn't a tap")
		editor.resetZoom()
		XCTAssertEqual(editor.zoom, 1)
		XCTAssertEqual(DiagramEditorModel.clampedOffset(500, content: 800, view: 432, origin: 16), 0)
		XCTAssertEqual(DiagramEditorModel.clampedOffset(0, content: 300, view: 432, origin: 16), 50, "content that fits is centred")
	}
}
