//
//  PageGeometry.swift
//  Rescriva (fork of Open Scanner)
//
//  The pure geometry behind "Adjust page": how a crop quad is stored, which
//  handle a touch grabs, how a drag moves the quad (and when the move is
//  refused), where the loupe sits, undo and redo, and the mapping between the
//  editor's view space and the original photo's normalized space, rotation
//  included. Foundation and CoreGraphics only, so all of it is unit-tested
//  without a device.
//

import CoreGraphics
import Foundation

// MARK: - Storage

extension PageQuad {
	/// The quad as stored on `ScanCapture.cropQuad`: "x,y;x,y;x,y;x,y", clockwise from the
	/// top-left corner, normalized to the upright original (top-left origin). Locale-independent.
	var storageString: String {
		corners.map { String(format: "%.5f,%.5f", Double($0.x), Double($0.y)) }.joined(separator: ";")
	}

	/// Parses `storageString`; nil unless it holds exactly four finite points.
	init?(storageString: String) {
		let pairs = storageString.split(separator: ";")
		guard pairs.count == 4 else { return nil }
		var points: [CGPoint] = []
		for pair in pairs {
			let values = pair.split(separator: ",").compactMap { Double($0) }
			guard values.count == 2, values.allSatisfy(\.isFinite) else { return nil }
			points.append(CGPoint(x: values[0], y: values[1]))
		}
		self.init(topLeft: points[0], topRight: points[1], bottomRight: points[2], bottomLeft: points[3])
	}
}

// MARK: - Rotation

/// Clockwise quarter turns. Every stored or computed rotation goes through `normalized`.
enum QuarterTurns {
	/// `turns` folded into 0...3 (−1 is 3, 5 is 1).
	static func normalized(_ turns: Int) -> Int {
		((turns % 4) + 4) % 4
	}
}

// MARK: - Handles

/// What a touch in the crop editor grabs.
enum QuadHandle: Hashable {
	/// A corner, by index into `PageQuad.corners` (0 is top-left, then clockwise).
	case corner(Int)
	/// An edge midpoint: edge `i` joins corners `i` and `i + 1` (0 top, 1 right, 2 bottom, 3 left).
	/// Dragging it moves both of its corners.
	case edge(Int)
	/// The middle: dragging it moves the whole quad.
	case body

	/// Every handle, corners first, so a tie in `QuadEditing.nearestHandle` goes to a corner.
	static let all: [QuadHandle] = (0..<4).map { QuadHandle.corner($0) } + (0..<4).map { QuadHandle.edge($0) } + [.body]
}

// MARK: - Editing

/// The crop editor's rules, on quads normalized to the original photo.
enum QuadEditing {
	/// The smallest crop, as a fraction of the photo. `PageCleanup.correctPerspective` leaves
	/// anything smaller uncorrected, so the editor never produces one.
	static let minimumArea: CGFloat = 0.01

	/// Where `handle` sits, given the quad's four corners in any space.
	static func point(of handle: QuadHandle, corners: [CGPoint]) -> CGPoint {
		guard corners.count == 4 else { return .zero }
		switch handle {
		case .corner(let index):
			return corners[QuarterTurns.normalized(index)]
		case .edge(let index):
			let start = corners[QuarterTurns.normalized(index)]
			let end = corners[QuarterTurns.normalized(index + 1)]
			return CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
		case .body:
			return CGPoint(x: corners.reduce(0) { $0 + $1.x } / 4, y: corners.reduce(0) { $0 + $1.y } / 4)
		}
	}

	/// The handle nearest `location`: a corner, an edge midpoint or the middle. Measure in view
	/// space (points), where distances mean what the finger feels. Corners win ties.
	static func nearestHandle(to location: CGPoint, corners: [CGPoint]) -> QuadHandle {
		guard corners.count == 4 else { return .body }
		var nearest = QuadHandle.body
		var nearestDistance = CGFloat.infinity
		for handle in QuadHandle.all {
			let point = point(of: handle, corners: corners)
			let distance = hypot(point.x - location.x, point.y - location.y)
			if distance < nearestDistance {
				nearest = handle
				nearestDistance = distance
			}
		}
		return nearest
	}

