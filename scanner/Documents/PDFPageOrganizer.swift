//
//  PDFPageOrganizer.swift
//  Folio (fork of Open Scanner)
//
//  Every page of the open PDF as a thumbnail: tap one to jump to it, drag to
//  reorder, or choose pages to rotate, delete or save as a new PDF. Add blank
//  pages, photos or another PDF's pages (merging two PDFs). Every change can be
//  undone, and nothing is written until the PDF is saved.
//

import PDFKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct PDFPageOrganizer: View {
	@Environment(\.dismiss) private var dismiss
	@Bindable var session: PDFEditSession
	let onGoToPage: (Int) -> Void
	/// The chosen pages as a new PDF, and how many there are.
	let onExtract: (Data, Int) -> Void

	@State private var selecting = false
	@State private var selection = Set<Int>()
	@State private var importingPDF = false
	@State private var importingPhotos = false
	@State private var photoItems: [PhotosPickerItem] = []
	@State private var problem: String?
	@State private var confirmingDelete = false

	private let columns = [GridItem(.adaptive(minimum: 104, maximum: 160), spacing: 14)]

	var body: some View {
		ZStack(alignment: .bottom) {
			GrainBackground()
			VStack(spacing: 0) {
				topBar
				ScrollView {
					LazyVGrid(columns: columns, spacing: 18) {
						ForEach(0..<session.pageCount, id: \.self) { index in
							if let page = session.document.page(at: index) {
								cell(page, index: index)
							}
						}
					}
					.padding(.horizontal, 16)
					.padding(.top, 8)
					.padding(.bottom, 140)
				}
			}
			if selecting {
				selectionBar
					.transition(.move(edge: .bottom).combined(with: .opacity))
			}
		}
		.fileImporter(isPresented: $importingPDF, allowedContentTypes: [.pdf]) { result in
			if case .success(let url) = result { insertPDF(url) }
		}
		.photosPicker(isPresented: $importingPhotos, selection: $photoItems, maxSelectionCount: 30, matching: .images)
		.onChange(of: photoItems) { _, items in
			guard !items.isEmpty else { return }
			insertPhotos(items)
		}
		.alert("Couldn't add those pages", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
			Button("OK", role: .cancel) {}
		} message: {
			Text(problem ?? "")
		}
		.confirmationDialog(selection.count == 1 ? "Delete this page?" : "Delete \(selection.count) pages?",
							isPresented: $confirmingDelete, titleVisibility: .visible) {
			Button("Delete", role: .destructive) { deleteSelection() }
		} message: {
			Text("You can undo this until you leave the PDF.")
		}
	}

	// MARK: Top

	private var topBar: some View {
		HStack(spacing: 8) {
			Button { dismiss() } label: {
				Text("Done")
					.font(FolioFont.ui(14, weight: .medium))
					.foregroundStyle(.cream)
					.frame(height: 40)
					.padding(.horizontal, 18)
					.background(Color.moss, in: Capsule())
					.folioShadow(.small)
			}
			.buttonStyle(PressScaleStyle(scale: 0.94))
			Text("Pages")
				.font(FolioFont.header(22))
				.foregroundStyle(.bark)
				.accessibilityAddTraits(.isHeader)
			Spacer(minLength: 4)
			if session.canOrganize {
				CircleIconButton(systemName: "arrow.uturn.backward", label: "Undo") { session.undo() }
					.disabled(!session.canUndo)
					.opacity(session.canUndo ? 1 : 0.4)
				addMenu
				Button {
					withAnimation(FolioMotion.ui) {
						selecting.toggle()
						selection.removeAll()
					}
				} label: {
					Text(selecting ? "Cancel" : "Select")
						.font(FolioFont.ui(14, weight: .medium))
						.foregroundStyle(.bark)
						.frame(height: 40)
						.padding(.horizontal, 14)
						.background(Color.cream, in: Capsule())
						.folioShadow(.small)
				}
				.buttonStyle(PressScaleStyle(scale: 0.94))
			}
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 6)
	}

	private var addMenu: some View {
		Menu {
			Button { session.insertBlankPage(at: insertionIndex) } label: { Label("Blank page", systemImage: "doc") }
			Button { importingPhotos = true } label: { Label("Photos", systemImage: "photo") }
			Button { importingPDF = true } label: { Label("Pages from another PDF", systemImage: "doc.on.doc") }
		} label: {
			Image(systemName: "plus")
				.font(.system(size: 17, weight: .regular))
				.foregroundStyle(.bark)
				.frame(width: 40, height: 40)
				.background(Color.cream, in: Circle())
				.folioShadow(.small)
		}
		.accessibilityLabel("Add pages")
	}

	/// New pages go after the last chosen page, or at the end.
	private var insertionIndex: Int {
		(selection.max().map { $0 + 1 }) ?? session.document.pageCount
	}

	// MARK: Pages

	private func cell(_ page: PDFPage, index: Int) -> some View {
		let isSelected = selection.contains(index)
		return VStack(spacing: 6) {
			PDFPageThumbnail(page: page, rotation: page.rotation, revision: session.revision)
				.overlay(alignment: .topTrailing) {
					if selecting {
						Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
							.font(.system(size: 22))
							.foregroundStyle(isSelected ? Color.moss : Color.bark.opacity(0.35))
							.background(Circle().fill(Color.cream).padding(2))
							.padding(6)
					}
				}
				.overlay {
					RoundedRectangle(cornerRadius: 6, style: .continuous)
						.strokeBorder(isSelected ? Color.moss : Color.clear, lineWidth: 3)
				}
			Text("\(index + 1)")
				.font(FolioFont.ui(12, weight: .medium))
				.foregroundStyle(index == session.currentPageIndex ? Color.moss : Color.slate)
				.monospacedDigit()
		}
		.contentShape(Rectangle())
		.onTapGesture {
			if selecting {
				if isSelected { selection.remove(index) } else { selection.insert(index) }
			} else {
				onGoToPage(index)
				dismiss()
			}
		}
		.draggable(String(index)) {
			PDFPageThumbnail(page: page, rotation: page.rotation, revision: session.revision)
				.frame(width: 80)
		}
		.dropDestination(for: String.self) { items, _ in
			guard session.canOrganize, let from = items.first.flatMap(Int.init), from != index else { return false }
			withAnimation(FolioMotion.ui) { session.movePage(from: from, to: index) }
			selection.removeAll()
			return true
		}
		.accessibilityElement(children: .combine)
		.accessibilityLabel(Text("Page \(index + 1)"))
		.accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
		.accessibilityActions {
			if session.canOrganize {
				if index > 0 {
					Button("Move earlier") { session.movePage(from: index, to: index - 1) }
				}
				if index < session.document.pageCount - 1 {
					Button("Move later") { session.movePage(from: index, to: index + 1) }
				}
			}
		}
	}

	private var selectionBar: some View {
		FrostedBottomBar {
			HStack(spacing: 0) {
				barButton("rotate.left", label: "Rotate left") { session.rotate(Array(selection), degrees: -90) }
				barButton("rotate.right", label: "Rotate right") { session.rotate(Array(selection), degrees: 90) }
				barButton("square.and.arrow.up.on.square", label: "Save as new PDF") { extractSelection() }
				barButton("trash", label: "Delete", tint: .terracotta) { confirmingDelete = true }
					.disabled(selection.count >= session.document.pageCount)
			}
			.disabled(selection.isEmpty)
			.opacity(selection.isEmpty ? 0.4 : 1)
			Text(selection.isEmpty ? "Choose pages, or drag one to move it" :
					(selection.count == 1 ? "1 page chosen" : "\(selection.count) pages chosen"))
				.font(FolioFont.bubble(14))
				.foregroundStyle(.slate)
		}
	}

	private func barButton(_ systemName: String, label: LocalizedStringKey, tint: Color = .bark, action: @escaping () -> Void) -> some View {
		Button(action: action) {
			VStack(spacing: 4) {
				Image(systemName: systemName)
					.font(.system(size: 19))
				Text(label)
					.font(FolioFont.ui(11, weight: .medium))
			}
			.foregroundStyle(tint)
			.frame(maxWidth: .infinity)
			.contentShape(Rectangle())
		}
		.buttonStyle(PressScaleStyle())
	}

	// MARK: Actions

	private func deleteSelection() {
		session.deletePages(Array(selection))
		selection.removeAll()
	}

	private func extractSelection() {
		guard let data = session.extractedPDF(Array(selection)) else { return }
		onExtract(data, selection.count)
		selection.removeAll()
	}

	private func insertPDF(_ url: URL) {
		let scoped = url.startAccessingSecurityScopedResource()
		defer { if scoped { url.stopAccessingSecurityScopedResource() } }
		var coordinationError: NSError?
		var other: PDFDocument?
		NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { readable in
			other = PDFDocument(url: readable)
		}
		guard let other else {
			problem = String(localized: "That file isn't a PDF Folio can open.")
			return
		}
		guard !other.isLocked else {
			problem = String(localized: "That PDF is locked with a password. Open it in Folio first, then save its pages as a new PDF.")
			return
		}
		withAnimation(FolioMotion.ui) { session.insertPages(of: other, at: insertionIndex) }
	}

	private func insertPhotos(_ items: [PhotosPickerItem]) {
		let index = insertionIndex
		Task {
			var images: [UIImage] = []
			for item in items {
				if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
					images.append(image.normalizedUp())
				}
			}
			photoItems = []
			guard !images.isEmpty else {
				problem = String(localized: "Those photos couldn't be opened.")
				return
			}
			withAnimation(FolioMotion.ui) { session.insertImages(images, at: index) }
		}
	}
}

/// A page drawn small, redrawn when it's rotated or the document changes.
struct PDFPageThumbnail: View {
	let page: PDFPage
	let rotation: Int
	let revision: Int
	@State private var image: UIImage?

	var body: some View {
		let bounds = page.bounds(for: .cropBox)
		let quarterTurned = (rotation / 90) % 2 != 0
		let aspect = quarterTurned ? bounds.height / max(bounds.width, 1) : bounds.width / max(bounds.height, 1)
		ZStack {
			Color.paper
			if let image {
				Image(uiImage: image)
					.resizable()
					.scaledToFit()
			}
		}
		.aspectRatio(max(aspect, 0.2), contentMode: .fit)
		.clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
		.shadow(color: Color.bark.opacity(0.18), radius: 2, x: 0, y: 1)
		.task(id: "\(rotation)-\(revision)") {
			// Pages belong to the open document, which isn't thread-safe: draw on the main actor, one cell at a time.
			await Task.yield()
			image = page.thumbnail(of: CGSize(width: 320, height: 320), for: .cropBox)
		}
	}
}
