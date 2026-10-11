//
//  DiagramGeometry.swift
//  Folio (fork of Open Scanner)
//
//  Shared drawing maths for diagrams: node outlines that match the Word and
//  PowerPoint preset of the same shape, where a connector leaves each
//  outline, arrowheads, and the conversion between a diagram's normalized
//  boxes and points. The document view and the drawing editor both draw
//  with these, so what you trace is what you export.
//

import SwiftUI

/// The outline of a diagram node, matching the OOXML preset of the same shape.
struct DiagramNodeOutline: Shape {
	let shape: Diagram.Shape

	func path(in rect: CGRect) -> Path {
		DiagramGeometry.outline(shape, in: rect)
	}
}

/// Outlines, connector clipping, arrowheads and box conversion for diagrams.
enum DiagramGeometry {
	/// Word's default `roundRect` corner: about a sixth of the shorter side.
	static let roundedCornerFraction: CGFloat = 0.1667
	/// How far an arrowhead reaches past the end of its line, in points.
	static let arrowheadLength: CGFloat = 8

	// MARK: Outlines

	static func outline(_ shape: Diagram.Shape, in rect: CGRect) -> Path {
		switch shape {
		case .rectangle:
			return Path(rect)
		case .roundedRectangle:
			return Path(roundedRect: rect, cornerRadius: min(rect.width, rect.height) * roundedCornerFraction, style: .continuous)
		case .ellipse:
			return Path(ellipseIn: rect)
		case .diamond, .parallelogram:
			var path = Path()
			path.addLines(vertices(shape, in: rect))
			path.closeSubpath()
			return path
		}
	}

	/// How much of a node's width each side of its label gives up, so the
	/// text stays inside slanted or curved sides.
	static func labelInsetFraction(_ shape: Diagram.Shape) -> CGFloat {
		switch shape {
		case .diamond: return 0.22
		case .parallelogram: return 0.18
		case .ellipse: return 0.12
		case .rectangle, .roundedRectangle: return 0.03
		}
	}