	/// `quad` with `handle` dragged by `delta` (normalized units), or nil when the result would
	/// be non-convex, smaller than `minimumArea`, or otherwise unusable.
	///
	/// Moved points stay inside the photo: a corner slides along the border it meets, and an edge
	/// or the whole quad stops at the border without changing shape.
	static func moved(_ quad: PageQuad, handle: QuadHandle, by delta: CGVector) -> PageQuad? {
		guard delta.dx.isFinite, delta.dy.isFinite else { return nil }
		var points = quad.corners
		let indices: [Int]
		switch handle {
		case .corner(let index):
			indices = [QuarterTurns.normalized(index)]
		case .edge(let index):
			indices = [QuarterTurns.normalized(index), QuarterTurns.normalized(index + 1)]
		case .body:
			indices = [0, 1, 2, 3]
		}
		let allowed = clampedDelta(delta, moving: indices.map { points[$0] })
		for index in indices {
			points[index] = clamped(CGPoint(x: points[index].x + allowed.dx, y: points[index].y + allowed.dy))
		}
		let result = PageQuad(topLeft: points[0], topRight: points[1], bottomRight: points[2], bottomLeft: points[3])
		guard isAcceptable(result) else { return nil }
		return result
	}

	/// `delta` shortened per axis so every one of `points` stays inside the unit square.
	static func clampedDelta(_ delta: CGVector, moving points: [CGPoint]) -> CGVector {
		guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
			  let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else { return .zero }
		let dx = min(max(delta.dx, -minX), 1 - maxX)
		let dy = min(max(delta.dy, -minY), 1 - maxY)
		return CGVector(dx: dx, dy: dy)
	}

	/// `point` moved to the nearest place inside the unit square.
	static func clamped(_ point: CGPoint) -> CGPoint {
		CGPoint(x: min(max(point.x, 0), 1), y: min(max(point.y, 0), 1))
	}

	/// `quad` with every corner moved inside the unit square (detected quads can stray a hair out).
	static func clamped(_ quad: PageQuad) -> PageQuad {
		PageQuad(topLeft: clamped(quad.topLeft), topRight: clamped(quad.topRight),
				 bottomRight: clamped(quad.bottomRight), bottomLeft: clamped(quad.bottomLeft))
	}

	/// True for a crop the re-processor can use: inside the photo, strictly convex, still wound
	/// clockwise and big enough.
	static func isAcceptable(_ quad: PageQuad) -> Bool {
		let inside = quad.corners.allSatisfy { (0...1).contains($0.x) && (0...1).contains($0.y) }
		guard inside else { return false }
		return quad.isConvex && isClockwise(quad) && quad.area >= minimumArea
	}

	/// True when the corners run clockwise on screen (top-left, top-right, bottom-right,
	/// bottom-left), as perspective correction expects. An edge dragged past the opposite one in a
	/// single step turns the crop inside out: still convex, but wound the other way, and it would
	/// make a mirrored page.
	static func isClockwise(_ quad: PageQuad) -> Bool {
		let points = quad.corners
		assert(points.count == 4, "a quad has four corners")
		var twiceSignedArea: CGFloat = 0
		for index in points.indices {
			let current = points[index]
			let next = points[(index + 1) % points.count]
			twiceSignedArea += current.x * next.y - next.x * current.y
		}
		// With y pointing down, a positive shoelace sum runs clockwise.
		return twiceSignedArea > 0
	}

	/// The position (0 top-left / top … 3 bottom-left / left) where corner or edge `index` of the
	/// original appears once the page is turned `quarterTurns` clockwise.
	static func visualIndex(_ index: Int, quarterTurns: Int) -> Int {
		QuarterTurns.normalized(index + quarterTurns)
	}
}

// MARK: - View mapping

/// Maps between the editor's view space (points, top-left origin) and normalized coordinates on
/// the upright original photo, for the original drawn turned `quarterTurns` clockwise and
/// aspect-fitted into a rectangle.
struct QuadViewMapping: Equatable {
	/// The original's size in pixels, upright and unturned.
	let imageSize: CGSize
	/// Clockwise quarter turns the photo is drawn with, 0...3.
	let quarterTurns: Int
	/// Where the turned photo is drawn, in view space.
	let frame: CGRect

	init(imageSize: CGSize, quarterTurns: Int, fittingIn bounds: CGRect) {
		self.imageSize = imageSize
		self.quarterTurns = QuarterTurns.normalized(quarterTurns)
		frame = Self.aspectFit(Self.rotatedSize(imageSize, quarterTurns: quarterTurns), in: bounds)
	}

	/// `size` after `quarterTurns` clockwise turns (odd turns swap width and height).
	static func rotatedSize(_ size: CGSize, quarterTurns: Int) -> CGSize {
		QuarterTurns.normalized(quarterTurns) % 2 == 0 ? size : CGSize(width: size.height, height: size.width)
	}

