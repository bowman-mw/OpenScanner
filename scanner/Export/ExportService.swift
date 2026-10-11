//
//  ExportService.swift
//  Folio (fork of Open Scanner)
//
//  Writes a scan to a file in the chosen format, ready for the share sheet.
//  Word, PowerPoint and plain text come from the rebuilt FolioDocument; the
//  searchable PDF comes from the page images and their recognized text.
//

import Foundation

/// The four export formats. Stored token.
enum ExportFormat: String, CaseIterable, Identifiable {
	case docx, pptx, pdf, txt

	var id: String { rawValue }

	var fileExtension: String { ".\(rawValue)" }

	var label: LocalizedStringResource {
		switch self {
		case .docx: return "Word document"
		case .pptx: return "PowerPoint"
		case .pdf: return "Searchable PDF"
		case .txt: return "Plain text"
		}
	}

	var detail: LocalizedStringResource {
		switch self {
		case .docx: return "Editable text, tables, equation and diagram"
		case .pptx: return "One slide per page, with theme colors"
		case .pdf: return "Looks like the scan, text is selectable"
		case .txt: return "Just the words"
		}
	}

	/// Where notes go in this format.
	var notesLabel: LocalizedStringResource {
		switch self {
		case .docx: return "Notes as Word comments"
		case .pptx: return "Notes as speaker notes"
		case .pdf: return "Notes as PDF annotations"
		case .txt: return "Include notes"
		}
	}

	/// Word and PowerPoint need a rebuild-capable iPhone.
	var needsRebuild: Bool { self == .docx || self == .pptx }
}

/// Builds export files.
@MainActor
enum ExportService {
	/// Writes `scan` as `format` into a fresh temporary folder and returns the file URL.
	static func makeFile(for scan: Scan, format: ExportFormat, includeNotes: Bool) async throws -> URL {
		let data: Data
		var options = RenderOptions()
		options.includeNotes = includeNotes
		switch format {
		case .pdf:
			data = SearchablePDF.render(SearchablePDF.pages(for: scan, includeNotes: includeNotes), title: scan.displayTitle)
		case .txt:
			if let document = scan.rebuiltDocument {
				data = Data(PlainTextRenderer.render(document, options: options).utf8)
			} else {
				let text = scan.capturesArray
					.map { $0.recognizedItemsArray.compactMap(\.transcript).joined(separator: "\n") }
					.joined(separator: "\n\n")
				data = Data(text.utf8)
			}
		case .docx, .pptx:
			let document = await currentDocument(for: scan)
			data = format == .docx
				? try DOCXRenderer.render(document, options: options)
				: try PPTXRenderer.render(document, options: options)
		}
		let folder = FileManager.default.temporaryDirectory
			.appendingPathComponent("Exports", isDirectory: true)
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		let url = folder.appendingPathComponent(fileName(for: scan, format: format))
		try data.write(to: url, options: .atomic)
		return url
	}

	/// "Lab notes — week 6.docx", made safe for file systems.
	static func fileName(for scan: Scan, format: ExportFormat) -> String {
		let base = scan.displayTitle.sanitized().whitespaceCondensed().trimmingCharacters(in: .whitespaces)
		return (base.isEmpty ? "Scan" : base) + format.fileExtension
	}

	/// The scan's rebuilt document, rebuilding first if it has none or its
	/// pages changed.
	private static func currentDocument(for scan: Scan) async -> FolioDocument {
		await Rebuilder(tier: DeviceTier.current).document(for: scan) { _ in }
	}
}
