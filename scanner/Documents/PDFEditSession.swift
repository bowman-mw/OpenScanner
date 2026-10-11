//
//  PDFEditSession.swift
//  Folio (fork of Open Scanner)
//
//  The open PDF: the PDFKit document, what the file says it is, the markup
//  tool and its colors, and undo/redo for every change Folio makes (marks and
//  page edits). Form fields are typed into PDFView itself and picked up when
//  saving. Marks are standard PDF annotations, so they stay editable in
//  Acrobat, Preview and other readers.
//

import Foundation
import Observation
import PDFKit
import SwiftUI
import UIKit

// MARK: - Tools

/// The markup toolbar.
enum PDFMarkupTool: String, CaseIterable, Identifiable {
	case highlight, underline, strikeOut, pen, highlighter, eraser, text, note, line, arrow, rectangle, ellipse

	var id: String { rawValue }

	var label: LocalizedStringKey {
		switch self {
		case .highlight: return "Highlight text"
		case .underline: return "Underline text"
		case .strikeOut: return "Strike out text"
		case .pen: return "Pen"
		case .highlighter: return "Highlighter"
		case .eraser: return "Eraser"
		case .text: return "Text box"
		case .note: return "Note"
		case .line: return "Line"
		case .arrow: return "Arrow"
		case .rectangle: return "Rectangle"
		case .ellipse: return "Circle"
		}
	}

	var systemImage: String {
		switch self {
		case .highlight: return "highlighter"
		case .underline: return "underline"
		case .strikeOut: return "strikethrough"
		case .pen: return "pencil.tip"
		case .highlighter: return "paintbrush.pointed"
		case .eraser: return "eraser"
		case .text: return "character.textbox"
		case .note: return "note.text"
		case .line: return "line.diagonal"
		case .arrow: return "arrow.up.right"
		case .rectangle: return "rectangle"
		case .ellipse: return "circle"
		}
	}

	/// Tools that mark the PDF's own text, chosen by dragging across it.
	var marksText: Bool { self == .highlight || self == .underline || self == .strikeOut }
	/// Tools that place something where you tap.
	var placesOnTap: Bool { self == .text || self == .note }
	var isShape: Bool { self == .line || self == .arrow || self == .rectangle || self == .ellipse }

	/// The color and size this tool remembers (nil for the eraser).
	var styleGroup: PDFMarkupStyleGroup? {
		switch self {
		case .highlight, .highlighter: return .highlighter
		case .underline, .strikeOut: return .textLine
		case .pen: return .pen
		case .line, .arrow, .rectangle, .ellipse: return .shape
		case .text, .note: return .text
		case .eraser: return nil
		}
	}

	/// What the hint line says while the tool is chosen.
	var hint: LocalizedStringKey {
		switch self {
		case .highlight, .underline, .strikeOut: return "Drag across the text"
		case .pen, .highlighter, .line, .arrow, .rectangle, .ellipse: return "Draw with one finger, scroll with two"
		case .eraser: return "Touch a mark to erase it"
		case .text: return "Tap where the text box goes"
		case .note: return "Tap where the note goes"
		}
	}
}

/// Tools that share a remembered color and size.
enum PDFMarkupStyleGroup: String, CaseIterable {
	case highlighter, textLine, pen, shape, text

	var swatches: [MarkSwatch] { self == .highlighter ? MarkPalette.highlighter : MarkPalette.ink }
	/// Stroke widths in points; font sizes for text.
	var sizes: [CGFloat] {
		switch self {
		case .highlighter: return [8, 14, 20]
		case .textLine: return [1, 1.5, 2.5]
		case .pen, .shape: return [1.5, 3, 5]
		case .text: return [12, 16, 22]
		}
	}
	var defaultStyle: PDFMarkupStyle { PDFMarkupStyle(colorIndex: self == .shape ? 1 : 0, sizeIndex: 1) }
}

