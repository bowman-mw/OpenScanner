//
//  PDFMarkEditing.swift
//  Rescriva (fork of Open Scanner)
//
//  Changing marks after they're made: picking one with the pointer, moving it, resizing a box or
//  a line, recoloring it, deleting it. Also any color beyond the palette, and who marks up on an
//  iPad: once Apple Pencil is in use, the pencil marks up and fingers scroll.
//

import Foundation
import PDFKit
import SwiftUI
import UIKit

// MARK: - Colors

/// A mark's color: one of the palette's, or any color the reader picks.
enum PDFMarkupColor: Hashable {
	case swatch(Int)
	/// 0xRRGGBB.
	case custom(UInt32)
}

extension UIColor {
	/// A color from 0xRRGGBB.
	convenience init(markRGB rgb: UInt32) {
		self.init(red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255, blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
	}

	/// The color as 0xRRGGBB in sRGB, ignoring alpha.
	var markRGB: UInt32 {
		var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
		guard getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return 0 }
		let channel = { (value: CGFloat) in UInt32((min(max(value, 0), 1) * 255).rounded()) }
		return channel(red) << 16 | channel(green) << 8 | channel(blue)
	}
}

// MARK: - Snapshots

/// What can change about a mark once it's made, kept so the change can be undone.
struct PDFMarkSnapshot {
	var bounds: CGRect
	var color: UIColor
	var fontColor: UIColor?
	var font: UIFont?
	var lineWidth: CGFloat?
	/// A line's ends, from the annotation's origin.
	var startPoint: CGPoint?
	var endPoint: CGPoint?
	/// An ink mark's strokes, from the annotation's origin (copies).
	var paths: [UIBezierPath]?

	init(of annotation: PDFAnnotation) {
		bounds = annotation.bounds
		color = annotation.color
		fontColor = annotation.type == "FreeText" ? annotation.fontColor : nil
		font = annotation.type == "FreeText" ? annotation.font : nil
		lineWidth = annotation.border?.lineWidth
		startPoint = annotation.type == "Line" ? annotation.startPoint : nil
		endPoint = annotation.type == "Line" ? annotation.endPoint : nil
		paths = annotation.type == "Ink" ? annotation.paths?.compactMap { $0.copy() as? UIBezierPath } : nil
	}

	func apply(to annotation: PDFAnnotation) {
		annotation.bounds = bounds
		annotation.color = color
		if let fontColor { annotation.fontColor = fontColor }
		if let font { annotation.font = font }
		if let lineWidth {
			let border = annotation.border ?? PDFBorder()
			border.lineWidth = lineWidth
			annotation.border = border
		}
		if let startPoint { annotation.startPoint = startPoint }
		if let endPoint { annotation.endPoint = endPoint }
		if let paths {
			for path in annotation.paths ?? [] { annotation.remove(path) }
			for path in paths { annotation.add(path) }
		}
		annotation.modificationDate = Date()
	}
}

/// A page's media and crop boxes, which a note margin widens.
struct PDFPageBoxes: Equatable {
	var media: CGRect
	var crop: CGRect

	init(media: CGRect, crop: CGRect) {
		self.media = media
		self.crop = crop
	}

	init(of page: PDFPage) {
		media = page.bounds(for: .mediaBox)
		crop = page.bounds(for: .cropBox)
	}

	func apply(to page: PDFPage) {
		page.setBounds(media, for: .mediaBox)
		page.setBounds(crop, for: .cropBox)
	}
}

// MARK: - Selection

/// The mark the pointer has picked.
struct PDFMarkSelection: Equatable {
	let annotation: PDFAnnotation
	let page: PDFPage

	static func == (lhs: PDFMarkSelection, rhs: PDFMarkSelection) -> Bool {
		lhs.annotation === rhs.annotation && lhs.page === rhs.page
	}

	/// The tool group whose colors and sizes fit this mark.
	var styleGroup: PDFMarkupStyleGroup? { PDFMarkupFactory.styleGroup(of: annotation) }

	/// Notes and text boxes have text to edit.
	var hasText: Bool { annotation.type == "Text" || annotation.type == "FreeText" }
}

/// What dragging on a selected mark does.
enum PDFMarkHandle: Equatable {
	case move
	/// A box's or circle's corner opposite its origin, as the page shows it.
	case corner
	case lineStart
	case lineEnd
}

// MARK: - Session

