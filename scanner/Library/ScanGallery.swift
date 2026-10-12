//
//  ScanGallery.swift
//  Rescriva (fork of Open Scanner)
//
//  The gallery grid every library screen uses, like Notes' gallery view:
//  page thumbnails with the title, date and tags under them, in sections
//  (Pinned first, then by date). In select mode a tap ticks a scan;
//  otherwise it opens. Long-press for Pin, Favorite, Move, Tags and Delete
//  — or Recover and Delete for Good in Recently Deleted.
//

import CoreData
import SwiftUI

struct ScanGallery: View {
	let sections: [LibraryGrouping.Section]
	let inRecentlyDeleted: Bool
	let selecting: Bool
	@Binding var selection: Set<NSManagedObjectID>
	let onAction: (GalleryAction, [Scan]) -> Void

	private let columns = [GridItem(.adaptive(minimum: 150), spacing: 14, alignment: .top)]

	var body: some View {
		LazyVStack(alignment: .leading, spacing: 22) {
			ForEach(sections) { section in
				VStack(alignment: .leading, spacing: 10) {
					if !section.title.isEmpty {
						Text(section.title)
							.rescrivaSectionLabel()
							.padding(.horizontal, 4)
							.accessibilityAddTraits(.isHeader)
					}
					LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
						ForEach(section.scans, id: \.objectID) { scan in
							tile(scan)
						}
					}
				}
			}
		}
		.padding(.horizontal, 16)
	}

	private func tile(_ scan: Scan) -> some View {
		Button {
			tapped(scan)
		} label: {
			ScanTile(scan: scan, inRecentlyDeleted: inRecentlyDeleted, isSelecting: selecting,
					 isSelected: selection.contains(scan.objectID))
		}
		.buttonStyle(PressScaleStyle(scale: 0.97))
		.contextMenu {
			if !selecting { menu(for: scan) }
		}
		.accessibilityAddTraits(selecting && selection.contains(scan.objectID) ? .isSelected : [])
	}

	private func tapped(_ scan: Scan) {
		guard selecting else {
			onAction(.open, [scan])
			return
		}
		withAnimation(RescrivaMotion.fast) {
			if selection.contains(scan.objectID) { selection.remove(scan.objectID) } else { selection.insert(scan.objectID) }
		}
	}

	@ViewBuilder
	private func menu(for scan: Scan) -> some View {
		if inRecentlyDeleted {
			Button { onAction(.recover, [scan]) } label: { Label("Recover", systemImage: "arrow.uturn.backward") }
			Button(role: .destructive) { onAction(.purge, [scan]) } label: { Label("Delete for Good", systemImage: "trash") }
		} else {
			Button { onAction(.pin(!scan.pinned), [scan]) } label: {
				Label(scan.pinned ? "Unpin" : "Pin", systemImage: scan.pinned ? "pin.slash" : "pin")
			}
			Button { onAction(.favorite(!scan.fave), [scan]) } label: {
				Label(scan.fave ? "Remove from Favorites" : "Add to Favorites", systemImage: scan.fave ? "star.slash" : "star")
			}
			Button { onAction(.move, [scan]) } label: { Label("Move to Folder…", systemImage: "folder") }
			Button { onAction(.tags, [scan]) } label: { Label("Tags…", systemImage: "number") }
			Divider()
			Button(role: .destructive) { onAction(.delete, [scan]) } label: { Label("Delete", systemImage: "trash") }
		}
	}
}

/// One scan in the grid: its first page on paper, then title, date and tags.
struct ScanTile: View {
	@ObservedObject var scan: Scan
	let inRecentlyDeleted: Bool
	let isSelecting: Bool
	let isSelected: Bool