extension MarkSwatch {
	var uiColor: UIColor {
		UIColor(red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255, blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
	}
}

/// Annotate's colors and sizes (`MarkPalette`) are shared, so marks look alike on scans and PDFs.
enum PDFMarkupPalette {
	/// How see-through freehand highlighter strokes are; Annotate's canvas uses the same.
	static let highlighterAlpha: CGFloat = 0.45
}

struct PDFMarkupStyle: Equatable {
	var colorIndex: Int
	var sizeIndex: Int
}

// MARK: - Edits

/// One undoable change. Pages and annotations are kept by reference, so undo puts back
/// the very objects that were removed.
enum PDFEdit {
	case addAnnotations([(annotation: PDFAnnotation, page: PDFPage)])
	case removeAnnotations([(annotation: PDFAnnotation, page: PDFPage)])
	case setContents(PDFAnnotation, old: String?, new: String?)
	case rotate([PDFPage], degrees: Int)
	case movePage(from: Int, to: Int)
	/// Pages and the indexes they had, ascending.
	case removePages([(page: PDFPage, index: Int)])
	/// Pages and the indexes they land at, ascending.
	case insertPages([(page: PDFPage, index: Int)])

	var inverse: PDFEdit {
		switch self {
		case .addAnnotations(let items): return .removeAnnotations(items)
		case .removeAnnotations(let items): return .addAnnotations(items)
		case .setContents(let annotation, let old, let new): return .setContents(annotation, old: new, new: old)
		case .rotate(let pages, let degrees): return .rotate(pages, degrees: -degrees)
		case .movePage(let from, let to): return .movePage(from: to, to: from)
		case .removePages(let items): return .insertPages(items)
		case .insertPages(let items): return .removePages(items)
		}
	}

	/// True for changes to the page list, which the organizer redraws for.
	var changesPages: Bool {
		switch self {
		case .rotate, .movePage, .removePages, .insertPages: return true
		default: return false
		}
	}

	func apply(to document: PDFDocument) {
		switch self {
		case .addAnnotations(let items):
			for item in items { item.page.addAnnotation(item.annotation) }
		case .removeAnnotations(let items):
			for item in items {
				if let popup = item.annotation.popup { item.page.removeAnnotation(popup) }
				item.page.removeAnnotation(item.annotation)
			}
		case .setContents(let annotation, _, let new):
			annotation.contents = new
		case .rotate(let pages, let degrees):
			for page in pages { page.rotation = ((page.rotation + degrees) % 360 + 360) % 360 }
		case .movePage(let from, let to):
			guard let page = document.page(at: from) else { return }
			document.removePage(at: from)
			document.insert(page, at: min(to, document.pageCount))
		case .removePages(let items):
			for item in items.sorted(by: { $0.index > $1.index }) {
				let index = document.index(for: item.page)
				if index != NSNotFound { document.removePage(at: index) }
			}
		case .insertPages(let items):
			for item in items.sorted(by: { $0.index < $1.index }) {
				document.insert(item.page, at: min(item.index, document.pageCount))
			}
		}
	}
}

// MARK: - Session

@MainActor
@Observable
final class PDFEditSession {
	enum Mode: Equatable { case read, markup }

	let item: PDFItem
	let document: PDFDocument
	/// What the original file says it is (claims, tags, XFA…).
	let originalReport: PDFFormatReport
	/// What the open version says it is: the edited copy's report once Folio has saved.
	private(set) var currentReport: PDFFormatReport

	var mode = Mode.read
	var tool = PDFMarkupTool.highlight
	/// The page the reader is on (the left page of a spread).
	var currentPageIndex = 0
	private(set) var styles: [PDFMarkupStyleGroup: PDFMarkupStyle] =
		Dictionary(uniqueKeysWithValues: PDFMarkupStyleGroup.allCases.map { ($0, $0.defaultStyle) })

	/// Bumped on every change, so views that draw pages refresh.
	private(set) var revision = 0

