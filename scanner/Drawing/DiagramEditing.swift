//
//  DiagramEditing.swift
//  Rescriva (fork of Open Scanner)
//
//  The drawing editor's edits as pure functions on `Diagram`, the resize
//  handles, the smart guides that snap a moving or resizing shape to its
//  neighbours (Google Drawings' alignment lines), and the labels a traced
//  shape picks up from the page's recognized text. CoreGraphics only and
//  free of UI state, so every rule is unit-tested off-device.
//

import CoreGraphics
import Foundation

// MARK: - Edits

extension Diagram {
	/// Most nodes the editor lets a diagram hold; bounds every loop over them.
	static let maxEditableNodes = 120
	/// Most edges the editor lets a diagram hold.
	static let maxEditableEdges = 240

	/// The first id of the form `prefix` + number that `ids` doesn't use.
	static func unusedID(prefix: String, among ids: [String]) -> String {
		let taken = Set(ids)
		for number in 1...(taken.count + 1) where !taken.contains("\(prefix)\(number)") {
			return "\(prefix)\(number)"
		}
		return "\(prefix)\(UUID().uuidString)"
	}

	/// Adds a node on top of the others and returns its id, or nil when the diagram is full.
	mutating func addNode(shape: Shape, box: NormalizedBox, label: String, stroke: RGBColor, fill: RGBColor?) -> String? {
		guard nodes.count < Self.maxEditableNodes, box.width > 0, box.height > 0 else { return nil }
		let id = Self.unusedID(prefix: "n", among: nodes.map(\.id))
		nodes.append(Node(id: id, label: label, shape: shape, box: box, stroke: stroke, fill: fill))
		return id
	}

	/// Removes a node and every edge that touches it.
	mutating func removeNode(_ id: String) {
		guard nodes.contains(where: { $0.id == id }) else { return }
		nodes.removeAll { $0.id == id }
		edges.removeAll { $0.from == id || $0.to == id }
	}

	mutating func updateNode(_ id: String, _ change: (inout Node) -> Void) {
		guard let index = nodes.firstIndex(where: { $0.id == id }) else { return }
		change(&nodes[index])
	}

	/// A copy of the node, offset down and to the right by `offset` (normalized), on top.
	mutating func duplicateNode(_ id: String, offset: Double) -> String? {
		guard let original = node(id) else { return nil }
		var box = original.box
		box.x = min(box.x + offset, max(0, 1 - box.width))
		box.y = min(box.y + offset, max(0, 1 - box.height))
		return addNode(shape: original.shape, box: box, label: original.label, stroke: original.stroke, fill: original.fill)
	}

	/// Draws the node above (or below) every other node.
	mutating func reorderNode(_ id: String, toFront: Bool) {
		guard let index = nodes.firstIndex(where: { $0.id == id }) else { return }
		let moved = nodes.remove(at: index)
		if toFront { nodes.append(moved) } else { nodes.insert(moved, at: 0) }
	}

	/// Joins two nodes and returns the new edge's id; nil for a loop, an
	/// unknown node, a pair already joined (either way round) or a full diagram.
	mutating func connect(_ from: String, _ to: String, direction: Direction) -> String? {
		guard from != to, node(from) != nil, node(to) != nil, edges.count < Self.maxEditableEdges else { return nil }
		guard !edges.contains(where: { ($0.from == from && $0.to == to) || ($0.from == to && $0.to == from) }) else { return nil }
		let id = Self.unusedID(prefix: "e", among: edges.map(\.id))
		edges.append(Edge(id: id, from: from, to: to, direction: direction))
		return id
	}

	mutating func removeEdge(_ id: String) {
		edges.removeAll { $0.id == id }
	}

	/// Changes an edge and, if it carried an open flag, settles the flag:
	/// editing an arrow by hand is the answer to "which way does it go?".
	mutating func updateEdge(_ id: String, _ change: (inout Edge) -> Void) {
		guard let index = edges.firstIndex(where: { $0.id == id }) else { return }
		change(&edges[index])
		settleFlag(at: index)
	}

	/// Swaps an edge's ends (keeping its arrowheads' meaning: a → b becomes b → a).
	mutating func reverseEdge(_ id: String) {
		updateEdge(id) { edge in
			let from = edge.from
			edge.from = edge.to
			edge.to = from
		}
	}

