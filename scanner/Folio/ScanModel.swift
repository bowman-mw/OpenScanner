//
//  ScanModel.swift
//  Folio (fork of Open Scanner)
//
//  Folio's view of Open Scanner's Core Data entities: the output a scan is
//  headed for, its look, where it came from and its rebuilt document, plus
//  helpers to create scans from captured or imported images.
//
//  App-target only (the widget shares DataExtensions.swift, not this file).
//

import Foundation
import CoreData
import SwiftUI
import UIKit

/// What a scan becomes. Stored token on `Scan.outputKind`.
enum OutputKind: String, CaseIterable, Identifiable {
	case pdf, docx, pptx

	var id: String { rawValue }

	/// Library chip label.
	var chipLabel: String {
		switch self {
		case .pdf: return "PDF"
		case .docx: return String(localized: "Word")
		case .pptx: return String(localized: "Slides")
		}
	}

	var chipColor: Color {
		switch self {
		case .pdf: return Color.bark.opacity(0.08)
		case .docx: return .lichen
		case .pptx: return Color.goldenrod.opacity(0.25)
		}
	}

	/// Placeholder ink for thumbnails without an image.
	var ink: Color {
		switch self {
		case .pdf: return .bark
		case .docx: return .moss
		case .pptx: return .goldenrod
		}
	}
}

/// The page filter chosen under "Look". Stored token on `Scan.look`.
enum LookFilter: String, CaseIterable, Identifiable {
	case color, gray, blackAndWhite = "bw", original

	var id: String { rawValue }

	var label: LocalizedStringKey {
		switch self {
		case .color: return "Color"
		case .gray: return "Gray"
		case .blackAndWhite: return "B&W"
		case .original: return "Original"
		}
	}
}

extension Scan {
	/// The chosen output; new scans default from their page shape.
	var output: OutputKind {
		get { OutputKind(rawValue: outputKind ?? "") ?? .pdf }
		set { outputKind = newValue.rawValue }
	}

	var lookFilter: LookFilter {
		get { LookFilter(rawValue: look ?? "") ?? .color }
		set { look = newValue.rawValue }
	}

	var pageSource: PageSource? {
		get { PageSource(rawValue: source ?? "") }
		set { source = newValue?.rawValue }
	}

	var displayTitle: String {
		guard let title, !title.trimmingCharacters(in: .whitespaces).isEmpty else {
			return String(localized: "Untitled")
		}
		return title
	}

	/// The rebuilt document, decoded from `rebuiltData`.
	var rebuiltDocument: FolioDocument? {
		get {
			guard let rebuiltData else { return nil }
			return try? JSONDecoder.folio.decode(FolioDocument.self, from: rebuiltData)
		}
		set {
			rebuiltData = newValue.flatMap { try? JSONEncoder.folio.encode($0) }
		}
	}

	/// True once the scan has been rebuilt into Word or Slides.
	var isRebuilt: Bool { rebuiltData != nil && output != .pdf }

	/// True when most pages are landscape, which suggests slides.
	var looksLikeSlides: Bool {
		let ratios = capturesArray.compactMap { $0.thumbnail?.aspectRatio }
		guard !ratios.isEmpty else { return false }
		return ratios.filter { $0 > 1.15 }.count * 2 > ratios.count
	}

	/// "4 pages · 2 hours ago".
	var libraryMeta: String {
		let count = capturesArray.count
		let pages = count == 1 ? String(localized: "1 page") : String(localized: "\(count) pages")
		return "\(pages) · \(FolioDates.relative(timestamp ?? Date()))"
	}

	/// "3 pages · Today at 9:14 · Handwritten".
	var detailMeta: String {
		let count = capturesArray.count
		var parts = [count == 1 ? String(localized: "1 page") : String(localized: "\(count) pages"),
					 FolioDates.dayAndTime(timestamp ?? Date())]
		if let source = pageSource {
			parts.append(source.displayName)
		}
		return parts.joined(separator: " · ")
	}

