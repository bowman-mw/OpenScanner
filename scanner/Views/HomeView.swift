//
//  HomeView.swift
//  Open Scanner → Folio
//
//  Created by Slaven Radic on 2024-09-01.
//  Folio: the Library — search every word you've scanned, favorites, the
//  list of scans, and the Scan button with its picker.
//

import SwiftUI
import CoreData
import PhotosUI
import PDFKit
import ImageIO
import UniformTypeIdentifiers

/// Library filter chips.
enum LibraryFilter: String, CaseIterable {
	case all, favorites, rebuilt

	var label: LocalizedStringKey {
		switch self {
		case .all: return "All"
		case .favorites: return "Favorites"
		case .rebuilt: return "Rebuilt"
		}
	}
}

struct HomeView: View {
	@Environment(\.managedObjectContext) private var viewContext
	@Environment(FolioRouter.self) private var router

	@FetchRequest(
		sortDescriptors: [NSSortDescriptor(keyPath: \Scan.order, ascending: false)],
		animation: .default)
	private var scans: FetchedResults<Scan>

	@State private var searchText = ""
	@State private var filter = LibraryFilter.all
	@State private var pickerOpen = false
	@State private var importingPhotos = false
	@State private var importingPDF = false
	@State private var photoSelection: [PhotosPickerItem] = []
	@State private var isImporting = false
	@State private var importProgress: String?
	@State private var scanToDelete: Scan?

	var body: some View {
		ZStack(alignment: .bottomTrailing) {
			GrainBackground()

			ScrollView {
				VStack(alignment: .leading, spacing: 0) {
					header
					searchField
					filterChips
					content
				}
				.padding(.bottom, 140)
			}
			.overlay(alignment: .top) { StatusBarScrim() }
			.scrollDismissesKeyboard(.immediately)

			if pickerOpen {
				Color.bark.opacity(0.18)
					.background(.ultraThinMaterial.opacity(0.25))
					.ignoresSafeArea()
					.onTapGesture { withAnimation(FolioMotion.ui) { pickerOpen = false } }
					.transition(.opacity)
					.accessibilityLabel("Close scan options")
			}

			ScanStartPicker(isOpen: $pickerOpen, isBusy: isImporting, busyTitle: importProgress) { start in
				withAnimation(FolioMotion.ui) { pickerOpen = false }
				switch start {
				case .document: router.push(.camera(.document, appendingTo: nil))
				case .whiteboard: router.push(.camera(.whiteboard, appendingTo: nil))
				case .photos: importingPhotos = true
				case .pdf: importingPDF = true
				}
			}
			.padding(.trailing, 20)
			.padding(.bottom, 10)
		}
		.photosPicker(isPresented: $importingPhotos, selection: $photoSelection, maxSelectionCount: 30, matching: .images)
		.fileImporter(isPresented: $importingPDF, allowedContentTypes: [.pdf]) { result in
			if case .success(let url) = result {
				importPDF(url)
			}
		}
		.task { await PDFImport.pruneOriginals(in: viewContext) }
		.onChange(of: photoSelection) { _, items in
			guard !items.isEmpty else { return }
			importPhotos(items)
		}
		.confirmationDialog("Delete this scan?", isPresented: Binding(get: { scanToDelete != nil }, set: { if !$0 { scanToDelete = nil } }), presenting: scanToDelete) { scan in
			Button("Delete “\(scan.displayTitle)”", role: .destructive) { delete(scan) }
		} message: { _ in
			Text("The pages and their text are removed from this iPhone and your other devices.")
		}
	}

	// MARK: Header

	private var header: some View {
		HStack {
			Text("Folio")
				.font(FolioFont.wordmark(34))
				.foregroundStyle(.bark)
				.accessibilityAddTraits(.isHeader)
			Spacer()
			CircleIconButton(systemName: "slider.vertical.3", label: "Settings") {
				router.push(.settings)
			}
		}
		.padding(.horizontal, 20)
		.padding(.top, 8)
		.padding(.bottom, 4)
	}

