//
//  PDFItemCard.swift
//  Folio (fork of Open Scanner)
//
//  A PDF in the Library list, beside the scans: its first pages, title, meta,
//  a "PDF file" chip (plus the standard it claims, if any) and the favorite star.
//

import SwiftUI

struct PDFItemCard: View {
	let item: PDFItem
	let onOpen: () -> Void
	let onToggleFave: () -> Void

	@State private var pages: [UIImage] = []

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
		.accessibilityLabel("\(item.title), PDF file, \(item.libraryMeta)\(item.fave ? ", favorite" : "")")
		.task(id: item.editedAt) { await loadPages() }
	}

	private var thumbnails: some View {
		HStack(alignment: .bottom, spacing: 10) {
			if pages.isEmpty {
				PaperThumbnail(image: nil, width: 46, height: 60, ink: .bark)
			}
			ForEach(Array(pages.enumerated()), id: \.offset) { _, image in
				let wide = image.size.width > image.size.height
				PaperThumbnail(image: image, width: wide ? 84 : 46, height: wide ? 52 : 60, ink: .bark)
			}
			Spacer(minLength: 0)
			if item.pageCount > 3 {
				VStack(spacing: 0) {
					Text("+\(item.pageCount - 3)")
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

	private var footer: some View {
		HStack(spacing: 8) {
			VStack(alignment: .leading, spacing: 2) {
				Text(item.title)
					.font(FolioFont.header(18))
					.foregroundStyle(.bark)
					.lineLimit(1)
				Text(item.libraryMeta)
					.font(FolioFont.ui(12))
					.foregroundStyle(.slate)
			}
			Spacer(minLength: 4)
			Text("PDF file")
				.font(FolioFont.ui(11, weight: .medium))
				.foregroundStyle(.bark)
				.padding(.vertical, 4)
				.padding(.horizontal, 9)
				.background(Color.bark.opacity(0.08), in: RoundedRectangle(cornerRadius: FolioRadius.small, style: .continuous))
			Button(action: onToggleFave) {
				Image(systemName: item.fave ? "star.fill" : "star")
					.font(.system(size: 17, weight: .light))
					.foregroundStyle(item.fave ? Color.goldenrod : Color.bark.opacity(0.3))
					.frame(width: 32, height: 32)
					.contentShape(Rectangle())
			}
			.buttonStyle(PressScaleStyle())
			.accessibilityLabel(item.fave ? "Remove from favorites" : "Add to favorites")
		}
	}

	private func loadPages() async {
		var loaded: [UIImage] = []
		for index in 0..<min(item.pageCount, 3) {
			if let image = await PDFLibrary.shared.thumbnail(for: item, page: index, width: 84) {
				loaded.append(image)
			}
		}
		pages = loaded
	}
}