	/// Marks an open edge flag as resolved with the edge as it now reads.
	private mutating func settleFlag(at index: Int) {
		guard edges.indices.contains(index), edges[index].flag != nil, edges[index].flag?.resolution == nil else { return }
		let edge = edges[index]
		let from = node(edge.from)?.label ?? edge.from, to = node(edge.to)?.label ?? edge.to
		edges[index].flag?.resolution = "\(from) \(edge.direction.textConnector) \(to)"
	}
}

// MARK: - Resize handles

/// One of the eight handles around a selected shape.
enum ResizeHandle: CaseIterable, Hashable {
	case topLeading, top, topTrailing, trailing, bottomTrailing, bottom, bottomLeading, leading

	var movesLeft: Bool { self == .topLeading || self == .leading || self == .bottomLeading }
	var movesRight: Bool { self == .topTrailing || self == .trailing || self == .bottomTrailing }
	var movesTop: Bool { self == .topLeading || self == .top || self == .topTrailing }
	var movesBottom: Bool { self == .bottomLeading || self == .bottom || self == .bottomTrailing }

	/// Where the handle sits on `rect`.
	func point(in rect: CGRect) -> CGPoint {
		let x = movesLeft ? rect.minX : (movesRight ? rect.maxX : rect.midX)
		let y = movesTop ? rect.minY : (movesBottom ? rect.maxY : rect.midY)
		return CGPoint(x: x, y: y)
	}

	/// `rect` with this handle dragged by `translation`, never smaller than `minimum` on a side.
	func resized(_ rect: CGRect, by translation: CGSize, minimum: CGFloat) -> CGRect {
		guard rect.width >= 0, rect.height >= 0 else { return rect }
		var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
		if movesLeft { minX = min(rect.minX + translation.width, rect.maxX - minimum) }
		if movesRight { maxX = max(rect.maxX + translation.width, rect.minX + minimum) }
		if movesTop { minY = min(rect.minY + translation.height, rect.maxY - minimum) }
		if movesBottom { maxY = max(rect.maxY + translation.height, rect.minY + minimum) }
		return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
	}
}

// MARK: - Smart guides

/// A smart guide: a line the moving shape now lines up with.
struct DiagramGuide: Hashable {
	enum Axis: Hashable {
		case vertical, horizontal
	}

	var axis: Axis
	/// x for a vertical guide, y for a horizontal one (canvas points).
	var position: CGFloat
	/// Where the line starts and ends along its own axis.
	var from: CGFloat
	var to: CGFloat
}

/// Snapping a shape's edges and centre lines to other shapes and the canvas.
enum DiagramSnapping {
	/// Moves `rect` by up to `threshold` so one of its left, centre or right
	/// lines (and top, middle or bottom lines) meets the same lines of another
	/// shape or the canvas, and returns the guides to draw.
	static func snapMove(_ rect: CGRect, others: [CGRect], canvas: CGSize, threshold: CGFloat) -> (rect: CGRect, guides: [DiagramGuide]) {
		guard threshold > 0 else { return (rect, []) }
		let targets = Targets(others: others, canvas: canvas)
		var snapped = rect
		if let dx = bestOffset(moving: [rect.minX, rect.midX, rect.maxX], targets: targets.x, threshold: threshold) {
			snapped.origin.x += dx
		}
		if let dy = bestOffset(moving: [rect.minY, rect.midY, rect.maxY], targets: targets.y, threshold: threshold) {
			snapped.origin.y += dy
		}
		return (snapped, guides(for: snapped, others: others, canvas: canvas))
	}

	/// Snaps only the edges `handle` moves, keeping at least `minimum` on a side.
	static func snapResize(_ rect: CGRect, handle: ResizeHandle, others: [CGRect], canvas: CGSize,
						   threshold: CGFloat, minimum: CGFloat) -> (rect: CGRect, guides: [DiagramGuide]) {
		guard threshold > 0 else { return (rect, []) }
		let targets = Targets(others: others, canvas: canvas)
		var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
		if handle.movesLeft, let d = bestOffset(moving: [minX], targets: targets.x, threshold: threshold) { minX = min(minX + d, maxX - minimum) }
		if handle.movesRight, let d = bestOffset(moving: [maxX], targets: targets.x, threshold: threshold) { maxX = max(maxX + d, minX + minimum) }
		if handle.movesTop, let d = bestOffset(moving: [minY], targets: targets.y, threshold: threshold) { minY = min(minY + d, maxY - minimum) }
		if handle.movesBottom, let d = bestOffset(moving: [maxY], targets: targets.y, threshold: threshold) { maxY = max(maxY + d, minY + minimum) }
		let snapped = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
		return (snapped, guides(for: snapped, others: others, canvas: canvas))
	}