	/// Corner points, clockwise from the top: the polygon for a diamond or
	/// parallelogram, the bounding box for every other shape.
	static func vertices(_ shape: Diagram.Shape, in rect: CGRect) -> [CGPoint] {
		switch shape {
		case .diamond:
			return [CGPoint(x: rect.midX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.midY),
					CGPoint(x: rect.midX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.midY)]
		case .parallelogram:
			let slant = min(rect.width * 0.2, rect.height * 0.6)
			return [CGPoint(x: rect.minX + slant, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
					CGPoint(x: rect.maxX - slant, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
		case .rectangle, .roundedRectangle, .ellipse:
			return [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
					CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
		}
	}

	// MARK: Connectors

	/// The straight connector between two nodes: centre to centre, clipped to
	/// both outlines with a small gap, leaving room for the arrowheads its
	/// direction draws. Nil when the shapes overlap too much to show a line.
	static func connector(from a: Diagram.Node, to b: Diagram.Node, direction: Diagram.Direction,
						  in size: CGSize, gap: CGFloat = 2, headRoom: CGFloat = 6) -> (start: CGPoint, end: CGPoint)? {
		let ra = rect(a.box, in: size), rb = rect(b.box, in: size)
		let start = CGPoint(x: ra.midX, y: ra.midY)
		let delta = CGVector(dx: rb.midX - ra.midX, dy: rb.midY - ra.midY)
		let length = hypot(delta.dx, delta.dy)
		guard length > 1 else { return nil }
		let back = CGVector(dx: -delta.dx, dy: -delta.dy)
		let t0 = exitFraction(a.shape, in: ra, toward: delta) + (gap + (direction == .both ? headRoom : 0)) / length
		let t1 = 1 - exitFraction(b.shape, in: rb, toward: back) - (gap + (direction == .none ? 0 : headRoom)) / length
		guard t1 > t0 else { return nil }
		return (CGPoint(x: start.x + delta.dx * t0, y: start.y + delta.dy * t0),
				CGPoint(x: start.x + delta.dx * t1, y: start.y + delta.dy * t1))
	}

	/// How far along `delta` (in multiples of it) a ray from the centre of
	/// `rect` crosses the outline of `shape`.
	static func exitFraction(_ shape: Diagram.Shape, in rect: CGRect, toward delta: CGVector) -> CGFloat {
		guard rect.width > 0, rect.height > 0, delta.dx != 0 || delta.dy != 0 else { return 0 }
		let a = rect.width / 2, b = rect.height / 2
		switch shape {
		case .ellipse:
			let scaled = (delta.dx / a) * (delta.dx / a) + (delta.dy / b) * (delta.dy / b)
			return 1 / scaled.squareRoot()
		case .diamond, .parallelogram:
			return polygonExit(vertices(shape, in: rect), from: CGPoint(x: rect.midX, y: rect.midY), along: delta)
		case .rectangle, .roundedRectangle:
			let tx = delta.dx == 0 ? CGFloat.infinity : a / abs(delta.dx)
			let ty = delta.dy == 0 ? CGFloat.infinity : b / abs(delta.dy)
			return min(tx, ty)
		}
	}

	/// The nearest crossing of the ray `centre + t·delta` (t > 0) with a closed polygon.
	private static func polygonExit(_ points: [CGPoint], from centre: CGPoint, along d: CGVector) -> CGFloat {
		guard points.count >= 3 else { return 0 }
		var best = CGFloat.infinity
		for index in points.indices {
			let p = points[index], q = points[(index + 1) % points.count]
			let e = CGVector(dx: q.x - p.x, dy: q.y - p.y)
			let denominator = d.dx * e.dy - d.dy * e.dx
			guard abs(denominator) > 1e-9 else { continue }
			let w = CGVector(dx: p.x - centre.x, dy: p.y - centre.y)
			let t = (w.dx * e.dy - w.dy * e.dx) / denominator
			let u = (w.dx * d.dy - w.dy * d.dx) / denominator
			if t > 0, u >= -1e-6, u <= 1 + 1e-6 { best = min(best, t) }
		}
		return best.isFinite ? best : 0
	}

	/// A filled arrowhead whose point sits `length` past `tip`, along the line from `tail`.
	static func arrowhead(at tip: CGPoint, from tail: CGPoint, length: CGFloat = arrowheadLength) -> Path {
		let angle = atan2(tip.y - tail.y, tip.x - tail.x)
		let spread: CGFloat = .pi / 7
		let point = CGPoint(x: tip.x + cos(angle) * length, y: tip.y + sin(angle) * length)
		var path = Path()
		path.move(to: point)
		path.addLine(to: CGPoint(x: point.x - cos(angle - spread) * length * 1.2, y: point.y - sin(angle - spread) * length * 1.2))
		path.addLine(to: CGPoint(x: point.x - cos(angle + spread) * length * 1.2, y: point.y - sin(angle + spread) * length * 1.2))
		path.closeSubpath()
		return path
	}

	// MARK: Boxes and points

	/// A normalized box in points on a canvas of `size`.
	static func rect(_ box: NormalizedBox, in size: CGSize) -> CGRect {
		CGRect(x: box.x * size.width, y: box.y * size.height, width: box.width * size.width, height: box.height * size.height)
	}

	/// A rectangle in points as a box normalized to a canvas of `size`.
	static func box(_ rect: CGRect, in size: CGSize) -> NormalizedBox {
		guard size.width > 0, size.height > 0 else { return NormalizedBox(x: 0, y: 0, width: 0, height: 0) }
		return NormalizedBox(x: rect.minX / size.width, y: rect.minY / size.height,
							 width: rect.width / size.width, height: rect.height / size.height)
	}

	/// Distance from `point` to the segment `a`–`b`.
	static func distance(from point: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
		let dx = b.x - a.x, dy = b.y - a.y
		let lengthSquared = dx * dx + dy * dy
		guard lengthSquared > 0 else { return hypot(point.x - a.x, point.y - a.y) }
		let t = max(0, min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared))
		return hypot(point.x - (a.x + t * dx), point.y - (a.y + t * dy))
	}
}
