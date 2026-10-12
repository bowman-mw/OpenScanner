//
//  LibraryAppearance.swift
//  Rescriva (fork of Open Scanner)
//
//  Folder colours and symbols from the Fernlet palette, and how folders,
//  tags, smart folders and scopes read on screen. Colour tokens and symbol
//  names are stored on the entities; a token this version doesn't know
//  shows as moss, and an unknown symbol as a plain folder.
//

import CoreData
import SwiftUI

/// A folder's colour. Stored token.
enum FolderColor: String, CaseIterable, Identifiable {
	case moss, fern, terracotta, goldenrod, slate, bark, plum, ink

	var id: String { rawValue }

	var color: Color {
		switch self {
		case .moss: return .moss
		case .fern: return .fern
		case .terracotta: return .terracotta
		case .goldenrod: return .goldenrod
		case .slate: return .slate
		case .bark: return .bark
		case .plum: return Color(red: 0x8A / 255, green: 0x5A / 255, blue: 0x7A / 255)
		case .ink: return .ink
		}
	}

	var name: String {
		switch self {
		case .moss: return String(localized: "Moss")
		case .fern: return String(localized: "Fern")
		case .terracotta: return String(localized: "Terracotta")
		case .goldenrod: return String(localized: "Goldenrod")
		case .slate: return String(localized: "Slate")
		case .bark: return String(localized: "Bark")
		case .plum: return String(localized: "Plum")
		case .ink: return String(localized: "Ink")
		}
	}

	static func token(_ raw: String?) -> FolderColor {
		raw.flatMap(FolderColor.init(rawValue:)) ?? .moss
	}
}

/// The SF Symbols a folder can wear. The names are stored tokens.
enum FolderSymbol {
	static let all = [
		"folder", "book.closed", "graduationcap", "briefcase", "flask", "lightbulb",
		"doc.text", "list.bullet.clipboard", "cart", "banknote", "house", "heart",
		"star", "leaf", "paintpalette", "music.note", "airplane", "person.2",
		"camera", "pencil", "tray", "archivebox", "calendar", "gearshape",
	]
	static let smartDefault = "gearshape"

	/// `name` when it's one of ours, otherwise `fallback`.
	static func valid(_ name: String?, fallback: String = "folder") -> String {
		guard let name, all.contains(name) else { return fallback }
		return name
	}
}

extension ScanFolder {
	var displayName: String { name?.isEmpty == false ? name ?? "" : String(localized: "Untitled Folder") }
	var tint: Color { FolderColor.token(colorToken).color }
	var symbolName: String { FolderSymbol.valid(symbol) }

	/// Subfolders, by name.
	var childFolders: [ScanFolder] {
		let set = children as? Set<ScanFolder> ?? []
		return set.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
	}

	/// Every scan filed here, deleted ones included.
	var scanList: [Scan] {
		Array(scans as? Set<Scan> ?? [])
	}
}

extension ScanTag {
	var displayName: String { "#\(name ?? "")" }
}

extension SmartFolder {
	var displayName: String { name?.isEmpty == false ? name ?? "" : String(localized: "Smart Folder") }
	var tint: Color { FolderColor.token(colorToken).color }
	var symbolName: String { FolderSymbol.valid(symbol, fallback: FolderSymbol.smartDefault) }
}

extension Scan {
	/// The scan's tags, by name.
	var tagList: [ScanTag] {
		let set = tags as? Set<ScanTag> ?? []
		return set.sorted { ($0.name ?? "").localizedStandardCompare($1.name ?? "") == .orderedAscending }
	}
}

/// How a scope reads in a title bar and a row.
struct ScopeAppearance {
	let title: String
	let symbol: String
	let tint: Color

	@MainActor
	static func of(_ scope: LibraryScope, in context: NSManagedObjectContext) -> ScopeAppearance {
		switch scope {
		case .all: return ScopeAppearance(title: String(localized: "All Scans"), symbol: "tray.full", tint: .moss)
		case .pinned: return ScopeAppearance(title: String(localized: "Pinned"), symbol: "pin", tint: .goldenrod)
		case .favorites: return ScopeAppearance(title: String(localized: "Favorites"), symbol: "star", tint: .goldenrod)
		case .recentlyDeleted: return ScopeAppearance(title: String(localized: "Recently Deleted"), symbol: "trash", tint: .slate)
		case .folder(let id):
			let folder = Library.folder(id, in: context)
			return ScopeAppearance(title: folder?.displayName ?? String(localized: "Folder"), symbol: folder?.symbolName ?? "folder",
								   tint: folder?.tint ?? .moss)
		case .tag(let id):
			return ScopeAppearance(title: Library.tag(id, in: context)?.displayName ?? "#", symbol: "number", tint: .moss)
		case .smart(let id):
			let smart = Library.smartFolder(id, in: context)
			return ScopeAppearance(title: smart?.displayName ?? String(localized: "Smart Folder"),
								   symbol: smart?.symbolName ?? FolderSymbol.smartDefault, tint: smart?.tint ?? .moss)
		}
	}
}
