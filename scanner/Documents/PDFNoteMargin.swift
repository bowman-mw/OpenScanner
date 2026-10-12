//
//  PDFNoteMargin.swift
//  Folio (fork of Open Scanner)
//
//  A wide margin beside every page to write notes in, apart from the PDF's own content. The page
//  grows on the left or right (its media and crop boxes widen) and the new strip gets a faint
//  tint, a Square annotation whose author (/T) is "Folio note margin", so it reads as a writing
//  space and Folio can find it again after a save (PDFKit keeps /T; it drops /NM). Both are
//  ordinary PDF, so the margin and what's written in it travel with the file to Acrobat,
//  Preview and printers.
//

import Foundation
import PDFKit
import UIKit

enum PDFNoteMargin: String, CaseIterable, Identifiable {
	case left, right

	var id: String { rawValue }

	/// The panel annotation's author (/T), which marks it as Folio's margin.
	static let panelName = "Folio note margin"
	/// How wide the margin is, as a share of the page's width as shown.
	static let widthFraction: CGFloat = 0.5
	/// The panel's faint tint: paper, a shade warmer than the page.
	static let tint = UIColor(red: 0.98, green: 0.965, blue: 0.93, alpha: 1)

	/// A page box's edges, in page space (y up).
	enum Edge: Equatable { case minX, maxX, minY, maxY }

	/// The box edge that shows on this side once the page's rotation is applied. PDF rotation turns
	/// the page clockwise: at 90° the bottom edge shows on the left, at 180° the right edge does.
	func edge(rotation: Int) -> Edge {
		let turns = ((rotation / 90) % 4 + 4) % 4
		let leftEdges: [Edge] = [.minX, .minY, .maxX, .maxY]
		let rightEdges: [Edge] = [.maxX, .maxY, .minX, .minY]
		return self == .left ? leftEdges[turns] : rightEdges[turns]
	}

	/// `box` widened on this side, and the strip that was added (page space).
	func expand(_ box: CGRect, rotation: Int, fraction: CGFloat = PDFNoteMargin.widthFraction) -> (box: CGRect, strip: CGRect) {
		let edge = edge(rotation: rotation)
		let along = edge == .minX || edge == .maxX
		let width = (along ? box.width : box.height) * fraction
		let strip: CGRect
		switch edge {
		case .minX: strip = CGRect(x: box.minX - width, y: box.minY, width: width, height: box.height)
		case .maxX: strip = CGRect(x: box.maxX, y: box.minY, width: width, height: box.height)
		case .minY: strip = CGRect(x: box.minX, y: box.minY - width, width: box.width, height: width)
		case .maxY: strip = CGRect(x: box.minX, y: box.maxY, width: box.width, height: width)
		}
		return (box.union(strip), strip)
	}

	/// `box` without `strip`, when the strip runs the full length of one of its edges; else nil.
	static func shrink(_ box: CGRect, removing strip: CGRect) -> CGRect? {
		guard let edge = edge(of: strip, in: box) else { return nil }
		var remaining = box
		switch edge {
		case .minX: remaining.origin.x = strip.maxX; remaining.size.width = box.maxX - strip.maxX
		case .maxX: remaining.size.width = strip.minX - box.minX
		case .minY: remaining.origin.y = strip.maxY; remaining.size.height = box.maxY - strip.maxY
		case .maxY: remaining.size.height = strip.minY - box.minY
		}
		return remaining.width > 1 && remaining.height > 1 ? remaining : nil
	}

	/// Which edge of `box` the strip lies along, if it spans that edge.
	static func edge(of strip: CGRect, in box: CGRect) -> Edge? {
		let near = { (a: CGFloat, b: CGFloat) in abs(a - b) < 0.5 }
		if near(strip.minY, box.minY) && near(strip.maxY, box.maxY) {
			if near(strip.minX, box.minX) { return .minX }
			if near(strip.maxX, box.maxX) { return .maxX }
		}
		if near(strip.minX, box.minX) && near(strip.maxX, box.maxX) {
			if near(strip.minY, box.minY) { return .minY }
			if near(strip.maxY, box.maxY) { return .maxY }
		}
		return nil
	}