	/// Creates a scan from page images (camera, Photos or a PDF) and starts
	/// recognizing their text. When `suggestsTitle`, the first line that reads
	/// like a title replaces `title` (unless the user renamed it meanwhile).
	@MainActor
	@discardableResult
	static func create(from images: [UIImage], title: String, source: PageSource?, in context: NSManagedObjectContext, output: OutputKind? = nil, suggestsTitle: Bool = true) -> Scan {
		let scan = Scan(context: context)
		scan.id = UUID()
		scan.timestamp = Date()
		scan.lastUpdate = Date()
		scan.title = title
		scan.order = Int32(nextOrder(in: context))
		scan.pageSource = source
		scan.append(images, placeholderTitle: suggestsTitle ? title : nil, in: context)
		// The design starts captures on Word (Slides for wide pages) where the
		// phone can rebuild; callers pass `.pdf` for imported PDFs.
		if let output {
			scan.output = output
		} else {
			scan.output = DeviceTier.current.canRebuild ? (scan.looksLikeSlides ? .pptx : .docx) : .pdf
		}
		context.saveQuietly()
		return scan
	}

	/// Adds pages to the end of the scan and recognizes their text.
	@MainActor
	func append(_ images: [UIImage], placeholderTitle: String? = nil, in context: NSManagedObjectContext) {
		let start = capturesArray.count
		var created: [(ScanCapture, UIImage)] = []
		for (offset, image) in images.enumerated() {
			// Per page: each page's full-size resize is autoreleased, and a
			// 54-page PDF piled them up to 1.7 GB before the loop ended.
			autoreleasepool {
				let capture = ScanCapture(context: context)
				capture.id = UUID()
				capture.timestamp = Date()
				capture.order = Int32(start + offset)
				capture.createImage(fullSizedImage: image)
				capture.createThumbnail(fullSizedImage: image)
				addToCaptures(capture)
				created.append((capture, image))
			}
		}
		lastUpdate = Date()
		context.saveQuietly()
		Task { await PageOCR.process(created, placeholderTitle: placeholderTitle) }
	}

	/// Renumbers pages after a move or delete.
	func renumberPages() {
		for (index, capture) in capturesArray.enumerated() {
			capture.order = Int32(index)
		}
		lastUpdate = Date()
	}

	private static func nextOrder(in context: NSManagedObjectContext) -> Int {
		let request = Scan.fetchRequest()
		request.sortDescriptors = [NSSortDescriptor(keyPath: \Scan.order, ascending: false)]
		request.fetchLimit = 1
		let top = (try? context.fetch(request))?.first
		return Int(top?.order ?? -1) + 1
	}
}

extension PageSource {
	var displayName: String {
		switch self {
		case .typed: return String(localized: "Typed")
		case .handwritten: return String(localized: "Handwritten")
		case .whiteboard: return String(localized: "Whiteboard")
		}
	}
}

extension JSONEncoder {
	/// Stable encoding for persisted documents (dates as exact reference-date seconds).
	static var folio: JSONEncoder {
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.sortedKeys]
		return encoder
	}
}

extension JSONDecoder {
	static var folio: JSONDecoder {
		JSONDecoder()
	}
}

/// Date phrases in the design's voice.
enum FolioDates {
	/// "2 hours ago", "Yesterday", "Tuesday", "Sep 28".
	static func relative(_ date: Date, now: Date = Date()) -> String {
		let calendar = Calendar.current
		if calendar.isDateInToday(date) {
			if now.timeIntervalSince(date) < 60 { return String(localized: "Just now") }
			let formatter = RelativeDateTimeFormatter()
			formatter.unitsStyle = .full
			return formatter.localizedString(for: date, relativeTo: now)
		}
		if calendar.isDateInYesterday(date) { return String(localized: "Yesterday") }
		if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day, days < 7 {
			return date.formatted(.dateTime.weekday(.wide))
		}
		return date.formatted(.dateTime.month(.abbreviated).day())
	}

	/// "Today at 9:14", "Sep 28 at 9:14".
	static func dayAndTime(_ date: Date) -> String {
		let calendar = Calendar.current
		let time = date.formatted(date: .omitted, time: .shortened)
		if calendar.isDateInToday(date) { return String(localized: "Today at \(time)") }
		if calendar.isDateInYesterday(date) { return String(localized: "Yesterday at \(time)") }
		return String(localized: "\(date.formatted(.dateTime.month(.abbreviated).day())) at \(time)")
	}

	/// "Scan, Oct 10" / "Whiteboard, Oct 10".
	static func defaultTitle(for kind: CaptureKind, on date: Date = Date()) -> String {
		let day = date.formatted(.dateTime.month(.abbreviated).day())
		switch kind {
		case .document: return String(localized: "Scan, \(day)")
		case .whiteboard: return String(localized: "Whiteboard, \(day)")
		}
	}
}
