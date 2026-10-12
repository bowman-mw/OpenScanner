//
//  InboxDrop.swift
//  Folio (fork of Open Scanner)
//
//  Writing hand-offs into the Inbox (see InboxManifest.swift for the layout). The Safari
//  extension sends a file in pieces, one native message each: `begin` makes the folder and a
//  pending manifest, `append` adds a piece, and `commit` checks the file and renames the
//  pending manifest into place. A rename is atomic, so the app never imports half a file.
//  Shared by the app (tests) and the Safari extension.
//

import Foundation

enum InboxDropError: LocalizedError, Equatable {
	/// The App Group container isn't there (the build isn't signed with the app group).
	case unavailable
	/// No hand-off with that id is still arriving.
	case unknownHandOff
	case tooLarge
	case empty
	case notAPDF
	case notAWebAddress

	var errorDescription: String? {
		switch self {
		case .unavailable: return String(localized: "Folio's shared folder isn't available. Open Folio once, then try again.")
		case .unknownHandOff: return String(localized: "That transfer to Folio was interrupted. Try again.")
		case .tooLarge: return String(localized: "That file is too large to send to Folio.")
		case .empty: return String(localized: "Nothing arrived to send to Folio.")
		case .notAPDF: return String(localized: "That file isn't a PDF.")
		case .notAWebAddress: return String(localized: "Folio can only open web addresses.")
		}
	}
}

/// Writes hand-offs into one Inbox folder.
struct InboxDrop {
	/// The App Group the app and its extensions share (scanner.entitlements).
	static let appGroup = "group.MBO.Scanner"
	static let folderName = "Inbox"
	/// The most one hand-off may hold.
	static let maxBytes: Int64 = 150 * 1024 * 1024
	/// Longest title kept in a file name.
	static let maxNameLength = 80

	let root: URL

	/// The Inbox in the App Group container; nil when the build has no app group.
	static var shared: InboxDrop? {
		guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else {
			return nil
		}
		return InboxDrop(root: container.appendingPathComponent(folderName, isDirectory: true))
	}

	func folder(for id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }

	// MARK: In pieces

	/// Starts a hand-off of a file that arrives in pieces. Returns its id.
	func begin(_ kind: InboxManifest.Kind, title: String, sourceURL: URL?, now: Date = Date()) throws -> UUID {
		guard kind != .link else { throw InboxDropError.notAWebAddress }
		if let sourceURL, !InboxManifest.isWebAddress(sourceURL) { throw InboxDropError.notAWebAddress }
		let id = UUID()
		let folder = folder(for: id)
		let name = Self.fileName(for: title, kind: kind)
		let manifest = InboxManifest(kind: kind, file: name, title: Self.cleanTitle(title, kind: kind), sourceURL: sourceURL, createdAt: now)
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		guard FileManager.default.createFile(atPath: folder.appendingPathComponent(name).path, contents: nil) else {
			throw CocoaError(.fileWriteUnknown)
		}
		try manifest.encoded().write(to: folder.appendingPathComponent(InboxManifest.pendingFileName), options: .atomic)
		return id
	}

	/// Adds the next piece of the file. Returns how many bytes have arrived.
	func append(_ data: Data, to id: UUID) throws -> Int64 {
		let file = try pendingFile(for: id)
		let size = try fileSize(file)
		guard size + Int64(data.count) <= Self.maxBytes else { throw InboxDropError.tooLarge }
		let handle = try FileHandle(forWritingTo: file)
		defer { close(handle) }
		try handle.seekToEnd()
		try handle.write(contentsOf: data)
		return size + Int64(data.count)
	}

	/// Checks the file and hands it to the app. A PDF has to look like one.
	func commit(_ id: UUID) throws {
		let folder = folder(for: id)
		let pending = folder.appendingPathComponent(InboxManifest.pendingFileName)
		let manifest = try InboxManifest.decode(Data(contentsOf: pending))
		let file = try pendingFile(for: id)
		guard try fileSize(file) > 0 else { throw InboxDropError.empty }
		if manifest.kind == .pdf {
			guard try Self.startsLikePDF(file) else { throw InboxDropError.notAPDF }
		}
		try FileManager.default.moveItem(at: pending, to: folder.appendingPathComponent(InboxManifest.fileName))
	}

