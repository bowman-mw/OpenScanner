//
//  Inbox.swift
//  Folio (fork of Open Scanner)
//
//  Importing what Folio's extensions hand over (see InboxManifest.swift). On launch, on coming to
//  the foreground and on an openscanner://inbox link, everything waiting goes into PDF Files:
//  a PDF as it is, a web page saved as a PDF first, a link downloaded first. Each hand-off's
//  folder is deleted once it's been through, imported or not. App-target only.
//

import SwiftUI

/// What one import did.
struct InboxReport: Equatable {
	/// PDFs added to PDF Files.
	var added = 0
	/// Hand-offs that couldn't be opened (and were removed).
	var failed = 0

	/// The toast for what went wrong, or nil when everything opened (PDFOpening reports that).
	var problem: String? {
		guard failed > 0 else { return nil }
		let missed = failed == 1 ? String(localized: "1 item sent to Folio couldn't be opened.")
			: String(localized: "\(failed) items sent to Folio couldn't be opened.")
		guard added > 1 else { return missed }
		return String(localized: "Added \(added) PDFs.") + " " + missed
	}
}

/// How the Inbox reaches the web: the live one, or a stand-in in tests.
@MainActor
protocol InboxWeb {
	/// Saves the HTML Safari showed as a PDF.
	func pdf(html: String, baseURL: URL?) async throws -> Data
	/// Loads the page at `url` and saves it as a PDF.
	func pdf(loading url: URL) async throws -> Data
	/// Downloads `url` to a temporary file.
	func download(_ url: URL) async throws -> URL
}

@MainActor
enum Inbox {
	static let scheme = "openscanner"
	static let host = "inbox"
	/// Posted when an openscanner://inbox link arrives; every window's `inboxImports` hears it.
	static let importRequested = Notification.Name("Folio.Inbox.importRequested")

	/// Claims an openscanner://inbox link and asks for an import. False for any other link.
	static func handle(_ url: URL) -> Bool {
		guard url.scheme?.lowercased() == scheme, url.host()?.lowercased() == host else { return false }
		NotificationCenter.default.post(name: importRequested, object: nil)
		return true
	}

	/// Imports everything ready in `store` into `library` through PDFOpening (one PDF opens
	/// straight away; more are counted in a toast), then removes every hand-off it looked at.
	@discardableResult
	static func importPending(from store: InboxStore?, into library: PDFLibrary, router: FolioRouter,
							  web: InboxWeb) async -> InboxReport {
		guard let store else { return InboxReport() }
		let contents = store.contents()
		for folder in contents.unusable + contents.abandoned {
			store.remove(folder)
		}
		var report = InboxReport(failed: contents.unusable.count)
		guard !contents.ready.isEmpty || report.failed > 0 else { return report }
		if contents.ready.contains(where: { $0.manifest.kind != .pdf }) {
			router.showToast(String(localized: "Opening what you sent to Folio…"))
		}
		var files: [URL] = []
		for item in contents.ready {
			do {
				files.append(try await pdfFile(for: item, web: web))
			} catch {
				print("Folio: couldn't import \(item.manifest.kind.rawValue) from the Inbox: \(error)")
				report.failed += 1
			}
		}
		let before = Set(library.items.map(\.id))
		await PDFOpening.open(files, in: library, router: router)
		report.added = library.items.filter { !before.contains($0.id) }.count
		report.failed += files.count - report.added
		for item in contents.ready {
			store.remove(item.folder)
		}
		if let problem = report.problem {
			router.showToast(problem)
		}
		return report
	}

	/// The hand-off as a PDF file in its folder, named for its title (PDFOpening titles it so).
	private static func pdfFile(for item: InboxStore.Item, web: InboxWeb) async throws -> URL {
		let manifest = item.manifest
		let destination = item.folder.appendingPathComponent(InboxDrop.fileName(for: manifest.title, kind: .pdf))
		switch manifest.kind {
		case .pdf:
			guard let file = item.fileURL else { throw InboxDropError.unknownHandOff }
			return file
		case .webPage:
			guard let file = item.fileURL else { throw InboxDropError.unknownHandOff }
			let html = try String(contentsOf: file, encoding: .utf8)
			try await web.pdf(html: html, baseURL: manifest.sourceURL).write(to: destination, options: .atomic)
			return destination
		case .link:
			guard let url = manifest.sourceURL else { throw InboxDropError.notAWebAddress }
			let downloaded = try await web.download(url)
			defer { removeQuietly(downloaded) }
			if try InboxDrop.startsLikePDF(downloaded) {
				// A run cut short may have left one here already.
				removeQuietly(destination)
				try FileManager.default.moveItem(at: downloaded, to: destination)
			} else {
				try await web.pdf(loading: url).write(to: destination, options: .atomic)
			}
			return destination
		}
	}

	private static func removeQuietly(_ url: URL) {
		guard FileManager.default.fileExists(atPath: url.path) else { return }
		do {
			try FileManager.default.removeItem(at: url)
		} catch {
			print("Folio: couldn't remove a download: \(error)")
		}
	}
}

// MARK: - Live web

/// The Inbox's real web: WebKit for pages, URLSession for downloads.
struct LiveInboxWeb: InboxWeb {
	func pdf(html: String, baseURL: URL?) async throws -> Data {
		try await WebPagePDF.pdf(html: html, baseURL: baseURL)
	}

	func pdf(loading url: URL) async throws -> Data {
		try await WebPagePDF.pdf(loading: url)
	}

	func download(_ url: URL) async throws -> URL {
		let request = URLRequest(url: url, timeoutInterval: WebPagePDF.loadTimeout)
		let (file, response) = try await URLSession.shared.download(for: request)
		if let http = response as? HTTPURLResponse {
			guard (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
		}
		// URLSession deletes its file when this returns; keep a copy under a name of our own.
		let kept = FileManager.default.temporaryDirectory.appendingPathComponent("inbox-\(UUID().uuidString)")
		try FileManager.default.moveItem(at: file, to: kept)
		return kept
	}
}

// MARK: - When to import

/// Runs imports one at a time for the whole app (each window asks; there's one Inbox).
@MainActor
final class InboxImporter {
	static let shared = InboxImporter()
	/// Back-to-back passes one run may make while requests keep arriving.
	private static let maxPasses = 3

	private var isRunning = false
	private var askedAgain = false

	/// Imports now, or once more after the import already running.
	func request(router: FolioRouter) {
		guard !isRunning else {
			askedAgain = true
			return
		}
		isRunning = true
		Task {
			for _ in 0..<Self.maxPasses {
				askedAgain = false
				await Inbox.importPending(from: .shared, into: PDFLibrary.shared, router: router, web: LiveInboxWeb())
				guard askedAgain else { break }
			}
			isRunning = false
		}
	}
}

/// Imports the Inbox when the window comes to the foreground (launch included) and when an
/// openscanner://inbox link arrives.
private struct InboxImports: ViewModifier {
	@Environment(\.scenePhase) private var scenePhase
	let router: FolioRouter

	func body(content: Content) -> some View {
		content
			.onChange(of: scenePhase, initial: true) { _, phase in
				guard phase == .active else { return }
				InboxImporter.shared.request(router: router)
			}
			.onReceive(NotificationCenter.default.publisher(for: Inbox.importRequested)) { _ in
				InboxImporter.shared.request(router: router)
			}
	}
}

extension View {
	/// Brings in what Folio's extensions hand over; see `Inbox`.
	func inboxImports(router: FolioRouter) -> some View {
		modifier(InboxImports(router: router))
	}
}