	/// The page count, observed: it changes with `revision`.
	var pageCount: Int {
		_ = revision
		return document.pageCount
	}
	private(set) var hasUnsavedChanges = false
	private var undoStack: [PDFEdit] = []
	private var redoStack: [PDFEdit] = []

	/// The password that unlocked the file, reused when saving so it stays protected.
	private var password: String?
	private var formSnapshot: [String] = []

	init(item: PDFItem, document: PDFDocument, report: PDFFormatReport, originalReport: PDFFormatReport) {
		self.item = item
		self.document = document
		self.currentReport = report
		self.originalReport = originalReport
		if !document.isLocked { formSnapshot = Self.formValues(in: document, report: report) }
	}

	/// Opens the item's current version; nil when it can't be read.
	static func open(_ item: PDFItem, in library: PDFLibrary) -> PDFEditSession? {
		let url = library.currentURL(for: item)
		guard let document = PDFDocument(url: url) else { return nil }
		let report = PDFFormatInspector.inspect(url: url) ?? PDFFormatReport()
		let original = item.isEdited ? (PDFFormatInspector.inspect(url: library.originalURL(for: item)) ?? report) : report
		return PDFEditSession(item: item, document: document, report: report, originalReport: original)
	}

	// MARK: Locking

	/// Observed through `revision`, which unlocking bumps.
	var isLocked: Bool {
		_ = revision
		return document.isLocked
	}

	/// The password the reader typed, for anything else that has to open the file.
	var unlockPassword: String? { password }

	func unlock(with password: String) -> Bool {
		guard document.unlock(withPassword: password) else { return false }
		self.password = password
		formSnapshot = Self.formValues(in: document, report: currentReport)
		revision += 1
		return true
	}

	// MARK: What's allowed

	/// Dynamic XFA forms only show a placeholder page; editing it would be pointless.
	var isPlaceholderForm: Bool { currentReport.xfa == .dynamic }

	/// The file can be saved: unencrypted, opened with the owner password, or protected
	/// by a password that restricts nothing (so saving with it changes nothing).
	var canSave: Bool {
		guard !isPlaceholderForm, !isLocked else { return false }
		guard document.isEncrypted else { return true }
		return document.permissionsStatus == .owner || restrictsNothing
	}

	var canMarkUp: Bool { canSave && document.allowsCommenting }
	var canOrganize: Bool { canSave && document.allowsDocumentAssembly }
	var canFillForms: Bool { canSave && document.allowsFormFieldEntry && currentReport.formFieldCount > 0 }

	/// Why editing is off, when it is.
	var readOnlyReason: String? {
		if isPlaceholderForm {
			return String(localized: "Dynamic XFA forms are drawn by Adobe's XFA engine, which Folio doesn't have. You're seeing the form's placeholder page.")
		}
		// Until it's unlocked, the password card says all there is to say.
		if isLocked { return nil }
		if document.isEncrypted && !canSave {
			return String(localized: "The owner of this PDF limits changes. You can read and search it.")
		}
		return nil
	}

	private var restrictsNothing: Bool {
		document.allowsCommenting && document.allowsDocumentAssembly && document.allowsFormFieldEntry
			&& document.allowsDocumentChanges && document.allowsCopying && document.allowsPrinting
			&& document.allowsContentAccessibility
	}

	// MARK: Style

	var currentStyleGroup: PDFMarkupStyleGroup? { tool.styleGroup }

	var currentStyle: PDFMarkupStyle? { currentStyleGroup.map { styles[$0] ?? $0.defaultStyle } }

	var currentColor: UIColor {
		guard let group = currentStyleGroup, let style = currentStyle else { return .black }
		return group.swatches[min(style.colorIndex, group.swatches.count - 1)].uiColor
	}

	var currentSize: CGFloat {
		guard let group = currentStyleGroup, let style = currentStyle else { return 2 }
		return group.sizes[min(style.sizeIndex, group.sizes.count - 1)]
	}

