//
//  PageMark.swift
//  Folio (fork of Open Scanner)
//
//  Annotations drawn over a scanned page: pen and highlighter strokes, lines,
//  arrows, rectangles and ovals. Marks live in page space (0…1 from the
//  top-left), so they stay put at any zoom, preview size or export size, and
//  the scan underneath is never changed.
//

import CoreGraphics
import Foundation

/// One annotation on a page.
struct PageMark: Identifiable, Equatable, Sendable {
	enum Kind: String, Codable, CaseIterable, Sendable {
		case pen, highlighter, line, arrow, rectangle, ellipse

		/// Freehand marks keep every sample; shapes keep their two drag ends.
		var isFreehand: Bool { self == .pen || self == .highlighter }
	}

	var id = UUID()
	var kind: Kind
	/// Page-space points (0…1 from the top-left). Shapes hold [start, end].
	var points: [CGPoint]
	/// sRGB color as 0xRRGGBB.
	var color: UInt32
	/// Stroke width as a fraction of the page width.
	var width: Double

	/// Rounds a page-space point to the precision marks are saved at
	/// (1/100,000 of the page — far finer than any scan's pixels), so a mark
	/// reads back exactly as it was drawn.
	static func quantized(_ point: CGPoint) -> CGPoint {
		CGPoint(x: quantized(point.x), y: quantized(point.y))
	}

	private static func quantized(_ value: CGFloat) -> CGFloat {
		(value * 100_000).rounded() / 100_000
	}
}

extension PageMark: Codable {
	private enum CodingKeys: String, CodingKey {
		case id, kind, points, color, width
	}

	init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		id = try container.decode(UUID.self, forKey: .id)
		kind = try container.decode(Kind.self, forKey: .kind)
		color = try container.decode(UInt32.self, forKey: .color)
		width = try container.decode(Double.self, forKey: .width)
		// Points are stored flat: [x0, y0, x1, y1, …].
		let flat = try container.decode([Double].self, forKey: .points)
		guard flat.count.isMultiple(of: 2), !flat.isEmpty else {
			throw DecodingError.dataCorruptedError(forKey: .points, in: container, debugDescription: "Points need x and y pairs")
		}
		points = stride(from: 0, to: flat.count, by: 2).map { CGPoint(x: CGFloat(flat[$0]), y: CGFloat(flat[$0 + 1])) }
	}

	func encode(to encoder: Encoder) throws {
		assert(!points.isEmpty, "A mark always has at least one point")
		var container = encoder.container(keyedBy: CodingKeys.self)
		try container.encode(id, forKey: .id)
		try container.encode(kind, forKey: .kind)
		try container.encode(color, forKey: .color)
		try container.encode(width, forKey: .width)
		try container.encode(points.map { Self.quantized($0) }.flatMap { [Double($0.x), Double($0.y)] }, forKey: .points)
	}
}

/// What's saved for one page. A mark this version can't read is skipped
/// rather than losing the whole page.
struct PageAnnotations: Codable, Equatable {
	var version = 1
	var marks: [PageMark]

	init(marks: [PageMark]) {
		self.marks = marks
	}

	private enum CodingKeys: String, CodingKey {
		case version, marks
	}

	init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
		let lossy = try container.decode([LossyMark].self, forKey: .marks)
		marks = lossy.compactMap(\.mark)
	}

	private struct LossyMark: Decodable {
		let mark: PageMark?

		init(from decoder: Decoder) throws {
			mark = try? PageMark(from: decoder)
		}
	}
}

/// Page-space geometry: hit testing for the eraser, shape snapping and
/// stroke simplification. Everything here works in a concrete `size` (view
/// points or page pixels) so distances aren't skewed by the page's aspect.
enum MarkGeometry {
	/// Snap lines to 45° steps within this many degrees.
	static let angleSnapDegrees: CGFloat = 4
	/// Snap rectangles and ovals to squares and circles within this ratio.
	static let squareSnapRatio: CGFloat = 0.08

	/// `points` scaled from page space into `size`.
	static func scaled(_ points: [CGPoint], to size: CGSize) -> [CGPoint] {
		points.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
	}

