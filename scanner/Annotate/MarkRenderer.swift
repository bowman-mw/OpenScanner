//
//  MarkRenderer.swift
//  Folio (fork of Open Scanner)
//
//  Draws page marks with Core Graphics, the same way everywhere they appear:
//  the annotation canvas, the preview, the zoomed page and the PDF export.
//  Highlights go down first with a multiply blend, so the words under them
//  stay dark; ink and shapes go on top.
//

import SwiftUI
import UIKit

enum MarkRenderer {
	/// Draws every mark over a page that fills `rect` (top-left origin), clipped to it: a mark a
	/// new crop or a split left partly or wholly off the page never shows on the paper around it
	/// (a PDF sheet's margin), as the preview's page and the canvas's bounds clip it too.
	static func draw(_ marks: [PageMark], in rect: CGRect, context: CGContext) {
		guard !marks.isEmpty else { return }
		context.saveGState()
		defer { context.restoreGState() }
		context.clip(to: rect)
		drawHighlights(marks, in: rect, context: context, blend: .multiply)
		drawInk(marks, in: rect, context: context)
	}

	/// The highlighter marks only.
	static func drawHighlights(_ marks: [PageMark], in rect: CGRect, context: CGContext, blend: CGBlendMode) {
		for mark in marks where mark.kind == .highlighter {
			draw(mark, in: rect, context: context, blend: blend)
		}
	}

	/// Everything but the highlighter marks.
	static func drawInk(_ marks: [PageMark], in rect: CGRect, context: CGContext) {
		for mark in marks where mark.kind != .highlighter {
			draw(mark, in: rect, context: context)
		}
	}

	/// Draws one mark. `alpha` lets the canvas show a highlight in progress
	/// translucently (it can't multiply against the page from its own layer).
	static func draw(_ mark: PageMark, in rect: CGRect, context: CGContext, blend: CGBlendMode = .normal, alpha: CGFloat = 1) {
		guard rect.width > 0, rect.height > 0, !mark.points.isEmpty else { return }
		let points = mark.points.map { CGPoint(x: rect.minX + $0.x * rect.width, y: rect.minY + $0.y * rect.height) }
		let lineWidth = max(CGFloat(mark.width) * rect.width, 0.5)
		let color = cgColor(mark.color)
		context.saveGState()
		defer { context.restoreGState() }
		context.setBlendMode(blend)
		context.setAlpha(alpha)
		context.setStrokeColor(color)
		context.setFillColor(color)
		context.setLineWidth(lineWidth)
		context.setLineCap(.round)
		context.setLineJoin(.round)
		if mark.kind.isFreehand, isDot(points, lineWidth: lineWidth), let center = points.first {
			// A tap leaves a round dot the width of the pen.
			context.fillEllipse(in: CGRect(x: center.x - lineWidth / 2, y: center.y - lineWidth / 2, width: lineWidth, height: lineWidth))
			return
		}
		context.addPath(path(for: mark.kind, points: points, lineWidth: lineWidth))
		context.strokePath()
		if mark.kind == .arrow, let head = arrowHead(points: points, lineWidth: lineWidth) {
			context.addPath(head)
			context.fillPath()
		}
	}

	/// The stroked outline of a mark whose points are already in `rect` space.
	static func path(for kind: PageMark.Kind, points: [CGPoint], lineWidth: CGFloat) -> CGPath {
		let path = CGMutablePath()
		guard let first = points.first, let last = points.last else { return path }
		switch kind {
		case .pen, .highlighter:
			addSmoothCurve(through: points, to: path)
		case .line:
			path.move(to: first)
			path.addLine(to: last)
		case .arrow:
			// Stop the shaft inside the head so its round cap doesn't poke through the tip.
			let length = hypot(last.x - first.x, last.y - first.y)
			let inset = min(arrowHeadLength(lineWidth: lineWidth, shaft: length) * 0.6, length)
			let scale = length > 0 ? (length - inset) / length : 0
			path.move(to: first)
			path.addLine(to: CGPoint(x: first.x + (last.x - first.x) * scale, y: first.y + (last.y - first.y) * scale))
		case .rectangle:
			path.addRect(CGRect(corner: first, opposite: last))
		case .ellipse:
			path.addEllipse(in: CGRect(corner: first, opposite: last))
		}
		return path
	}