extension PDFEditSession {
	/// The topmost mark the pointer can pick at `point` (page space).
	func mark(at point: CGPoint, on page: PDFPage) -> PDFAnnotation? {
		page.annotations.last { PDFMarkupFactory.isSelectable($0) && PDFMarkupFactory.hitTest($0, point) }
	}

	func select(_ annotation: PDFAnnotation?, on page: PDFPage?) {
		guard let annotation, let page, PDFMarkupFactory.isSelectable(annotation) else {
			selection = nil
			return
		}
		selection = PDFMarkSelection(annotation: annotation, page: page)
	}

	/// Moves the selected mark by `delta` (page space), keeping it on the page. One undo step.
	func moveSelection(by delta: CGVector) {
		guard let selection, PDFMarkupFactory.isMovable(selection.annotation) else { return }
		let old = PDFMarkSnapshot(of: selection.annotation)
		var new = old
		new.bounds = PDFMarkupFactory.moved(old.bounds, by: delta, within: selection.page.bounds(for: .cropBox))
		perform(.reshape(selection.annotation, old: old, new: new))
	}

	/// Records a change the viewer already made live (a drag), so it can be undone.
	func recordReshape(_ annotation: PDFAnnotation, from old: PDFMarkSnapshot) {
		let new = PDFMarkSnapshot(of: annotation)
		guard new.bounds != old.bounds || new.startPoint != old.startPoint || new.endPoint != old.endPoint else { return }
		recordApplied(.reshape(annotation, old: old, new: new))
	}

	func deleteSelection() {
		guard let selection else { return }
		self.selection = nil
		perform(.removeAnnotations([(selection.annotation, selection.page)]))
	}

	/// Gives the selected mark `color`, keeping a highlighter stroke see-through. One undo step.
	func recolorSelection(_ color: UIColor) {
		guard let selection else { return }
		let annotation = selection.annotation
		let old = PDFMarkSnapshot(of: annotation)
		var new = old
		if annotation.type == "FreeText" {
			new.fontColor = color
		} else {
			new.color = color.withAlphaComponent(old.color.cgColor.alpha)
		}
		performReshape(annotation, old: old, new: new, coalescing: true)
	}

	/// Gives the selected mark a stroke width, or a text box a font size. One undo step.
	func resizeSelectionStroke(_ size: CGFloat) {
		guard let selection else { return }
		let annotation = selection.annotation
		let old = PDFMarkSnapshot(of: annotation)
		var new = old
		if annotation.type == "FreeText", let font = old.font {
			new.font = font.withSize(size)
			new.bounds = PDFMarkupFactory.textBoxBounds(annotation.contents ?? "", font: font.withSize(size), topLeft: CGPoint(x: old.bounds.minX, y: old.bounds.maxY),
														pageBounds: selection.page.bounds(for: .cropBox))
		} else if let width = old.lineWidth {
			new.lineWidth = size
			PDFMarkupFactory.repad(&new, from: width, to: size)
		} else {
			return
		}
		performReshape(annotation, old: old, new: new, coalescing: true)
	}

	/// The selection's color and size, matched to the palette and the size notches.
	var selectionStyle: PDFMarkupStyle? {
		guard let selection, let group = selection.styleGroup else { return nil }
		let annotation = selection.annotation
		let color = annotation.type == "FreeText" ? (annotation.fontColor ?? .black) : annotation.color
		let size = annotation.type == "FreeText" ? (annotation.font?.pointSize ?? group.defaultSize) : (annotation.border?.lineWidth ?? group.defaultSize)
		return PDFMarkupStyle(color: group.markupColor(for: color), size: group.nearestSize(size))
	}

	/// Drops the selection if its mark is no longer on a page (undone, erased).
	func validateSelection() {
		guard let selection else { return }
		if selection.annotation.page !== selection.page { self.selection = nil }
	}
}

// MARK: - Apple Pencil

/// Who marks up. On an iPad with Apple Pencil, only the pencil does and fingers scroll and zoom;
/// everywhere else one finger marks up and two scroll.
enum PDFMarkupInput {
	/// The reader's own choice, when they've made one (UserDefaults; a stored Bool).
	static let pencilOnlyKey = "markupPencilOnly"
	/// Set the first time Apple Pencil touches a page in markup.
	static let pencilSeenKey = "markupApplePencilSeen"