	/// The polyline the eraser tests against: the stroke itself for freehand
	/// marks, lines and arrows; the closed outline for rectangles and ovals.
	static func outline(of mark: PageMark, in size: CGSize) -> [CGPoint] {
		let points = scaled(mark.points, to: size)
		guard let first = points.first, let last = points.last else { return [] }
		switch mark.kind {
		case .pen, .highlighter:
			return points
		case .line, .arrow:
			return [first, last]
		case .rectangle:
			let rect = CGRect(corner: first, opposite: last)
			return [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
					CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY),
					CGPoint(x: rect.minX, y: rect.minY)]
		case .ellipse:
			let rect = CGRect(corner: first, opposite: last)
			let samples = 64
			return (0...samples).map { step in
				let angle = CGFloat(step) / CGFloat(samples) * 2 * .pi
				return CGPoint(x: rect.midX + cos(angle) * rect.width / 2, y: rect.midY + sin(angle) * rect.height / 2)
			}
		}
	}

	/// Distance from `point` to the nearest part of the mark's outline, in `size` units.
	static func distance(from point: CGPoint, to mark: PageMark, in size: CGSize) -> CGFloat {
		let outline = outline(of: mark, in: size)
		guard let first = outline.first else { return .infinity }
		guard outline.count > 1 else { return hypot(point.x - first.x, point.y - first.y) }
		var nearest = CGFloat.infinity
		for index in 1..<outline.count {
			nearest = min(nearest, segmentDistance(from: point, to: outline[index - 1], outline[index]))
		}
		return nearest
	}

	/// True when an eraser of `radius` at `point` touches the mark's ink.
	static func eraser(at point: CGPoint, radius: CGFloat, hits mark: PageMark, in size: CGSize) -> Bool {
		guard size.width > 0, size.height > 0 else { return false }
		return distance(from: point, to: mark, in: size) <= radius + CGFloat(mark.width) * size.width / 2
	}

	/// Distance from `point` to the segment `a`–`b`.
	static func segmentDistance(from point: CGPoint, to a: CGPoint, _ b: CGPoint) -> CGFloat {
		let dx = b.x - a.x
		let dy = b.y - a.y
		let lengthSquared = dx * dx + dy * dy
		guard lengthSquared > 0 else { return hypot(point.x - a.x, point.y - a.y) }
		let t = max(0, min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared))
		return hypot(point.x - (a.x + t * dx), point.y - (a.y + t * dy))
	}

	/// The end of a dragged shape after snapping: lines and arrows settle on
	/// the nearest 45° when they're within a few degrees of it, rectangles and
	/// ovals become squares and circles when they're nearly even.
	static func snappedEnd(for kind: PageMark.Kind, from start: CGPoint, to end: CGPoint) -> CGPoint {
		let dx = end.x - start.x
		let dy = end.y - start.y
		guard dx != 0 || dy != 0 else { return end }
		switch kind {
		case .line, .arrow:
			let angle = atan2(dy, dx)
			let step = CGFloat.pi / 4
			let snapped = (angle / step).rounded() * step
			guard abs(angle - snapped) <= angleSnapDegrees * .pi / 180 else { return end }
			let length = hypot(dx, dy)
			return CGPoint(x: start.x + cos(snapped) * length, y: start.y + sin(snapped) * length)
		case .rectangle, .ellipse:
			let side = max(abs(dx), abs(dy))
			guard side > 0, abs(abs(dx) - abs(dy)) / side <= squareSnapRatio else { return end }
			return CGPoint(x: start.x + (dx < 0 ? -side : side), y: start.y + (dy < 0 ? -side : side))
		case .pen, .highlighter:
			return end
		}
	}

	/// Drops points that sit within `tolerance` of the line through their
	/// neighbours (Ramer–Douglas–Peucker, iterative), keeping both ends.
	static func simplified(_ points: [CGPoint], tolerance: CGFloat) -> [CGPoint] {
		guard points.count > 2, tolerance > 0 else { return points }
		var keep = [Bool](repeating: false, count: points.count)
		keep[0] = true
		keep[points.count - 1] = true
		var ranges = [(0, points.count - 1)]
		// Each pass splits one range in two or retires it, so this ends within 2n passes.
		for _ in 0..<(points.count * 2) {
			guard let (start, end) = ranges.popLast() else { break }
			guard end > start + 1 else { continue }
			var farthest = start
			var farthestDistance: CGFloat = 0
			for index in (start + 1)..<end {
				let distance = segmentDistance(from: points[index], to: points[start], points[end])
				if distance > farthestDistance {
					farthest = index
					farthestDistance = distance
				}
			}
			guard farthestDistance > tolerance else { continue }
			keep[farthest] = true
			ranges.append((start, farthest))
			ranges.append((farthest, end))
		}
		return points.indices.filter { keep[$0] }.map { points[$0] }
	}
}

extension CGRect {
	/// The rectangle spanned by two opposite corners, in either order.
	init(corner: CGPoint, opposite: CGPoint) {
		self.init(x: min(corner.x, opposite.x), y: min(corner.y, opposite.y),
				  width: abs(opposite.x - corner.x), height: abs(opposite.y - corner.y))
	}
}