	func selectColor(_ index: Int) {
		guard let group = currentStyleGroup else { return }
		styles[group, default: group.defaultStyle].colorIndex = index
	}

	func selectSize(_ index: Int) {
		guard let group = currentStyleGroup else { return }
		styles[group, default: group.defaultStyle].sizeIndex = index
	}

	// MARK: Changes

	var canUndo: Bool { !undoStack.isEmpty }
	var canRedo: Bool { !redoStack.isEmpty }

	func perform(_ edit: PDFEdit) {
		edit.apply(to: document)
		undoStack.append(edit)
		redoStack.removeAll()
		changed()
	}

	/// Records a change the viewer already made (the eraser removes marks as you drag).
	func recordApplied(_ edit: PDFEdit) {
		undoStack.append(edit)
		redoStack.removeAll()
		changed()
	}

	func undo() {
		guard let edit = undoStack.popLast() else { return }
		edit.inverse.apply(to: document)
		redoStack.append(edit)
		changed()
	}

	func redo() {
		guard let edit = redoStack.popLast() else { return }
		edit.apply(to: document)
		undoStack.append(edit)
		changed()
	}

	private func changed() {
		hasUnsavedChanges = true
		revision += 1
	}

	/// True when Folio's changes or typed form values differ from the open file.
	var needsSave: Bool {
		hasUnsavedChanges || (currentReport.formFieldCount > 0 && Self.formValues(in: document, report: currentReport) != formSnapshot)
	}

	// MARK: Saving

	/// Writes the edited copy, keeping the file's password. The original stays as imported.
	func save(in library: PDFLibrary) throws {
		guard canSave, needsSave else { return }
		var options: [PDFDocumentWriteOption: Any] = [:]
		if document.isEncrypted, let password {
			options[.userPasswordOption] = password
			options[.ownerPasswordOption] = password
		}
		let saved = try library.save(document, for: library.item(item.id) ?? item, options: options)
		if let saved { currentReport = saved }
		hasUnsavedChanges = false
		formSnapshot = Self.formValues(in: document, report: currentReport)
	}

	/// Every form field's value in page order, to tell whether the user typed anything.
	private static func formValues(in document: PDFDocument, report: PDFFormatReport) -> [String] {
		guard report.formFieldCount > 0 else { return [] }
		var values: [String] = []
		for index in 0..<document.pageCount {
			guard let page = document.page(at: index) else { continue }
			for annotation in page.annotations where annotation.type == "Widget" {
				values.append("\(annotation.fieldName ?? ""):\(annotation.widgetStringValue ?? ""):\(annotation.buttonWidgetState.rawValue)")
			}
		}
		return values
	}

	// MARK: Find

	/// Matches for the current search, in page order, as PDFKit finds them.
	private(set) var findResults: [PDFSelection] = []
	/// The match the reader is on.
	private(set) var findIndex: Int?
	private(set) var isFinding = false
	@ObservationIgnored private lazy var finder = PDFFinder(session: self)

	/// Searches the whole document in the background; matches arrive as they're found.
	func find(_ query: String) {
		finder.start(query.trimmingCharacters(in: .whitespacesAndNewlines))
	}

	func showNextResult() {
		guard !findResults.isEmpty else { return }
		findIndex = ((findIndex ?? -1) + 1) % findResults.count
	}

	func showPreviousResult() {
		guard !findResults.isEmpty else { return }
		findIndex = ((findIndex ?? 0) - 1 + findResults.count) % findResults.count
	}

	func endFind() {
		finder.cancel()
		findResults = []
		findIndex = nil
		isFinding = false
	}

	fileprivate func findStarted() {
		findResults = []
		findIndex = nil
		isFinding = true
	}

	fileprivate func found(_ selection: PDFSelection) {
		selection.color = UIColor(Color.goldenrod).withAlphaComponent(0.45)
		findResults.append(selection)
		if findIndex == nil { findIndex = 0 }
	}

