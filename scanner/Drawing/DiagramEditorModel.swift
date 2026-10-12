//
//  DiagramEditorModel.swift
//  Rescriva (fork of Open Scanner)
//
//  State for the drawing editor: the diagram being drawn, the tool, the
//  selection, zoom and pan, undo history, and the one-finger gesture
//  machine that turns touches into Google Drawings–style edits — drag out a
//  shape, move and resize with smart guides, drag a connector from shape to
//  shape. Geometry is in canvas points: the diagram's frame fitted to the
//  screen at 100% zoom. Screen ("view") points only appear at the edges.
//

import SwiftUI

/// What the next drag on the canvas does.
enum DrawingTool: Hashable {
	case select
	/// Drag to draw this shape; a tap drops one at the default size.
	case shape(Diagram.Shape)
	/// Drag from one shape to another to join them.
	case connector(Diagram.Direction)
}

/// What is selected on the canvas.
enum DrawingSelection: Hashable {
	case node(String)
	case edge(String)
}

/// A connector being dragged out from a shape (canvas points).
struct PendingConnector: Equatable {
	let from: String
	var end: CGPoint
	var target: String?
	let direction: Diagram.Direction
}

/// Where a touch landed.
enum DrawingHit: Equatable {
	case handle(String, ResizeHandle)
	case connectionPoint(String)
	case node(String)
	case edge(String)
	case canvas
}

/// The drawing editor's state and edits. One per editor session.
@MainActor
@Observable
final class DiagramEditorModel {
	/// Smallest side a shape can have, in canvas points.
	static let minimumSide: CGFloat = 16
	/// A shape dropped with a tap, in screen points.
	static let defaultSize = CGSize(width: 104, height: 56)
	/// Finger travel before a touch counts as a drag, in screen points.
	static let dragSlop: CGFloat = 6
	/// Snap distance, in screen points.
	static let snapDistance: CGFloat = 7
	/// How close a touch must be to a handle or connection point, in screen points.
	static let touchRadius: CGFloat = 18
	/// How far outside a side its connection point sits, in screen points.
	static let connectionOffset: CGFloat = 24
	static let maxZoom: CGFloat = 4
	static let maxUndo = 60
	/// Room around the canvas at 100% zoom, in screen points.
	static let canvasInset: CGFloat = 16

	private(set) var diagram: Diagram
	var selection: DrawingSelection?
	private(set) var tool: DrawingTool = .select
	private(set) var guides: [DiagramGuide] = []
	private(set) var pendingConnector: PendingConnector?
	/// The shape being dragged out with a shape tool, in canvas points.
	private(set) var draft: CGRect?
	/// Bumped when a new unlabelled shape, or a double-tapped item, wants its label typed.
	private(set) var labelRequest = 0
	private(set) var zoom: CGFloat = 1
	private(set) var pan: CGSize = .zero
	/// Colours the next shape is drawn with: the last ones picked.
	private(set) var stroke = DrawingPalette.defaultBorder
	private(set) var fill = DrawingPalette.defaultFill
	private(set) var hasChanges = false
	/// The canvas size at 100% and the size of the view showing it.
	private(set) var canvasSize: CGSize = .zero
	private(set) var viewSize: CGSize = .zero
	private(set) var history: [Diagram] = []
	private(set) var future: [Diagram] = []

	/// The page's recognized text in the diagram's frame, for labelling traced shapes.
	@ObservationIgnored let traceLines: [RecognizedLine]
	@ObservationIgnored private var interaction = Interaction.idle
	@ObservationIgnored private var pinchStart: (zoom: CGFloat, pan: CGSize)?
	@ObservationIgnored private var ignoresTouch = false
	@ObservationIgnored private var lastTap: (time: Date, point: CGPoint)?
	@ObservationIgnored private var labelSessionOpen = false