	var body: some View {
		VStack(alignment: .leading, spacing: 5) {
			thumbnail
			Text(scan.displayTitle)
				.font(RescrivaFont.header(15))
				.foregroundStyle(.bark)
				.lineLimit(2)
				.multilineTextAlignment(.leading)
				.padding(.top, 4)
			Text(meta)
				.font(RescrivaFont.ui(11))
				.foregroundStyle(inRecentlyDeleted ? Color.terracotta : Color.slate)
				.lineLimit(1)
			if !scan.tagList.isEmpty {
				Text(scan.tagList.prefix(3).map(\.displayName).joined(separator: " "))
					.font(RescrivaFont.ui(11, weight: .medium))
					.foregroundStyle(.moss)
					.lineLimit(1)
			}
		}
		.frame(maxWidth: .infinity, alignment: .leading)
		.contentShape(Rectangle())
		.accessibilityElement(children: .ignore)
		.accessibilityLabel(Text(accessibilityText))
	}

	private var thumbnail: some View {
		Color.paper
			.aspectRatio(0.78, contentMode: .fit)
			.overlay { pageImage }
			.clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
			.overlay {
				RoundedRectangle(cornerRadius: 10, style: .continuous)
					.strokeBorder(isSelected ? Color.moss : Color.bark.opacity(0.08), lineWidth: isSelected ? 3 : 1)
			}
			.overlay(alignment: .topLeading) { kindChip }
			.overlay(alignment: .topTrailing) { badge }
			.overlay(alignment: .bottomTrailing) { pageCount }
			.shadow(color: Color.bark.opacity(0.10), radius: 3, x: 0, y: 2)
			.shadow(color: Color.bark.opacity(0.06), radius: 10, x: 0, y: 6)
	}

	@ViewBuilder
	private var pageImage: some View {
		if let image = scan.capturesArray.first?.thumbnail {
			if scan.output == .pptx {
				Image(uiImage: image).resizable().scaledToFit().padding(6)
			} else {
				Image(uiImage: image).resizable().scaledToFill()
			}
		} else {
			PlaceholderLines(ink: scan.output.ink).padding(18)
		}
	}

	private var kindChip: some View {
		Text(scan.output.chipLabel)
			.font(RescrivaFont.ui(10, weight: .medium))
			.foregroundStyle(.bark)
			.padding(.vertical, 3)
			.padding(.horizontal, 7)
			.background {
				ZStack {
					Capsule().fill(Color.cream.opacity(0.94))
					Capsule().fill(scan.output.chipColor)
				}
			}
			.padding(7)
	}

	@ViewBuilder
	private var badge: some View {
		if isSelecting {
			Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
				.font(.system(size: 22))
				.foregroundStyle(isSelected ? Color.moss : Color.bark.opacity(0.45))
				.background(Circle().fill(Color.cream).padding(2))
				.padding(7)
		} else if scan.pinned || scan.fave {
			HStack(spacing: 3) {
				if scan.pinned { Image(systemName: "pin.fill") }
				if scan.fave { Image(systemName: "star.fill") }
			}
			.font(.system(size: 10, weight: .semibold))
			.foregroundStyle(.goldenrod)
			.padding(5)
			.background(Color.cream.opacity(0.94), in: Capsule())
			.padding(7)
		}
	}

	@ViewBuilder
	private var pageCount: some View {
		let count = scan.capturesArray.count
		if count > 1 {
			Text("\(count)")
				.font(RescrivaFont.ui(10, weight: .medium))
				.foregroundStyle(.bark)
				.padding(.vertical, 3)
				.padding(.horizontal, 7)
				.background(Color.cream.opacity(0.94), in: Capsule())
				.padding(7)
				.accessibilityHidden(true)
		}
	}

	private var meta: String {
		if inRecentlyDeleted {
			let days = Library.daysLeft(for: scan)
			return days == 1 ? String(localized: "1 day left") : String(localized: "\(days) days left")
		}
		let date = scan.lastUpdate ?? scan.timestamp ?? Date()
		return Calendar.current.isDateInToday(date) ? date.formatted(date: .omitted, time: .shortened)
			: date.formatted(date: .abbreviated, time: .omitted)
	}

	private var accessibilityText: String {
		var parts = [scan.displayTitle, scan.output.chipLabel, meta]
		if scan.pinned { parts.append(String(localized: "pinned")) }
		if scan.fave { parts.append(String(localized: "favorite")) }
		parts += scan.tagList.map(\.displayName)
		return parts.joined(separator: ", ")
	}
}