	/// Pencil-only on an iPad when the reader chose it, or, if they haven't chosen, once Apple
	/// Pencil has been used or the system's "Only Draw with Apple Pencil" is on.
	static func pencilOnly(idiom: UIUserInterfaceIdiom, choice: Bool?, pencilSeen: Bool, systemPrefersPencil: Bool) -> Bool {
		guard idiom == .pad else { return false }
		if let choice { return choice }
		return pencilSeen || systemPrefersPencil
	}

	/// The setting as it stands on this device.
	@MainActor
	static var current: Bool {
		let defaults = UserDefaults.standard
		return pencilOnly(idiom: UIDevice.current.userInterfaceIdiom, choice: defaults.object(forKey: pencilOnlyKey) as? Bool,
						  pencilSeen: defaults.bool(forKey: pencilSeenKey), systemPrefersPencil: UIPencilInteraction.prefersPencilOnlyDrawing)
	}

	/// Only an iPad has Apple Pencil to choose.
	@MainActor
	static var canChoose: Bool { UIDevice.current.userInterfaceIdiom == .pad }
}

extension PDFEditSession {
	/// The reader turned pencil-only on or off; remembered for every PDF.
	func setPencilOnly(_ on: Bool) {
		UserDefaults.standard.set(on, forKey: PDFMarkupInput.pencilOnlyKey)
		pencilOnly = on
	}

	/// Apple Pencil touched a page: unless the reader chose otherwise, the pencil marks up from now on.
	func pencilTouched() {
		let defaults = UserDefaults.standard
		guard !defaults.bool(forKey: PDFMarkupInput.pencilSeenKey) else { return }
		defaults.set(true, forKey: PDFMarkupInput.pencilSeenKey)
		pencilOnly = PDFMarkupInput.current
	}

	/// Apple Pencil's double tap: the eraser and back, or the tool before, as the system setting says.
	func pencilDoubleTapped(switchesToEraser: Bool) {
		if switchesToEraser {
			tool = tool == .eraser ? previousTool : .eraser
		} else {
			tool = previousTool
		}
	}
}

// MARK: - Marked pages

extension PDFEditSession {
	/// The pages with marks on them, in order (observed through `revision`).
	var markedPageIndexes: [Int] {
		_ = revision
		return (0..<document.pageCount).filter { index in
			document.page(at: index)?.annotations.contains(where: PDFMarkupFactory.isMark) ?? false
		}
	}
}

// MARK: - Factory

extension PDFMarkupFactory {
	/// Marks someone made: Rescriva's, and comments from other apps (stamps, squiggles, Acrobat's
	/// notes). Not links, form fields, the pop-ups notes open in, or the note margin.
	static func isMark(_ annotation: PDFAnnotation) -> Bool {
		guard let type = annotation.type, !PDFNoteMargin.isPanel(annotation) else { return false }
		return !["Link", "Widget", "Popup"].contains(type)
	}

	/// Kinds the pointer can pick: Rescriva's marks, never form fields, links or the note margin.
	static func isSelectable(_ annotation: PDFAnnotation) -> Bool {
		isErasable(annotation)
	}

	/// Marks that can move. Highlights, underlines and strike-outs belong to their text.
	static func isMovable(_ annotation: PDFAnnotation) -> Bool {
		guard isSelectable(annotation), let type = annotation.type else { return false }
		return !["Highlight", "Underline", "StrikeOut"].contains(type)
	}

	/// The handles a selected mark offers besides moving.
	static func handles(of annotation: PDFAnnotation) -> [PDFMarkHandle] {
		switch annotation.type {
		case "Square", "Circle": return [.corner]
		case "Line": return [.lineStart, .lineEnd]
		default: return []
		}
	}

	/// The tool group a mark's colors and sizes come from.
	static func styleGroup(of annotation: PDFAnnotation) -> PDFMarkupStyleGroup? {
		switch annotation.type {
		case "Ink": return annotation.color.cgColor.alpha < 0.99 ? .highlighter : .pen
		case "Highlight": return .highlighter
		case "Underline", "StrikeOut": return .textLine
		case "Square", "Circle", "Line": return .shape
		case "FreeText", "Text": return .text
		default: return nil
		}
	}