	private var searchField: some View {
		HStack(spacing: 8) {
			Image(systemName: "magnifyingglass")
				.font(.system(size: 16))
				.foregroundStyle(.slate)
			TextField("Search every word you've scanned", text: $searchText)
				.font(FolioFont.ui(15))
				.foregroundStyle(.bark)
				.submitLabel(.search)
				.autocorrectionDisabled()
				.textInputAutocapitalization(.never)
			if !searchText.isEmpty {
				Button {
					searchText = ""
				} label: {
					Image(systemName: "xmark.circle.fill")
						.foregroundStyle(Color.slate.opacity(0.6))
				}
				.accessibilityLabel("Clear search")
			}
		}
		.padding(.horizontal, 14)
		.frame(height: 44)
		.background(Color.cream, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
		.overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.bark.opacity(0.08)) }
		.padding(.horizontal, 20)
		.padding(.top, 10)
	}

	private var filterChips: some View {
		HStack(spacing: 8) {
			ForEach(LibraryFilter.allCases, id: \.self) { option in
				ChoiceChip(label: option.label, isSelected: filter == option) {
					filter = option
				}
			}
		}
		.padding(.horizontal, 20)
		.padding(.top, 14)
		.padding(.bottom, 6)
	}

	// MARK: Content

	private var visibleScans: [Scan] {
		scans.filter { scan in
			switch filter {
			case .all: break
			case .favorites: if !scan.fave { return false }
			case .rebuilt: if scan.output == .pdf { return false }
			}
			return searchText.isEmpty || scan.containsText(searchText.trimmingCharacters(in: .whitespaces))
		}
	}

	@ViewBuilder
	private var content: some View {
		let visible = visibleScans
		if scans.isEmpty {
			Text("Nothing scanned yet. Tap Scan whenever you're ready.")
				.font(FolioFont.bubble(16))
				.foregroundStyle(.slate)
				.multilineTextAlignment(.center)
				.frame(maxWidth: .infinity)
				.padding(.horizontal, 32)
				.padding(.vertical, 48)
		} else if visible.isEmpty {
			Text(searchText.isEmpty ? "Nothing here yet." : "Nothing here mentions that yet.")
				.font(FolioFont.bubble(16))
				.foregroundStyle(.slate)
				.multilineTextAlignment(.center)
				.frame(maxWidth: .infinity)
				.padding(.horizontal, 32)
				.padding(.vertical, 48)
		} else {
			LazyVStack(spacing: 12) {
				ForEach(visible, id: \.objectID) { scan in
					ScanCard(scan: scan) { open(scan) } onToggleFave: { toggleFave(scan) }
						.contextMenu { cardMenu(scan) }
				}
			}
			.padding(.horizontal, 16)
			.padding(.top, 8)
		}
	}

	@ViewBuilder
	private func cardMenu(_ scan: Scan) -> some View {
		Button {
			toggleFave(scan)
		} label: {
			Label(scan.fave ? "Remove from favorites" : "Add to favorites", systemImage: scan.fave ? "star.slash" : "star")
		}
		Button(role: .destructive) {
			scanToDelete = scan
		} label: {
			Label("Delete", systemImage: "trash")
		}
	}

	// MARK: Actions

	private func open(_ scan: Scan) {
		router.push(.preview(scan))
	}

	private func toggleFave(_ scan: Scan) {
		withAnimation(FolioMotion.ui) {
			scan.fave.toggle()
		}
		viewContext.saveQuietly()
	}

	private func delete(_ scan: Scan) {
		router.forget(scan)
		if let id = scan.id { PDFImport.removeOriginal(for: id) }
		withAnimation(FolioMotion.ui) {
			viewContext.delete(scan)
			viewContext.saveQuietly()
		}
	}

	private func importPhotos(_ items: [PhotosPickerItem]) {
		isImporting = true
		Task {
			var images: [UIImage] = []
			for item in items {
				if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
					let removeShadows = UserDefaults.standard.bool(forKey: FolioPreference.removeShadows)
					images.append(await ImportCleanup.prepare(image.normalizedUp(), removeShadows: removeShadows))
				}
			}
			photoSelection = []
			isImporting = false
			guard !images.isEmpty else {
				router.showToast(String(localized: "Those photos couldn't be opened."))
				return
			}
			let title = images.count == 1 ? String(localized: "Photo, \(Date().formatted(.dateTime.month(.abbreviated).day()))")
				: String(localized: "Photos, \(Date().formatted(.dateTime.month(.abbreviated).day()))")
			let scan = Scan.create(from: images, title: title, source: nil, in: viewContext)
			router.push(.scan(scan))
		}
	}

	private func importPDF(_ url: URL) {
		isImporting = true
		importProgress = String(localized: "Opening PDF…")
		Task {
			let scoped = url.startAccessingSecurityScopedResource()
			let images = await PDFImport.pages(of: url) { done, total in
				importProgress = String(localized: "Opening page \(done) of \(total)")
			}
			// Copied while the file is still ours to read; kept once the scan has an id.
			let original = images.isEmpty ? nil : await PDFImport.stageOriginal(url)
			if scoped { url.stopAccessingSecurityScopedResource() }
			isImporting = false
			importProgress = nil
			guard !images.isEmpty else {
				router.showToast(String(localized: "That PDF couldn't be opened."))
				return
			}
			let title = url.deletingPathExtension().lastPathComponent
			// The file's name beats the first line Vision reads ("** amprius").
			let scan = Scan.create(from: images, title: title, source: .typed, in: viewContext, output: .pdf, suggestsTitle: false)
			if let original, let id = scan.id {
				PDFImport.keepOriginal(original, named: url.lastPathComponent, for: id)
			}
			router.push(.scan(scan))
		}
	}
}