	/// The filled triangle at an arrow's tip, or nil for a zero-length arrow.
	static func arrowHead(points: [CGPoint], lineWidth: CGFloat) -> CGPath? {
		guard let start = points.first, let tip = points.last else { return nil }
		let dx = tip.x - start.x
		let dy = tip.y - start.y
		let shaft = hypot(dx, dy)
		guard shaft > 0 else { return nil }
		let length = arrowHeadLength(lineWidth: lineWidth, shaft: shaft)
		let ux = dx / shaft
		let uy = dy / shaft
		let base = CGPoint(x: tip.x - ux * length, y: tip.y - uy * length)
		let half = length * 0.5
		let head = CGMutablePath()
		head.move(to: tip)
		head.addLine(to: CGPoint(x: base.x - uy * half, y: base.y + ux * half))
		head.addLine(to: CGPoint(x: base.x + uy * half, y: base.y - ux * half))
		head.closeSubpath()
		return head
	}

	/// Head length grows with the stroke but never outgrows a short arrow.
	private static func arrowHeadLength(lineWidth: CGFloat, shaft: CGFloat) -> CGFloat {
		min(max(lineWidth * 4.5, 9), shaft * 0.6)
	}

	/// A freehand mark that never really moved.
	private static func isDot(_ points: [CGPoint], lineWidth: CGFloat) -> Bool {
		guard let first = points.first else { return false }
		return points.allSatisfy { hypot($0.x - first.x, $0.y - first.y) < max(lineWidth * 0.25, 0.5) }
	}

	/// Quadratic curves through the midpoints, so strokes read as ink, not polylines.
	private static func addSmoothCurve(through points: [CGPoint], to path: CGMutablePath) {
		guard let first = points.first else { return }
		path.move(to: first)
		guard points.count > 2 else {
			path.addLine(to: points[points.count - 1])
			return
		}
		for index in 1..<(points.count - 1) {
			let control = points[index]
			let next = points[index + 1]
			path.addQuadCurve(to: CGPoint(x: (control.x + next.x) / 2, y: (control.y + next.y) / 2), control: control)
		}
		path.addLine(to: points[points.count - 1])
	}

	/// 0xRRGGBB as an sRGB color.
	static func cgColor(_ rgb: UInt32) -> CGColor {
		UIColor(red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
				blue: CGFloat(rgb & 0xFF) / 255, alpha: 1).cgColor
	}

	/// The page image with its marks drawn in, at the image's own resolution.
	static func flattened(_ image: UIImage, marks: [PageMark]) -> UIImage {
		guard !marks.isEmpty, image.size.width > 0, image.size.height > 0 else { return image }
		let format = UIGraphicsImageRendererFormat()
		format.scale = image.scale
		format.opaque = true
		return UIGraphicsImageRenderer(size: image.size, format: format).image { context in
			image.draw(at: .zero)
			draw(marks, in: CGRect(origin: .zero, size: image.size), context: context.cgContext)
		}
	}
}

/// A page's marks laid over its image in SwiftUI. Highlights sit in their
/// own layer, multiplied onto the page beneath; ink goes on top.
struct MarksOverlay: View {
	let marks: [PageMark]

	var body: some View {
		if !marks.isEmpty {
			ZStack {
				Canvas { context, size in
					context.withCGContext { cg in
						MarkRenderer.drawHighlights(marks, in: CGRect(origin: .zero, size: size), context: cg, blend: .normal)
					}
				}
				.blendMode(.multiply)
				Canvas { context, size in
					context.withCGContext { cg in
						MarkRenderer.drawInk(marks, in: CGRect(origin: .zero, size: size), context: cg)
					}
				}
			}
			.allowsHitTesting(false)
			.accessibilityHidden(true)
		}
	}
}