	/// `bounds` moved by `delta`, kept inside `page` (a mark bigger than the page keeps its top-left on it).
	static func moved(_ bounds: CGRect, by delta: CGVector, within page: CGRect) -> CGRect {
		var moved = bounds.offsetBy(dx: delta.dx, dy: delta.dy)
		moved.origin.x = min(max(moved.minX, page.minX), max(page.maxX - moved.width, page.minX))
		moved.origin.y = min(max(moved.minY, page.minY), max(page.maxY - moved.height, page.minY))
		return moved
	}

	/// A line from `start` to `end` (page space): its bounds, padded so an arrowhead fits, and its
	/// ends from the bounds' origin.
	static func lineGeometry(from start: CGPoint, to end: CGPoint, width: CGFloat) -> (bounds: CGRect, start: CGPoint, end: CGPoint) {
		let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
		let bounds = rect.insetBy(dx: -width * 4, dy: -width * 4)
		return (bounds, CGPoint(x: start.x - bounds.minX, y: start.y - bounds.minY), CGPoint(x: end.x - bounds.minX, y: end.y - bounds.minY))
	}

	/// Re-pads a mark's bounds for a new stroke width the way it was made (lines by four widths,
	/// ink by one, boxes and circles by half), keeping what it draws where it was.
	static func repad(_ snapshot: inout PDFMarkSnapshot, from old: CGFloat, to new: CGFloat) {
		if let start = snapshot.startPoint, let end = snapshot.endPoint {
			let origin = snapshot.bounds.origin
			let line = lineGeometry(from: CGPoint(x: origin.x + start.x, y: origin.y + start.y),
									to: CGPoint(x: origin.x + end.x, y: origin.y + end.y), width: new)
			snapshot.bounds = line.bounds
			snapshot.startPoint = line.start
			snapshot.endPoint = line.end
		} else if let paths = snapshot.paths {
			let grow = new - old
			snapshot.bounds = snapshot.bounds.insetBy(dx: -grow, dy: -grow)
			snapshot.paths = paths.compactMap { path in
				let moved = path.copy() as? UIBezierPath
				moved?.apply(CGAffineTransform(translationX: grow, y: grow))
				return moved
			}
		} else {
			let grow = (new - old) / 2
			snapshot.bounds = snapshot.bounds.insetBy(dx: -grow, dy: -grow)
		}
	}

	/// A text box's frame for `text` in `font`, its top-left at `topLeft`, kept inside `pageBounds`.
	static func textBoxBounds(_ text: String, font: UIFont, topLeft: CGPoint, pageBounds: CGRect) -> CGRect {
		let maxWidth = max(pageBounds.maxX - topLeft.x - 8, 80)
		let measured = (text as NSString).boundingRect(with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
													   options: [.usesLineFragmentOrigin], attributes: [.font: font], context: nil)
		let size = CGSize(width: ceil(measured.width) + 12, height: ceil(measured.height) + 8)
		var origin = CGPoint(x: topLeft.x, y: topLeft.y - size.height)
		origin.x = min(max(origin.x, pageBounds.minX), pageBounds.maxX - size.width)
		origin.y = min(max(origin.y, pageBounds.minY), pageBounds.maxY - size.height)
		return CGRect(origin: origin, size: size)
	}

	/// True when `point` (page space) is within `slack` of a line, or of an ink stroke.
	static func strokeHit(_ annotation: PDFAnnotation, _ point: CGPoint, slack: CGFloat) -> Bool? {
		let width = annotation.border?.lineWidth ?? 1
		let local = CGPoint(x: point.x - annotation.bounds.minX, y: point.y - annotation.bounds.minY)
		switch annotation.type {
		case "Line":
			return distance(from: local, toSegment: annotation.startPoint, annotation.endPoint) <= width / 2 + slack
		case "Ink":
			guard let paths = annotation.paths, !paths.isEmpty else { return nil }
			return paths.contains { path in
				path.cgPath.copy(strokingWithWidth: width + slack * 2, lineCap: .round, lineJoin: .round, miterLimit: 1).contains(local)
			}
		default:
			return nil
		}
	}

	static func distance(from point: CGPoint, toSegment start: CGPoint, _ end: CGPoint) -> CGFloat {
		let dx = end.x - start.x, dy = end.y - start.y
		let lengthSquared = dx * dx + dy * dy
		guard lengthSquared > 0 else { return hypot(point.x - start.x, point.y - start.y) }
		let t = min(max(((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared, 0), 1)
		return hypot(point.x - (start.x + t * dx), point.y - (start.y + t * dy))
	}
}