	fileprivate func findEnded() {
		isFinding = false
	}

	// MARK: Pages

	func rotate(_ indexes: [Int], degrees: Int) {
		let pages = indexes.sorted().compactMap { document.page(at: $0) }
		guard !pages.isEmpty else { return }
		perform(.rotate(pages, degrees: degrees))
	}

	func deletePages(_ indexes: [Int]) {
		let items = indexes.sorted().compactMap { index in document.page(at: index).map { (page: $0, index: index) } }
		// A PDF needs at least one page.
		guard !items.isEmpty, items.count < document.pageCount else { return }
		perform(.removePages(items))
	}

	func movePage(from: Int, to: Int) {
		guard from != to, from >= 0, from < document.pageCount, to >= 0, to < document.pageCount else { return }
		perform(.movePage(from: from, to: to))
	}

	/// Inserts every page of `other` at `index` (merging two PDFs).
	func insertPages(of other: PDFDocument, at index: Int) {
		var items: [(page: PDFPage, index: Int)] = []
		for offset in 0..<other.pageCount {
			// Copies, so the other document keeps its pages.
			guard let page = other.page(at: offset)?.copy() as? PDFPage else { continue }
			items.append((page, index + offset))
		}
		guard !items.isEmpty else { return }
		perform(.insertPages(items))
	}

	/// Inserts a blank page the size of its neighbour.
	func insertBlankPage(at index: Int) {
		let reference = document.page(at: max(0, min(index, document.pageCount) - 1)) ?? document.page(at: 0)
		let bounds = reference?.bounds(for: .mediaBox) ?? CGRect(x: 0, y: 0, width: 612, height: 792)
		let image = UIGraphicsImageRenderer(size: bounds.size).image { context in
			UIColor.white.setFill()
			context.fill(CGRect(origin: .zero, size: bounds.size))
		}
		guard let page = PDFPage(image: image) else { return }
		perform(.insertPages([(page, index)]))
	}

	/// Inserts photos as pages.
	func insertImages(_ images: [UIImage], at index: Int) {
		let items = images.enumerated().compactMap { offset, image in PDFPage(image: image).map { (page: $0, index: index + offset) } }
		guard !items.isEmpty else { return }
		perform(.insertPages(items))
	}

	/// The chosen pages as a new PDF (copies; this document is unchanged).
	func extractedPDF(_ indexes: [Int]) -> Data? {
		let extracted = PDFDocument()
		for (offset, index) in indexes.sorted().enumerated() {
			guard let page = document.page(at: index)?.copy() as? PDFPage else { continue }
			extracted.insert(page, at: offset)
		}
		return extracted.pageCount > 0 ? extracted.dataRepresentation() : nil
	}

	// MARK: Marks

	func add(_ annotations: [PDFAnnotation], on page: PDFPage) {
		guard !annotations.isEmpty else { return }
		perform(.addAnnotations(annotations.map { (annotation: $0, page: page) }))
	}

	/// Erases the mark under `point` (page space), if it's one Folio's tools make.
	@discardableResult
	func erase(at point: CGPoint, on page: PDFPage) -> Bool {
		guard let annotation = page.annotations.last(where: { PDFMarkupFactory.isErasable($0) && PDFMarkupFactory.hitTest($0, point) }) else {
			return false
		}
		perform(.removeAnnotations([(annotation, page)]))
		return true
	}

	func setContents(of annotation: PDFAnnotation, to text: String) {
		let old = annotation.contents
		guard old != text else { return }
		if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let page = annotation.page {
			perform(.removeAnnotations([(annotation, page)]))
		} else {
			perform(.setContents(annotation, old: old, new: text))
		}
	}
}

// MARK: - Find

/// Runs PDFKit's background search and hands matches to the session on the main thread.
private final class PDFFinder: NSObject, PDFDocumentDelegate {
	private weak var session: PDFEditSession?
	private let document: PDFDocument
	/// Bumped per search, so a cancelled search's late matches are dropped.
	private var generation = 0