	/// The side a strip shows on, given the page's rotation.
	static func side(of strip: CGRect, in box: CGRect, rotation: Int) -> PDFNoteMargin? {
		guard let edge = edge(of: strip, in: box) else { return nil }
		return allCases.first { $0.edge(rotation: rotation) == edge }
	}

	static func isPanel(_ annotation: PDFAnnotation) -> Bool {
		annotation.type == "Square" && annotation.userName == panelName
	}

	/// The tinted panel that fills a margin strip.
	static func panel(filling strip: CGRect) -> PDFAnnotation {
		let panel = PDFAnnotation(bounds: strip, forType: .square, withProperties: nil)
		panel.userName = panelName
		panel.color = tint
		panel.interiorColor = tint
		let border = PDFBorder()
		border.lineWidth = 0
		panel.border = border
		panel.contents = nil
		return panel
	}
}

extension PDFEditSession {
	/// The note margin's side on `page`, from its panel.
	func noteMargin(on page: PDFPage) -> PDFNoteMargin? {
		let crop = page.bounds(for: .cropBox)
		return page.annotations.lazy.filter(PDFNoteMargin.isPanel)
			.compactMap { PDFNoteMargin.side(of: $0.bounds, in: crop, rotation: page.rotation) }.first
	}

	/// The margin on the page being read (observed through `revision`).
	var currentNoteMargin: PDFNoteMargin? {
		_ = revision
		return document.page(at: currentPageIndex).flatMap(noteMargin(on:))
	}

	/// How many marks sit wholly inside note margins, which removing the margins would delete.
	var marksInNoteMargins: Int {
		_ = revision
		return (0..<document.pageCount).compactMap(document.page(at:)).reduce(0) { count, page in
			count + Self.marginContents(on: page).marks.count
		}
	}

	/// Gives every page a note margin on `side`, or takes them away (nil), in one undo step. Taking a
	/// margin away deletes the marks written wholly inside it; pages already as asked are left alone.
	func setNoteMargin(_ side: PDFNoteMargin?) {
		var removed: [(annotation: PDFAnnotation, page: PDFPage)] = []
		var boxes: [(page: PDFPage, old: PDFPageBoxes, new: PDFPageBoxes)] = []
		var added: [(annotation: PDFAnnotation, page: PDFPage)] = []
		for index in 0..<document.pageCount {
			guard let page = document.page(at: index), noteMargin(on: page) != side || Self.marginContents(on: page).panels.count > 1 else { continue }
			let old = PDFPageBoxes(of: page)
			let (panels, marks) = Self.marginContents(on: page)
			var new = old
			for panel in panels {
				new = Self.boxes(new, without: panel.bounds)
			}
			removed += (panels + marks).map { (annotation: $0, page: page) }
			if let side {
				let (crop, strip) = side.expand(new.crop, rotation: page.rotation)
				new = PDFPageBoxes(media: new.media.union(crop), crop: crop)
				added.append((PDFNoteMargin.panel(filling: strip), page))
			}
			if new != old { boxes.append((page, old, new)) }
		}
		var edits: [PDFEdit] = []
		if !removed.isEmpty { edits.append(.removeAnnotations(removed)) }
		if !boxes.isEmpty { edits.append(.setPageBoxes(boxes)) }
		if !added.isEmpty { edits.append(.addAnnotations(added)) }
		guard !edits.isEmpty else { return }
		selection = nil
		perform(.batch(edits))
	}

	/// The page's margin panels, and the marks lying wholly inside them.
	static func marginContents(on page: PDFPage) -> (panels: [PDFAnnotation], marks: [PDFAnnotation]) {
		let panels = page.annotations.filter(PDFNoteMargin.isPanel)
		let marks = page.annotations.filter { mark in
			PDFMarkupFactory.isErasable(mark) && panels.contains { $0.bounds.insetBy(dx: -0.5, dy: -0.5).contains(mark.bounds) }
		}
		return (panels, marks)
	}

	/// `boxes` with a margin strip taken off (the media box only where it shares the crop box's edge).
	static func boxes(_ boxes: PDFPageBoxes, without strip: CGRect) -> PDFPageBoxes {
		guard let crop = PDFNoteMargin.shrink(boxes.crop, removing: strip) else { return boxes }
		let media = PDFNoteMargin.shrink(boxes.media, removing: strip) ?? boxes.media
		return PDFPageBoxes(media: media, crop: crop)
	}
}