// MARK: - PDF import

/// Turns a PDF into page images without holding every page as a bitmap: pages
/// render one at a time off the main thread and stay JPEG until something
/// draws or reads them. (Fifty-odd full-size bitmaps at once crashed the app.)
enum PDFImport {
	static let maxPages = 200
	/// Rendered width in pixels: the width a page is stored at.
	static let pageWidth: CGFloat = 2400
	/// Keeps very tall pages (receipts, posters) to a sane size.
	static let maxPageHeight: CGFloat = 4000

	/// Up to `maxPages` pages of the PDF at `url`, or none if it can't be opened.
	/// `progress` hears (pages done, pages to do) after each page.
	static func pages(of url: URL, progress: @escaping @MainActor (Int, Int) -> Void) async -> [UIImage] {
		let encoded = await Task.detached(priority: .userInitiated) { () -> [Data] in
			guard let document = PDFDocument(url: url), !document.isLocked else { return [] }
			let count = min(document.pageCount, maxPages)
			var pages: [Data] = []
			for index in 0..<count {
				autoreleasepool {
					if let page = document.page(at: index), let data = jpeg(of: page) {
						pages.append(data)
					}
				}
				await progress(index + 1, count)
			}
			return pages
		}.value
		return encoded.compactMap(lazyImage)
	}

	/// One page upright on white, `pageWidth` pixels across, as JPEG.
	private static func jpeg(of page: PDFPage) -> Data? {
		let box = page.bounds(for: .cropBox)
		let quarterTurned = (page.rotation / 90) % 2 != 0
		let size = quarterTurned ? CGSize(width: box.height, height: box.width) : box.size
		guard size.width >= 1, size.height >= 1 else { return nil }
		let scale = min(pageWidth / size.width, maxPageHeight / size.height)
		let width = Int((size.width * scale).rounded())
		let height = Int((size.height * scale).rounded())
		guard let space = CGColorSpace(name: CGColorSpace.sRGB),
			  let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
									  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
		context.setFillColor(gray: 1, alpha: 1)
		context.fill(CGRect(x: 0, y: 0, width: width, height: height))
		context.interpolationQuality = .high
		context.scaleBy(x: scale, y: scale)
		// draw(with:to:) applies the page's rotation and crop origin itself.
		page.draw(with: .cropBox, to: context)
		guard let image = context.makeImage() else { return nil }
		return UIImage(cgImage: image).jpegData(compressionQuality: 0.9)
	}

	/// A page that stays compressed in memory and is decoded only while used.
	private static func lazyImage(_ data: Data) -> UIImage? {
		let options = [kCGImageSourceShouldCache: false] as CFDictionary
		guard let source = CGImageSourceCreateWithData(data as CFData, nil),
			  let image = CGImageSourceCreateImageAtIndex(source, 0, options) else { return nil }
		return UIImage(cgImage: image)
	}
}

// MARK: - Original PDFs