	/// The largest rectangle of `size`'s aspect that fits in `bounds`, centred.
	static func aspectFit(_ size: CGSize, in bounds: CGRect) -> CGRect {
		guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else {
			return CGRect(origin: CGPoint(x: bounds.midX, y: bounds.midY), size: .zero)
		}
		let scale = min(bounds.width / size.width, bounds.height / size.height)
		let fitted = CGSize(width: size.width * scale, height: size.height * scale)
		return CGRect(x: bounds.midX - fitted.width / 2, y: bounds.midY - fitted.height / 2,
					  width: fitted.width, height: fitted.height)
	}

	/// A normalized point on the original → the same spot on the photo turned clockwise.
	static func rotated(_ point: CGPoint, quarterTurns: Int) -> CGPoint {
		switch QuarterTurns.normalized(quarterTurns) {
		case 1: return CGPoint(x: 1 - point.y, y: point.x)
		case 2: return CGPoint(x: 1 - point.x, y: 1 - point.y)
		case 3: return CGPoint(x: point.y, y: 1 - point.x)
		default: return point
		}
	}

	/// The inverse of `rotated`.
	static func unrotated(_ point: CGPoint, quarterTurns: Int) -> CGPoint {
		rotated(point, quarterTurns: 4 - QuarterTurns.normalized(quarterTurns))
	}

	/// A normalized point on the original → view space.
	func viewPoint(_ normalized: CGPoint) -> CGPoint {
		let turned = Self.rotated(normalized, quarterTurns: quarterTurns)
		return CGPoint(x: frame.minX + turned.x * frame.width, y: frame.minY + turned.y * frame.height)
	}

	/// A view point → normalized coordinates on the original (not clamped).
	func normalizedPoint(_ viewPoint: CGPoint) -> CGPoint {
		guard frame.width > 0, frame.height > 0 else { return .zero }
		let turned = CGPoint(x: (viewPoint.x - frame.minX) / frame.width, y: (viewPoint.y - frame.minY) / frame.height)
		return Self.unrotated(turned, quarterTurns: quarterTurns)
	}

	/// A drag's translation in view space → the same move on the original, normalized.
	func normalizedDelta(_ translation: CGSize) -> CGVector {
		let start = normalizedPoint(frame.origin)
		let end = normalizedPoint(CGPoint(x: frame.minX + translation.width, y: frame.minY + translation.height))
		return CGVector(dx: end.x - start.x, dy: end.y - start.y)
	}

	/// The quad's corners in view space, in the quad's own (unturned) order.
	func viewCorners(of quad: PageQuad) -> [CGPoint] {
		quad.corners.map(viewPoint)
	}
}

// MARK: - Loupe

/// Where the magnifier sits while a handle is dragged.
enum LoupePlacement {
	/// The centre of a loupe of `diameter` for a finger at `touch`: above the finger, `gap` clear
	/// of it; beside it (on the roomier side) when there is no room above; always inside `bounds`.
	static func center(touch: CGPoint, diameter: CGFloat, gap: CGFloat, in bounds: CGSize) -> CGPoint {
		let radius = max(diameter, 0) / 2
		var center = CGPoint(x: touch.x, y: touch.y - gap - radius)
		if center.y < radius {
			let side: CGFloat = touch.x > bounds.width / 2 ? -1 : 1
			center = CGPoint(x: touch.x + side * (gap + radius), y: touch.y)
		}
		center.x = min(max(center.x, radius), max(radius, bounds.width - radius))
		center.y = min(max(center.y, radius), max(radius, bounds.height - radius))
		return center
	}
}

// MARK: - History

/// Undo and redo for one editing session, as snapshots of the editor's state.
struct EditHistory<State: Equatable> {
	/// Snapshots older than this many steps are dropped.
	let limit: Int
	private(set) var undoStack: [State] = []
	private(set) var redoStack: [State] = []

	init(limit: Int = 100) {
		self.limit = max(1, limit)
	}

	var canUndo: Bool { !undoStack.isEmpty }
	var canRedo: Bool { !redoStack.isEmpty }

	/// Records that the state just changed away from `previous`. Clears redo.
	mutating func record(_ previous: State) {
		undoStack.append(previous)
		if undoStack.count > limit {
			undoStack.removeFirst(undoStack.count - limit)
		}
		redoStack.removeAll()
	}

	/// The state to go back to from `current`, or nil when there is nothing to undo.
	mutating func undo(from current: State) -> State? {
		guard let previous = undoStack.popLast() else { return nil }
		redoStack.append(current)
		return previous
	}

	/// The state to go forward to from `current`, or nil when there is nothing to redo.
	mutating func redo(from current: State) -> State? {
		guard let next = redoStack.popLast() else { return nil }
		undoStack.append(current)
		return next
	}
}