	/// Every line a shape can snap to: the others' edges and centres, and the canvas's.
	private struct Targets {
		let x: [CGFloat]
		let y: [CGFloat]

		init(others: [CGRect], canvas: CGSize) {
			x = others.flatMap { [$0.minX, $0.midX, $0.maxX] } + [0, canvas.width / 2, canvas.width]
			y = others.flatMap { [$0.minY, $0.midY, $0.maxY] } + [0, canvas.height / 2, canvas.height]
		}
	}

	/// The smallest offset (within `threshold`) that puts one moving line on a target.
	static func bestOffset(moving: [CGFloat], targets: [CGFloat], threshold: CGFloat) -> CGFloat? {
		var best: CGFloat?
		for line in moving {
			for target in targets {
				let offset = target - line
				if abs(offset) <= threshold, abs(offset) < abs(best ?? .infinity) { best = offset }
			}
		}
		return best
	}

	/// Guides for every line of `rect` that another shape (or the canvas centre) shares.
	static func guides(for rect: CGRect, others: [CGRect], canvas: CGSize) -> [DiagramGuide] {
		let tolerance: CGFloat = 0.5
		var result = Set<DiagramGuide>()
		for other in others {
			for x in [rect.minX, rect.midX, rect.maxX] where [other.minX, other.midX, other.maxX].contains(where: { abs($0 - x) < tolerance }) {
				result.insert(DiagramGuide(axis: .vertical, position: x, from: min(rect.minY, other.minY), to: max(rect.maxY, other.maxY)))
			}
			for y in [rect.minY, rect.midY, rect.maxY] where [other.minY, other.midY, other.maxY].contains(where: { abs($0 - y) < tolerance }) {
				result.insert(DiagramGuide(axis: .horizontal, position: y, from: min(rect.minX, other.minX), to: max(rect.maxX, other.maxX)))
			}
		}
		if abs(rect.midX - canvas.width / 2) < tolerance {
			result.insert(DiagramGuide(axis: .vertical, position: canvas.width / 2, from: 0, to: canvas.height))
		}
		if abs(rect.midY - canvas.height / 2) < tolerance {
			result.insert(DiagramGuide(axis: .horizontal, position: canvas.height / 2, from: 0, to: canvas.width))
		}
		return Array(result)
	}
}

// MARK: - Labels from the page

/// The page's recognized text, re-used to label shapes traced over the original.
enum TraceLabels {
	/// Most lines one shape's label takes.
	static let maxLines = 6
	/// Longest label taken from the page.
	static let maxLength = 80

	/// The recognized lines whose centres sit inside `box` (both in the
	/// diagram's frame), top to bottom, joined by spaces; empty when none do.
	static func label(in box: NormalizedBox, lines: [RecognizedLine]) -> String {
		guard box.width > 0, box.height > 0 else { return "" }
		let inside = lines.filter { line in
			line.box.midX >= box.x && line.box.midX <= box.x + box.width && line.box.midY >= box.y && line.box.midY <= box.y + box.height
		}
		let ordered = inside.sorted { ($0.box.minY, $0.box.minX) < ($1.box.minY, $1.box.minX) }.prefix(maxLines)
		let text = ordered.map { $0.text.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
		return String(text.prefix(maxLength))
	}

	/// Page lines (normalized to the page) re-expressed in `frame`'s own 0–1
	/// coordinates, keeping only those whose centre falls inside the frame.
	static func lines(_ pageLines: [RecognizedLine], in frame: NormalizedBox) -> [RecognizedLine] {
		guard frame.width > 0, frame.height > 0 else { return [] }
		return pageLines.compactMap { line in
			let box = CGRect(x: (line.box.minX - frame.x) / frame.width, y: (line.box.minY - frame.y) / frame.height,
							 width: line.box.width / frame.width, height: line.box.height / frame.height)
			guard (0...1).contains(box.midX), (0...1).contains(box.midY) else { return nil }
			return RecognizedLine(text: line.text, confidence: line.confidence, alternatives: line.alternatives, box: box)
		}
	}
}