	private enum Interaction {
		case idle
		/// Touch down, not yet far enough to be a drag (view points).
		case pending(start: CGPoint, hit: DrawingHit)
		case moving(id: String, origin: CGRect, start: CGPoint)
		case resizing(id: String, handle: ResizeHandle, origin: CGRect, start: CGPoint)
		case connecting
		case drawing(shape: Diagram.Shape, start: CGPoint)
		/// Panning a zoomed canvas (view points).
		case panning(origin: CGSize, start: CGPoint)
	}

	init(diagram: Diagram, traceLines: [RecognizedLine]) {
		self.diagram = diagram
		self.traceLines = traceLines
	}

	// MARK: Layout and coordinates

	/// Fits the canvas (the diagram's aspect) into a view of `size`.
	func layout(in size: CGSize) {
		guard size.width > 0, size.height > 0 else { return }
		let available = CGSize(width: max(size.width - 2 * Self.canvasInset, 1), height: max(size.height - 2 * Self.canvasInset, 1))
		let aspect = CGFloat(diagram.aspect > 0 ? diagram.aspect : 1)
		let width = min(available.width, available.height * aspect)
		viewSize = size
		canvasSize = CGSize(width: width, height: width / aspect)
		clampPan()
	}

	/// The canvas's top-left corner in the view at 100% zoom and no pan.
	var origin: CGPoint {
		CGPoint(x: (viewSize.width - canvasSize.width) / 2, y: (viewSize.height - canvasSize.height) / 2)
	}

	func toView(_ point: CGPoint) -> CGPoint {
		CGPoint(x: origin.x + pan.width + point.x * zoom, y: origin.y + pan.height + point.y * zoom)
	}

	func toView(_ rect: CGRect) -> CGRect {
		let corner = toView(rect.origin)
		return CGRect(x: corner.x, y: corner.y, width: rect.width * zoom, height: rect.height * zoom)
	}

	func toCanvas(_ point: CGPoint) -> CGPoint {
		guard zoom > 0 else { return point }
		return CGPoint(x: (point.x - origin.x - pan.width) / zoom, y: (point.y - origin.y - pan.height) / zoom)
	}

	/// A node's box in canvas points.
	func rect(of node: Diagram.Node) -> CGRect {
		DiagramGeometry.rect(node.box, in: canvasSize)
	}

	/// The four connection points around a shape (canvas points), clockwise from the top.
	func connectionPoints(around rect: CGRect) -> [CGPoint] {
		let offset = Self.connectionOffset / max(zoom, 1)
		return [CGPoint(x: rect.midX, y: rect.minY - offset), CGPoint(x: rect.maxX + offset, y: rect.midY),
				CGPoint(x: rect.midX, y: rect.maxY + offset), CGPoint(x: rect.minX - offset, y: rect.midY)]
	}

	/// An edge's line in canvas points, or nil when its shapes overlap.
	func segment(of edge: Diagram.Edge) -> (start: CGPoint, end: CGPoint)? {
		guard let from = diagram.node(edge.from), let to = diagram.node(edge.to) else { return nil }
		return DiagramGeometry.connector(from: from, to: to, direction: edge.direction, in: canvasSize)
	}

	var selectedNode: Diagram.Node? {
		guard case .node(let id) = selection else { return nil }
		return diagram.node(id)
	}

	var selectedEdge: Diagram.Edge? {
		guard case .edge(let id) = selection else { return nil }
		return diagram.edges.first { $0.id == id }
	}

	var canUndo: Bool { !history.isEmpty }
	var canRedo: Bool { !future.isEmpty }

	// MARK: Hit testing