	@MainActor
	init(session: PDFEditSession) {
		self.session = session
		self.document = session.document
	}

	@MainActor
	func start(_ query: String) {
		cancel()
		generation += 1
		session?.findStarted()
		guard !query.isEmpty else {
			session?.findEnded()
			return
		}
		document.delegate = self
		document.beginFindString(query, withOptions: [.caseInsensitive, .diacriticInsensitive])
	}

	@MainActor
	func cancel() {
		if document.isFinding { document.cancelFindString() }
		generation += 1
	}

	func didMatchString(_ instance: PDFSelection) {
		let token = generation
		DispatchQueue.main.async { [weak self] in
			guard let self, token == self.generation else { return }
			MainActor.assumeIsolated { self.session?.found(instance) }
		}
	}

	func documentDidEndDocumentFind(_ notification: Notification) {
		let token = generation
		DispatchQueue.main.async { [weak self] in
			guard let self, token == self.generation else { return }
			MainActor.assumeIsolated { self.session?.findEnded() }
		}
	}
}

// MARK: - Making marks

/// Builds standard PDF annotations. PDFKit measures ink paths, line endpoints and
/// highlight quads from the annotation's own origin, not the page's.
enum PDFMarkupFactory {
	/// A freehand stroke through `points` (page space).
	static func ink(_ points: [CGPoint], color: UIColor, width: CGFloat, alpha: CGFloat = 1) -> PDFAnnotation? {
		guard let first = points.first else { return nil }
		let bounds = boundingRect(points).insetBy(dx: -width, dy: -width)
		let path = UIBezierPath()
		path.move(to: CGPoint(x: first.x - bounds.minX, y: first.y - bounds.minY))
		if points.count == 1 {
			path.addLine(to: CGPoint(x: first.x - bounds.minX + 0.1, y: first.y - bounds.minY))
		}
		for point in points.dropFirst() {
			path.addLine(to: CGPoint(x: point.x - bounds.minX, y: point.y - bounds.minY))
		}
		path.lineCapStyle = .round
		path.lineJoinStyle = .round
		let annotation = PDFAnnotation(bounds: bounds, forType: .ink, withProperties: nil)
		annotation.add(path)
		annotation.color = color.withAlphaComponent(alpha)
		annotation.border = border(width)
		annotation.modificationDate = Date()
		return annotation
	}

	/// A line, arrow, rectangle or circle dragged from `start` to `end` (page space).
	static func shape(_ tool: PDFMarkupTool, from start: CGPoint, to end: CGPoint, color: UIColor, width: CGFloat) -> PDFAnnotation? {
		let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
		guard max(rect.width, rect.height) >= 4 else { return nil }
		let annotation: PDFAnnotation
		switch tool {
		case .line, .arrow:
			let bounds = rect.insetBy(dx: -width * 4, dy: -width * 4)
			annotation = PDFAnnotation(bounds: bounds, forType: .line, withProperties: nil)
			annotation.startPoint = CGPoint(x: start.x - bounds.minX, y: start.y - bounds.minY)
			annotation.endPoint = CGPoint(x: end.x - bounds.minX, y: end.y - bounds.minY)
			annotation.endLineStyle = tool == .arrow ? .openArrow : .none
		case .rectangle:
			annotation = PDFAnnotation(bounds: rect.insetBy(dx: -width / 2, dy: -width / 2), forType: .square, withProperties: nil)
		case .ellipse:
			annotation = PDFAnnotation(bounds: rect.insetBy(dx: -width / 2, dy: -width / 2), forType: .circle, withProperties: nil)
		default:
			return nil
		}
		annotation.color = color
		annotation.border = border(width)
		annotation.modificationDate = Date()
		return annotation
	}