/// The PDF a scan was imported from, kept under its own name as Application
/// Support/Originals/PDF/<scan id>/<name>.pdf for "View original" (and, later,
/// a rebuild that reads the PDF's own text and drawings). Like page originals it
/// lives on this iPhone only: out of Core Data, so CloudKit never syncs it, and
/// out of device backups. A scan synced from another device just has no
/// original here.
extension PDFImport {
	static var originalsDirectory: URL {
		let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
			?? FileManager.default.temporaryDirectory
		return support.appendingPathComponent("Originals", isDirectory: true).appendingPathComponent("PDF", isDirectory: true)
	}

	/// The kept PDF for `scan`, if this iPhone has one.
	static func original(for scan: Scan) -> URL? {
		guard let id = scan.id,
			  let files = try? FileManager.default.contentsOfDirectory(at: folder(for: id), includingPropertiesForKeys: nil) else { return nil }
		return files.first { $0.pathExtension.lowercased() == "pdf" }
	}

	/// Copies the picked PDF to a temporary file off the main thread. Call while
	/// its security scope is open. Nil, logged, when it can't be copied: the scan
	/// is then kept without its original.
	static func stageOriginal(_ url: URL) async -> URL? {
		await Task.detached(priority: .userInitiated) { () -> URL? in
			let staged = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).pdf")
			do {
				try FileManager.default.copyItem(at: url, to: staged)
				return staged
			} catch {
				print("Folio: couldn't copy the original PDF: \(error)")
				return nil
			}
		}.value
	}

	/// Moves a staged PDF into place as `name`, the original for scan `id` (a
	/// rename on the same volume). Its folder is new, so the prune spares it.
	static func keepOriginal(_ staged: URL, named name: String, for id: UUID) {
		let folder = folder(for: id)
		let fileName = name.lowercased().hasSuffix(".pdf") ? name : "\(name).pdf"
		do {
			try prepareOriginalsDirectory()
			try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
			try FileManager.default.moveItem(at: staged, to: folder.appendingPathComponent(fileName))
		} catch {
			print("Folio: couldn't keep the original PDF: \(error)")
		}
	}

	/// Deletes the kept PDF for scan `id`, if there is one.
	static func removeOriginal(for id: UUID) {
		let folder = folder(for: id)
		guard FileManager.default.fileExists(atPath: folder.path) else { return }
		do {
			try FileManager.default.removeItem(at: folder)
		} catch {
			print("Folio: couldn't remove an original PDF: \(error)")
		}
	}

	/// Deletes kept PDFs whose scans are gone (deleted on another device). Like
	/// page originals, it does nothing when more than half would go: an iCloud
	/// account change empties the library at once, and its scans come back under
	/// the same ids while their PDFs can't be fetched again.
	@MainActor
	static func pruneOriginals(in context: NSManagedObjectContext) async {
		let request = NSFetchRequest<NSDictionary>(entityName: "Scan")
		request.resultType = .dictionaryResultType
		request.propertiesToFetch = ["id"]
		let ids: Set<UUID>
		do {
			ids = Set(try context.fetch(request).compactMap { $0["id"] as? UUID })
		} catch {
			print("Folio: couldn't list scans to prune original PDFs: \(error)")
			return
		}
		let cutoff = Date()
		await Task.detached(priority: .utility) {
			pruneOriginals(keeping: ids, olderThan: cutoff)
		}.value
	}

	private static func pruneOriginals(keeping ids: Set<UUID>, olderThan cutoff: Date) {
		let keys: [URLResourceKey] = [.contentModificationDateKey]
		guard let folders = try? FileManager.default.contentsOfDirectory(at: originalsDirectory, includingPropertiesForKeys: keys) else { return }
		let orphans = folders.filter { folder in
			guard let id = UUID(uuidString: folder.lastPathComponent) else { return false }
			let modified = (try? folder.resourceValues(forKeys: Set(keys)))?.contentModificationDate ?? .distantPast
			return !ids.contains(id) && modified < cutoff
		}
		guard !orphans.isEmpty, orphans.count * 2 <= folders.count else { return }
		for folder in orphans {
			do {
				try FileManager.default.removeItem(at: folder)
			} catch {
				print("Folio: couldn't remove an orphaned original PDF: \(error)")
			}
		}
	}

	private static func folder(for id: UUID) -> URL {
		originalsDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
	}

	/// Creates Originals/PDF, with Originals excluded from device backups.
	private static func prepareOriginalsDirectory() throws {
		guard !FileManager.default.fileExists(atPath: originalsDirectory.path) else { return }
		try FileManager.default.createDirectory(at: originalsDirectory, withIntermediateDirectories: true)
		var values = URLResourceValues()
		values.isExcludedFromBackup = true
		var originals = originalsDirectory.deletingLastPathComponent()
		try originals.setResourceValues(values)
	}
}