	/// What a touch at `point` (canvas points) lands on, topmost first.
	func hit(at point: CGPoint) -> DrawingHit {
		let reach = Self.touchRadius / max(zoom, 1)
		if tool == .select, let node = selectedNode {
			let box = rect(of: node)
			if let handle = ResizeHandle.allCases.first(where: { handle in distance(handle.point(in: box), point) <= reach }) {
				return .handle(node.id, handle)
			}
			if connectionPoints(around: box).contains(where: { distance($0, point) <= reach }) {
				return .connectionPoint(node.id)
			}
		}
		let slack = 6 / max(zoom, 1)
		if let node = diagram.nodes.last(where: { rect(of: $0).insetBy(dx: -slack, dy: -slack).contains(point) }) {
			return .node(node.id)
		}
		let edge = diagram.edges.first { edge in
			guard let line = segment(of: edge) else { return false }
			return DiagramGeometry.distance(from: point, toSegment: line.start, line.end) <= 12 / max(zoom, 1)
		}
		return edge.map { .edge($0.id) } ?? .canvas
	}

	private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
		hypot(a.x - b.x, a.y - b.y)
	}

	// MARK: Touches (view points)

	/// A finger moved (or just touched down) on the canvas.
	func touchChanged(start: CGPoint, location: CGPoint) {
		guard pinchStart == nil, !ignoresTouch, canvasSize.width > 0 else { return }
		switch interaction {
		case .idle:
			interaction = .pending(start: start, hit: hit(at: toCanvas(start)))
		case .pending(let origin, let hit):
			guard distance(origin, location) > Self.dragSlop else { return }
			begin(hit, at: origin)
			proceed(to: location)
		default:
			proceed(to: location)
		}
	}

	/// The finger lifted.
	func touchEnded(start: CGPoint, location: CGPoint) {
		defer {
			interaction = .idle
			guides = []
			draft = nil
			pendingConnector = nil
			ignoresTouch = false
		}
		guard !ignoresTouch, pinchStart == nil else { return }
		switch interaction {
		case .idle, .pending:
			tap(at: start)
		case .connecting:
			finishConnector()
		case .drawing(let shape, let origin):
			finishDrawing(shape, from: origin, to: clamped(toCanvas(location)))
		case .moving, .resizing:
			if history.last == diagram { history.removeLast() }
		case .panning:
			break
		}
	}

	/// Decides what a drag that started on `hit` does.
	private func begin(_ hit: DrawingHit, at viewStart: CGPoint) {
		let start = toCanvas(viewStart)
		switch (tool, hit) {
		case (.shape(let shape), _):
			interaction = .drawing(shape: shape, start: clamped(start))
		case (.connector(let direction), .node(let id)), (.connector(let direction), .handle(let id, _)),
			 (.connector(let direction), .connectionPoint(let id)):
			startConnector(from: id, direction: direction)
		case (.select, .connectionPoint(let id)):
			startConnector(from: id, direction: .forward)
		case (.select, .handle(let id, let handle)):
			guard let node = diagram.node(id) else { return }
			recordStep()
			interaction = .resizing(id: id, handle: handle, origin: rect(of: node), start: start)
		case (.select, .node(let id)):
			guard let node = diagram.node(id) else { return }
			recordStep()
			selection = .node(id)
			interaction = .moving(id: id, origin: rect(of: node), start: start)
		default:
			interaction = .panning(origin: pan, start: viewStart)
		}
	}

	/// Carries the current drag on to `location`.
	private func proceed(to location: CGPoint) {
		let point = toCanvas(location)
		switch interaction {
		case .moving(let id, let origin, let start):
			move(id, from: origin, by: CGSize(width: point.x - start.x, height: point.y - start.y))
		case .resizing(let id, let handle, let origin, let start):
			resize(id, handle: handle, from: origin, by: CGSize(width: point.x - start.x, height: point.y - start.y))
		case .connecting:
			updateConnector(to: point)
		case .drawing(_, let start):
			let end = clamped(point)
			draft = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
		case .panning(let origin, let start):
			pan = CGSize(width: origin.width + location.x - start.x, height: origin.height + location.y - start.y)
			clampPan()
		case .idle, .pending:
			break
		}
	}

	private func tap(at viewPoint: CGPoint) {
		let point = toCanvas(viewPoint)
		let isDouble = registerTap(at: viewPoint)
		switch tool {
		case .shape(let shape):
			addShape(shape, in: defaultRect(centredAt: point))
		case .connector:
			if case .node(let id) = hit(at: point) { selection = .node(id) }
		case .select:
			select(hit(at: point), double: isDouble)
		}
	}

	private func select(_ hit: DrawingHit, double: Bool) {
		switch hit {
		case .node(let id), .handle(let id, _), .connectionPoint(let id):
			selection = .node(id)
		case .edge(let id):
			selection = .edge(id)
		case .canvas:
			selection = nil
			return
		}
		if double { labelRequest += 1 }
	}

	/// True when this tap follows the last one closely enough to be a double tap.
	private func registerTap(at point: CGPoint) -> Bool {
		let now = Date()
		defer { lastTap = (now, point) }
		guard let last = lastTap else { return false }
		return now.timeIntervalSince(last.time) < 0.35 && distance(point, last.point) < 24
	}

	// MARK: Moving, resizing, drawing, connecting

	private func move(_ id: String, from origin: CGRect, by translation: CGSize) {
		var moved = origin.offsetBy(dx: translation.width, dy: translation.height)
		moved.origin.x = min(max(moved.minX, 0), max(canvasSize.width - moved.width, 0))
		moved.origin.y = min(max(moved.minY, 0), max(canvasSize.height - moved.height, 0))
		let snap = DiagramSnapping.snapMove(moved, others: otherRects(excluding: id), canvas: canvasSize,
											threshold: Self.snapDistance / max(zoom, 1))
		guides = snap.guides
		setRect(snap.rect, of: id)
	}

	private func resize(_ id: String, handle: ResizeHandle, from origin: CGRect, by translation: CGSize) {
		let canvas = CGRect(origin: .zero, size: canvasSize)
		let resized = handle.resized(origin, by: translation, minimum: Self.minimumSide).intersection(canvas)
		guard resized.width >= Self.minimumSide / 2, resized.height >= Self.minimumSide / 2 else { return }
		let snap = DiagramSnapping.snapResize(resized, handle: handle, others: otherRects(excluding: id), canvas: canvasSize,
											  threshold: Self.snapDistance / max(zoom, 1), minimum: Self.minimumSide)
		guides = snap.guides
		setRect(snap.rect, of: id)
	}

	private func otherRects(excluding id: String) -> [CGRect] {
		diagram.nodes.filter { $0.id != id }.map(rect(of:))
	}

	private func setRect(_ rect: CGRect, of id: String) {
		let box = DiagramGeometry.box(rect, in: canvasSize)
		diagram.updateNode(id) { $0.box = box }
		hasChanges = true
	}

	private func finishDrawing(_ shape: Diagram.Shape, from start: CGPoint, to end: CGPoint) {
		let drawn = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
		let tooSmall = drawn.width < Self.minimumSide || drawn.height < Self.minimumSide
		addShape(shape, in: tooSmall ? defaultRect(centredAt: start) : drawn)
	}

	/// Adds a shape labelled with the page text under it, selects it, and
	/// asks for a label when the page had none there.
	private func addShape(_ shape: Diagram.Shape, in rect: CGRect) {
		guard canvasSize.width > 0, rect.width > 0, rect.height > 0 else { return }
		let box = DiagramGeometry.box(rect, in: canvasSize)
		let label = TraceLabels.label(in: box, lines: traceLines)
		let (stroke, fill) = (self.stroke, self.fill)
		guard let id = commit({ $0.addNode(shape: shape, box: box, label: label, stroke: stroke, fill: fill) }) else { return }
		selection = .node(id)
		tool = .select
		if label.isEmpty { labelRequest += 1 }
	}

	/// A default-size shape centred on `point`, inside the canvas.
	func defaultRect(centredAt point: CGPoint) -> CGRect {
		let scale = max(zoom, 1)
		let width = min(Self.defaultSize.width / scale, canvasSize.width), height = min(Self.defaultSize.height / scale, canvasSize.height)
		let x = min(max(point.x - width / 2, 0), canvasSize.width - width)
		let y = min(max(point.y - height / 2, 0), canvasSize.height - height)
		return CGRect(x: x, y: y, width: width, height: height)
	}

	private func clamped(_ point: CGPoint) -> CGPoint {
		CGPoint(x: min(max(point.x, 0), canvasSize.width), y: min(max(point.y, 0), canvasSize.height))
	}

	private func startConnector(from id: String, direction: Diagram.Direction) {
		guard let node = diagram.node(id) else { return }
		let box = rect(of: node)
		pendingConnector = PendingConnector(from: id, end: CGPoint(x: box.midX, y: box.midY), target: nil, direction: direction)
		interaction = .connecting
	}

	private func updateConnector(to point: CGPoint) {
		guard var pending = pendingConnector else { return }
		let slack = Self.touchRadius / max(zoom, 1)
		pending.end = point
		pending.target = diagram.nodes.last { $0.id != pending.from && rect(of: $0).insetBy(dx: -slack, dy: -slack).contains(point) }?.id
		pendingConnector = pending
	}

	private func finishConnector() {
		guard let pending = pendingConnector, let target = pending.target else { return }
		guard let id = commit({ $0.connect(pending.from, target, direction: pending.direction) }) else { return }
		selection = .edge(id)
		tool = .select
	}

	// MARK: Zoom and pan

	/// Two fingers pinching around `anchor` (view points), `scale` relative to the pinch's start.
	func pinchChanged(scale: CGFloat, anchor: CGPoint) {
		if pinchStart == nil {
			pinchStart = (zoom, pan)
			interaction = .idle
			guides = []
			draft = nil
			pendingConnector = nil
			ignoresTouch = true
		}
		guard let start = pinchStart, start.zoom > 0 else { return }
		let newZoom = min(max(start.zoom * scale, 1), Self.maxZoom)
		let fixed = CGPoint(x: (anchor.x - origin.x - start.pan.width) / start.zoom, y: (anchor.y - origin.y - start.pan.height) / start.zoom)
		zoom = newZoom
		pan = CGSize(width: anchor.x - origin.x - fixed.x * newZoom, height: anchor.y - origin.y - fixed.y * newZoom)
		clampPan()
	}

	func pinchEnded() {
		pinchStart = nil
	}

	/// Back to the whole canvas at 100%.
	func resetZoom() {
		zoom = 1
		pan = .zero
	}

	/// Keeps a zoomed canvas on screen and centres one that fits.
	private func clampPan() {
		pan = CGSize(width: Self.clampedOffset(pan.width, content: canvasSize.width * zoom, view: viewSize.width, origin: origin.x),
					 height: Self.clampedOffset(pan.height, content: canvasSize.height * zoom, view: viewSize.height, origin: origin.y))
	}

	static func clampedOffset(_ value: CGFloat, content: CGFloat, view: CGFloat, origin: CGFloat) -> CGFloat {
		guard content > view - 2 * canvasInset else { return (view - content) / 2 - origin }
		let low = view - canvasInset - origin - content, high = canvasInset - origin
		return min(max(value, low), high)
	}

	// MARK: Undo

	/// Applies an edit as one undo step and returns what it returned; an edit
	/// that changes nothing leaves the history alone.
	@discardableResult
	private func commit<Result>(_ change: (inout Diagram) -> Result) -> Result {
		var updated = diagram
		let result = change(&updated)
		guard updated != diagram else { return result }
		recordStep()
		diagram = updated
		hasChanges = true
		return result
	}

	/// Saves the current diagram as an undo step (a drag records once, at its start).
	private func recordStep() {
		history.append(diagram)
		if history.count > Self.maxUndo { history.removeFirst() }
		future.removeAll()
	}

	func undo() {
		guard let previous = history.popLast() else { return }
		future.append(diagram)
		diagram = previous
		dropStaleSelection()
	}

	func redo() {
		guard let next = future.popLast() else { return }
		history.append(diagram)
		diagram = next
		dropStaleSelection()
	}

	private func dropStaleSelection() {
		switch selection {
		case .node(let id) where diagram.node(id) == nil, .edge(let id) where !diagram.edges.contains(where: { $0.id == id }):
			selection = nil
		default:
			break
		}
	}

	// MARK: Commands

	func selectTool(_ next: DrawingTool) {
		tool = next
		if next != .select { selection = nil }
	}

	/// Adds a shape in the middle of what's on screen (the accessible way to add one).
	func dropShape(_ shape: Diagram.Shape) {
		let centre = toCanvas(CGPoint(x: viewSize.width / 2, y: viewSize.height / 2))
		addShape(shape, in: defaultRect(centredAt: clamped(centre)))
	}

	func setShape(_ shape: Diagram.Shape) {
		guard case .node(let id) = selection else { return }
		commit { $0.updateNode(id) { $0.shape = shape } }
	}

	func setStroke(_ color: RGBColor) {
		stroke = color
		guard case .node(let id) = selection else { return }
		commit { $0.updateNode(id) { $0.stroke = color } }
	}

	func setFill(_ color: RGBColor?) {
		fill = color
		guard case .node(let id) = selection else { return }
		commit { $0.updateNode(id) { $0.fill = color } }
	}

	func duplicateSelection() {
		guard case .node(let id) = selection, canvasSize.width > 0 else { return }
		let offset = Double(16 / canvasSize.width)
		if let copy = commit({ $0.duplicateNode(id, offset: offset) }) { selection = .node(copy) }
	}

	func deleteSelection() {
		switch selection {
		case .node(let id): commit { $0.removeNode(id) }
		case .edge(let id): commit { $0.removeEdge(id) }
		case nil: return
		}
		selection = nil
	}

	func reorderSelection(toFront: Bool) {
		guard case .node(let id) = selection else { return }
		commit { $0.reorderNode(id, toFront: toFront) }
	}

	func setDirection(_ direction: Diagram.Direction) {
		guard case .edge(let id) = selection else { return }
		commit { $0.updateEdge(id) { $0.direction = direction } }
	}

	func reverseSelection() {
		guard case .edge(let id) = selection else { return }
		commit { $0.reverseEdge(id) }
	}

	/// "Looks right": settles an uncertain edge as it is.
	func confirmSelectedEdge() {
		guard case .edge(let id) = selection else { return }
		commit { $0.updateEdge(id) { _ in } }
	}

	/// Moves the selected shape by a fraction of the canvas (VoiceOver's move actions).
	func nudgeSelection(dx: Double, dy: Double) {
		guard let node = selectedNode else { return }
		commit { diagram in
			diagram.updateNode(node.id) { node in
				node.box.x = min(max(node.box.x + dx, 0), max(1 - node.box.width, 0))
				node.box.y = min(max(node.box.y + dy, 0), max(1 - node.box.height, 0))
			}
		}
	}

	// MARK: Labels

	/// The selected shape's or connector's label.
	var selectedLabel: String {
		selectedNode?.label ?? selectedEdge?.label ?? ""
	}

	/// Opens one undo step for a stretch of typing.
	func beginLabelEdit() {
		guard selection != nil, !labelSessionOpen else { return }
		labelSessionOpen = true
		recordStep()
	}

	func setLabel(_ text: String) {
		switch selection {
		case .node(let id):
			diagram.updateNode(id) { $0.label = text }
		case .edge(let id):
			guard let index = diagram.edges.firstIndex(where: { $0.id == id }) else { return }
			diagram.edges[index].label = text.isEmpty ? nil : text
		case nil:
			return
		}
		hasChanges = true
	}

	/// Closes the typing step, dropping it if nothing changed.
	func endLabelEdit() {
		guard labelSessionOpen else { return }
		labelSessionOpen = false
		if history.last == diagram { history.removeLast() }
	}
}