	/// Highlight, underline or strike-out marks over `selection`, one per line.
	static func textMarks(_ tool: PDFMarkupTool, over selection: PDFSelection, on page: PDFPage, color: UIColor) -> [PDFAnnotation] {
		let subtype: PDFAnnotationSubtype
		switch tool {
		case .highlight: subtype = .highlight
		case .underline: subtype = .underline
		case .strikeOut: subtype = .strikeOut
		default: return []
		}
		return selection.selectionsByLine().compactMap { line in
			let bounds = line.bounds(for: page)
			guard bounds.width > 1, bounds.height > 1 else { return nil }
			let annotation = PDFAnnotation(bounds: bounds, forType: subtype, withProperties: nil)
			// Top-left, top-right, bottom-left, bottom-right, from the annotation's origin.
			annotation.quadrilateralPoints = [CGPoint(x: 0, y: bounds.height), CGPoint(x: bounds.width, y: bounds.height),
											  CGPoint(x: 0, y: 0), CGPoint(x: bounds.width, y: 0)].map { NSValue(cgPoint: $0) }
			annotation.color = color
			annotation.modificationDate = Date()
			return annotation
		}
	}

	/// A sticky note at `point` (page space, the icon's top-left).
	static func note(at point: CGPoint, text: String, color: UIColor) -> PDFAnnotation {
		let annotation = PDFAnnotation(bounds: CGRect(x: point.x, y: point.y - 24, width: 24, height: 24), forType: .text, withProperties: nil)
		annotation.contents = text
		annotation.color = color
		annotation.iconType = .comment
		annotation.modificationDate = Date()
		return annotation
	}

	/// A text box whose top-left is at `point`, kept inside `pageBounds`.
	static func textBox(at point: CGPoint, text: String, color: UIColor, fontSize: CGFloat, pageBounds: CGRect) -> PDFAnnotation {
		let font = UIFont.systemFont(ofSize: fontSize)
		let maxWidth = max(pageBounds.maxX - point.x - 8, 80)
		let measured = (text as NSString).boundingRect(with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
													   options: [.usesLineFragmentOrigin], attributes: [.font: font], context: nil)
		let size = CGSize(width: ceil(measured.width) + 12, height: ceil(measured.height) + 8)
		var origin = CGPoint(x: point.x, y: point.y - size.height)
		origin.x = min(max(origin.x, pageBounds.minX), pageBounds.maxX - size.width)
		origin.y = min(max(origin.y, pageBounds.minY), pageBounds.maxY - size.height)
		let annotation = PDFAnnotation(bounds: CGRect(origin: origin, size: size), forType: .freeText, withProperties: nil)
		annotation.contents = text
		annotation.font = font
		annotation.fontColor = color
		annotation.color = .clear
		annotation.border = border(0)
		annotation.modificationDate = Date()
		return annotation
	}

	/// Marks the eraser may remove: the kinds Folio's tools make, never form fields or links.
	static func isErasable(_ annotation: PDFAnnotation) -> Bool {
		guard let type = annotation.type else { return false }
		return ["Ink", "Highlight", "Underline", "StrikeOut", "Square", "Circle", "Line", "Text", "FreeText"].contains(type)
	}

	/// True when `point` (page space) touches the annotation, with a little slack for thin strokes.
	static func hitTest(_ annotation: PDFAnnotation, _ point: CGPoint) -> Bool {
		annotation.bounds.insetBy(dx: -6, dy: -6).contains(point)
	}

	static func boundingRect(_ points: [CGPoint]) -> CGRect {
		guard let first = points.first else { return .null }
		var rect = CGRect(origin: first, size: .zero)
		for point in points.dropFirst() { rect = rect.union(CGRect(origin: point, size: .zero)) }
		return rect
	}

	private static func border(_ width: CGFloat) -> PDFBorder {
		let border = PDFBorder()
		border.lineWidth = width
		return border
	}
}