	/// Drops a hand-off that's still arriving. One already handed over is left for the app.
	func cancel(_ id: UUID) {
		let folder = folder(for: id)
		guard FileManager.default.fileExists(atPath: folder.appendingPathComponent(InboxManifest.pendingFileName).path) else { return }
		do {
			try FileManager.default.removeItem(at: folder)
		} catch {
			print("Folio: couldn't remove a cancelled hand-off: \(error)")
		}
	}

	// MARK: In one go

	/// Hands over a link for the app to download.
	func dropLink(_ url: URL, title: String, now: Date = Date()) throws -> UUID {
		guard InboxManifest.isWebAddress(url) else { throw InboxDropError.notAWebAddress }
		let id = UUID()
		let folder = folder(for: id)
		let manifest = InboxManifest(kind: .link, file: nil, title: Self.cleanTitle(title, kind: .link), sourceURL: url, createdAt: now)
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		try manifest.encoded().write(to: folder.appendingPathComponent(InboxManifest.fileName), options: .atomic)
		return id
	}

	/// Hands over a whole file at once (a copy; the original isn't touched).
	func dropFile(at source: URL, as kind: InboxManifest.Kind, title: String, sourceURL: URL? = nil, now: Date = Date()) throws -> UUID {
		guard try fileSize(source) <= Self.maxBytes else { throw InboxDropError.tooLarge }
		let id = try begin(kind, title: title, sourceURL: sourceURL, now: now)
		do {
			let file = try pendingFile(for: id)
			try FileManager.default.removeItem(at: file)
			try FileManager.default.copyItem(at: source, to: file)
			try commit(id)
		} catch {
			cancel(id)
			throw error
		}
		return id
	}

	// MARK: Names

	/// "<title>.pdf" or "<title>.html", safe as a file name. The app titles a PDF after its file.
	static func fileName(for title: String, kind: InboxManifest.Kind) -> String {
		"\(cleanTitle(title, kind: kind)).\(kind == .webPage ? "html" : "pdf")"
	}

	/// The title without characters a file name can't hold, trimmed to `maxNameLength`.
	static func cleanTitle(_ title: String, kind: InboxManifest.Kind) -> String {
		let banned = CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.controlCharacters).union(.newlines)
		let words = title.components(separatedBy: banned).joined(separator: " ").split(whereSeparator: \.isWhitespace)
		var name = String(words.joined(separator: " ").prefix(maxNameLength))
		name = String(name.drop { $0 == "." || $0 == " " }).trimmingCharacters(in: .whitespaces)
		if name.lowercased().hasSuffix(".pdf") { name = String(name.dropLast(4)) }
		guard name.isEmpty else { return name }
		return kind == .webPage ? String(localized: "Web page") : String(localized: "Document")
	}

	// MARK: Files

	/// The file of a hand-off that's still arriving.
	private func pendingFile(for id: UUID) throws -> URL {
		let folder = folder(for: id)
		let pending = folder.appendingPathComponent(InboxManifest.pendingFileName)
		guard FileManager.default.fileExists(atPath: pending.path) else { throw InboxDropError.unknownHandOff }
		let manifest = try InboxManifest.decode(Data(contentsOf: pending))
		guard let name = manifest.file, InboxManifest.isPlainFileName(name) else { throw InboxDropError.unknownHandOff }
		return folder.appendingPathComponent(name)
	}

	private func fileSize(_ url: URL) throws -> Int64 {
		let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
		return (attributes[.size] as? NSNumber)?.int64Value ?? 0
	}

	private func close(_ handle: FileHandle) {
		do {
			try handle.close()
		} catch {
			print("Folio: couldn't close a hand-off file: \(error)")
		}
	}

	/// True when "%PDF-" appears in the first kilobyte, where readers look for it.
	static func startsLikePDF(_ url: URL) throws -> Bool {
		let handle = try FileHandle(forReadingFrom: url)
		defer {
			do { try handle.close() } catch { print("Folio: couldn't close a PDF being checked: \(error)") }
		}
		let head = try handle.read(upToCount: 1024) ?? Data()
		return head.range(of: Data("%PDF-".utf8)) != nil
	}
}
