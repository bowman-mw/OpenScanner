//
//  HomeView.swift
//  Open Scanner → Folio
//
//  Created by Slaven Radic on 2024-09-01.
//  Folio: the Library — search every word you've scanned, favorites, a list
//  or photowall of scans, and the Scan button with its picker.
//

import SwiftUI
import CoreData
import PhotosUI
import PDFKit
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

	@AppStorage(FolioPreference.libraryLayout) private var layout = LibraryLayout.list
	@State private var searchText = ""
	@State private var filter = LibraryFilter.all
	@State private var pickerOpen = false
	@State private var importingPhotos = false
	@State private var importingPDF = false
	@State private var photoSelection: [PhotosPickerItem] = []
	@State private var isImporting = false
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

			ScanStartPicker(isOpen: $pickerOpen, isBusy: isImporting) { start in
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
		.overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.bark.opacity(0.08)))
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
		} else if layout == .photowall {
			photowall(visible)
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

	private func photowall(_ visible: [Scan]) -> some View {
		ZStack(alignment: .top) {
			Rectangle()
				.fill(Color.bark.opacity(0.25))
				.frame(height: 1)
				.padding(.top, 16)
				.accessibilityHidden(true)
			LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)], spacing: 22) {
				ForEach(Array(visible.enumerated()), id: \.element.objectID) { index, scan in
					PolaroidCard(scan: scan, rotation: [-1.5, 1.2, 0.8, -1.0, 1.6][index % 5]) { open(scan) }
						.contextMenu { cardMenu(scan) }
				}
			}
			.padding(.top, 12)
		}
		.padding(.horizontal, 16)
		.padding(.top, 4)
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
		router.push(.scan(scan))
	}

	private func toggleFave(_ scan: Scan) {
		withAnimation(FolioMotion.ui) {
			scan.fave.toggle()
		}
		viewContext.saveQuietly()
	}

	private func delete(_ scan: Scan) {
		router.forget(scan)
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
		let scoped = url.startAccessingSecurityScopedResource()
		defer { if scoped { url.stopAccessingSecurityScopedResource() } }
		guard let document = PDFDocument(url: url) else {
			isImporting = false
			router.showToast(String(localized: "That PDF couldn't be opened."))
			return
		}
		var images: [UIImage] = []
		for index in 0..<min(document.pageCount, 200) {
			guard let page = document.page(at: index) else { continue }
			let bounds = page.bounds(for: .mediaBox)
			let width: CGFloat = 2400
			let scale = width / max(bounds.width, 1)
			images.append(page.thumbnail(of: CGSize(width: width, height: bounds.height * scale), for: .mediaBox))
		}
		isImporting = false
		let title = url.deletingPathExtension().lastPathComponent
		let scan = Scan.create(from: images, title: title, source: .typed, in: viewContext, output: .pdf)
		router.push(.scan(scan))
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
		let captures = scan.capturesArray
		let slides = scan.output == .pptx
		Button(action: onOpen) {
			VStack(alignment: .leading, spacing: 12) {
				HStack(alignment: .bottom, spacing: 10) {
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
}

/// A scan in the photowall layout: a pinned Polaroid with a slight tilt.
struct PolaroidCard: View {
	@ObservedObject var scan: Scan
	let rotation: Double
	let onOpen: () -> Void

	var body: some View {
		let slides = scan.output == .pptx
		Button(action: onOpen) {
			VStack(alignment: .leading, spacing: 0) {
				GeometryReader { proxy in
					let side = proxy.size.width
					let width = side * (slides ? 0.88 : 0.62)
					let height = width / (slides ? 16.0 / 9.0 : 3.0 / 4.0)
					ZStack {
						Color.parchment
						PaperThumbnail(image: scan.capturesArray.first?.thumbnail, width: width, height: height, ink: scan.output.ink)
					}
					.frame(width: side, height: side)
				}
				.aspectRatio(1, contentMode: .fit)

				VStack(alignment: .leading, spacing: 1) {
					Text(scan.displayTitle)
						.font(FolioFont.body(15, italic: true))
						.foregroundStyle(.bark)
						.lineLimit(1)
					Text(scan.wallMeta)
						.font(FolioFont.ui(11))
						.foregroundStyle(.slate)
				}
				.padding(.horizontal, 2)
				.padding(.top, 9)
				.padding(.bottom, 12)
			}
			.padding(.horizontal, 10)
			.padding(.top, 10)
			.background(Color.paper, in: RoundedRectangle(cornerRadius: 3, style: .continuous))
			.shadow(color: Color.bark.opacity(0.10), radius: 4, x: 0, y: 2)
			.shadow(color: Color.bark.opacity(0.08), radius: 12, x: 0, y: 10)
			.overlay(alignment: .top) {
				RoundedRectangle(cornerRadius: 3, style: .continuous)
					.fill(Color.fern)
					.frame(width: 10, height: 18)
					.offset(y: -8)
					.accessibilityHidden(true)
			}
			.rotationEffect(.degrees(rotation))
		}
		.buttonStyle(PressScaleStyle(scale: 0.96))
		.accessibilityElement(children: .combine)
		.accessibilityLabel("\(scan.displayTitle), \(scan.wallMeta)")
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