// MARK: - Cards

/// A scan in the list layout: up to three page thumbnails, title, meta, kind
/// chip and favorite star.
struct ScanCard: View {
	@ObservedObject var scan: Scan
	let onOpen: () -> Void
	let onToggleFave: () -> Void

	var body: some View {
		Button(action: onOpen) {
			VStack(alignment: .leading, spacing: 12) {
				thumbnails
				footer
			}
			.padding(.top, 14)
			.padding(.horizontal, 14)
			.padding(.bottom, 12)
			.background(Color.cream, in: RoundedRectangle(cornerRadius: FolioRadius.medium, style: .continuous))
			.folioShadow(.card)
		}
		.buttonStyle(PressScaleStyle(scale: 0.97))
		.accessibilityElement(children: .combine)
		.accessibilityLabel("\(scan.displayTitle), \(scan.output.chipLabel), \(scan.libraryMeta)\(scan.fave ? ", favorite" : "")")
	}

	/// Up to three page thumbnails, and a "+N more" badge.
	private var thumbnails: some View {
		let captures = scan.capturesArray
		let slides = scan.output == .pptx
		return HStack(alignment: .bottom, spacing: 10) {
			ForEach(captures.prefix(3), id: \.objectID) { capture in
				PaperThumbnail(image: capture.thumbnail, width: slides ? 84 : 46, height: slides ? 52 : 60, ink: scan.output.ink)
			}
			if captures.isEmpty {
				PaperThumbnail(image: nil, width: 46, height: 60, ink: scan.output.ink)
			}
			Spacer(minLength: 0)
			if captures.count > 3 {
				VStack(spacing: 0) {
					Text("+\(captures.count - 3)")
						.font(FolioFont.ui(13, weight: .medium))
						.foregroundStyle(.bark)
					Text("more")
						.font(FolioFont.ui(10))
						.foregroundStyle(.moss)
				}
				.frame(width: 40, height: 40)
				.background(Color.lichen, in: Circle())
				.frame(maxHeight: .infinity)
			}
		}
		.frame(minHeight: 62, alignment: .bottomLeading)
	}

	/// Title, meta, kind chip and favorite star.
	private var footer: some View {
		HStack(spacing: 8) {
			VStack(alignment: .leading, spacing: 2) {
				Text(scan.displayTitle)
					.font(FolioFont.header(18))
					.foregroundStyle(.bark)
					.lineLimit(1)
				Text(scan.libraryMeta)
					.font(FolioFont.ui(12))
					.foregroundStyle(.slate)
			}
			Spacer(minLength: 4)
			Text(scan.output.chipLabel)
				.font(FolioFont.ui(11, weight: .medium))
				.foregroundStyle(.bark)
				.padding(.vertical, 4)
				.padding(.horizontal, 9)
				.background(scan.output.chipColor, in: RoundedRectangle(cornerRadius: FolioRadius.small, style: .continuous))
			Button(action: onToggleFave) {
				Image(systemName: scan.fave ? "star.fill" : "star")
					.font(.system(size: 17, weight: .light))
					.foregroundStyle(scan.fave ? Color.goldenrod : Color.bark.opacity(0.3))
					.frame(width: 32, height: 32)
					.contentShape(Rectangle())
			}
			.buttonStyle(PressScaleStyle())
			.accessibilityLabel(scan.fave ? "Remove from favorites" : "Add to favorites")
		}
	}
}

extension UIImage {
	/// Redraws the image with `.up` orientation so Vision and PDF export see it upright.
	func normalizedUp() -> UIImage {
		guard imageOrientation != .up else { return self }
		let format = UIGraphicsImageRendererFormat()
		format.scale = 1
		return UIGraphicsImageRenderer(size: size, format: format).image { _ in
			draw(in: CGRect(origin: .zero, size: size))
		}
	}
}

struct HomeView_Previews: PreviewProvider {
	static var previews: some View {
		HomeView()
			.environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
			.environment(FolioRouter())
	}
}
