//
//  FolioRouter.swift
//  Folio (fork of Open Scanner)
//
//  Navigation for the Folio flow. Screens float in and dissolve out (the
//  Fernlet motion rules forbid sliding pushes), so instead of a
//  NavigationStack the app keeps an explicit stack of routes over the Library.
//

import SwiftUI
import CoreData
import UIKit

/// The design's screen map, below the Library root.
enum FolioRoute: Hashable {
	/// The document camera; `appendingTo` adds pages to an existing scan.
	case camera(CaptureKind, appendingTo: Scan?)
	/// Read-only preview of a scan (what opens from the Library).
	case preview(Scan)
	/// Scan & pages — the editor, reached with Edit.
	case scan(Scan)
	/// Recognized text for one page.
	case page(Scan, ScanCapture)
	/// Rebuilding into Word or Slides.
	case processing(Scan)
	/// Review & fix.
	case review(Scan)
	case settings
	/// A folder, tag, smart folder, Pinned, All Scans, Favorites or Recently Deleted.
	case collection(LibraryScope)
}

/// What the camera is pointed at. Stored token.
enum CaptureKind: String, Hashable {
	case document, whiteboard
}

/// One entry on the route stack, with a stable identity for transitions.
struct RouteEntry: Identifiable, Hashable {
	let id = UUID()
	let route: FolioRoute
}

/// A transient confirmation shown at the top of the screen.
struct FolioToast: Identifiable {
	let id = UUID()
	let message: String
	var actionLabel: String?
	var action: (() -> Void)?
}

/// Owns the route stack and the toast. One per window.
@MainActor
@Observable
final class FolioRouter {
	private(set) var stack: [RouteEntry] = [] {
		didSet { LibraryPlacement.shared.folderID = placementFolderID }
	}
	private(set) var toast: FolioToast?

	/// The visible route, or nil when the Library is showing.
	var top: FolioRoute? { stack.last?.route }

	/// The route a back pill on `route` returns to (nil = the Library).
	func routeBelow(_ route: FolioRoute) -> FolioRoute? {
		guard let index = stack.lastIndex(where: { $0.route == route }), index > 0 else { return nil }
		return stack[index - 1].route
	}

	/// The folder the topmost folder screen shows, which new scans join.
	var placementFolderID: UUID? {
		for entry in stack.reversed() {
			if case .collection(.folder(let id)) = entry.route { return id }
		}
		return nil
	}

	/// True while the camera is the visible screen (the status bar turns light).
	var isCameraVisible: Bool {
		if case .camera = top { return true }
		return false
	}

	func push(_ route: FolioRoute) {
		withAnimation(FolioMotion.ui) {
			stack.append(RouteEntry(route: route))
		}
	}

	func pop() {
		guard !stack.isEmpty else { return }
		withAnimation(FolioMotion.ui) {
			_ = stack.removeLast()
		}
	}

	func popToRoot() {
		withAnimation(FolioMotion.ui) {
			stack.removeAll()
		}
	}

	/// Swaps the visible screen, e.g. Rebuilding → Review, or Camera → Scan.
	func replaceTop(with route: FolioRoute) {
		withAnimation(FolioMotion.ui) {
			if !stack.isEmpty { stack.removeLast() }
			stack.append(RouteEntry(route: route))
		}
	}

	/// Drops any screens showing a scan that was deleted.
	func forget(_ scan: Scan) {
		stack.removeAll { entry in
			switch entry.route {
			case .preview(let s), .scan(let s), .processing(let s), .review(let s), .page(let s, _): return s == scan
			case .camera(_, let s): return s == scan
			case .settings, .collection: return false
			}
		}
	}

	func showToast(_ message: String, actionLabel: String? = nil, action: (() -> Void)? = nil) {
		let next = FolioToast(message: message, actionLabel: actionLabel, action: action)
		withAnimation(FolioMotion.ui) {
			toast = next
		}
		Task { [weak self] in
			do {
				try await Task.sleep(for: .seconds(action == nil ? 2.4 : 4))
			} catch {
				return  // cancelled: leave the toast to the next one
			}
			guard let self, self.toast?.id == next.id else { return }
			withAnimation(FolioMotion.ui) {
				self.toast = nil
			}
		}
	}

	func dismissToast() {
		withAnimation(FolioMotion.ui) {
			toast = nil
		}
	}
}

// MARK: - Device tier

/// What this iPhone can do, from the plan's "Scan modes and device support".
/// Stored token (also accepted as the `deviceTier` launch argument override).
enum DeviceTier: String, CaseIterable {
	/// Apple Intelligence iPhones: handwriting, equations and diagrams.
	case smart
	/// iOS 26: typed pages and tables via Vision's document reader.
	case basic
	/// Everything else: clean, searchable PDFs.
	case pdf

	static var current: DeviceTier {
		if let override = UserDefaults.standard.string(forKey: FolioPreference.deviceTier),
		   let tier = DeviceTier(rawValue: override) {
			return tier
		}
		guard #available(iOS 26.0, *) else { return .pdf }
		return AppleIntelligence.isAvailable ? .smart : .basic
	}

	var canRebuild: Bool { self != .pdf }

	var displayName: String {
		switch self {
		case .smart: return String(localized: "Smart rebuild")
		case .basic: return String(localized: "Basic rebuild")
		case .pdf: return String(localized: "PDF scanner")
		}
	}

	var summary: String {
		switch self {
		case .smart: return String(localized: "This iPhone can rebuild handwriting and whiteboard diagrams into editable files.")
		case .basic: return String(localized: "This iPhone rebuilds typed pages and tables. Diagrams come through as pictures.")
		case .pdf: return String(localized: "This iPhone makes clean, searchable PDFs. Rebuilding needs a newer model.")
		}
	}
}

// MARK: - Preferences

/// UserDefaults keys (stored tokens). Launch arguments override any of them,
/// e.g. `-deviceTier pdf -seedSampleLibrary YES`.
enum FolioPreference {
	static let autoCapture = "autoCapture"
	static let removeShadows = "removeShadows"
	static let keepMarkerColors = "keepMarkerColors"
	static let companionTips = "companionTips"
	static let deviceTier = "deviceTier"
	static let seedSampleLibrary = "seedSampleLibrary"

	static func registerDefaults() {
		UserDefaults.standard.register(defaults: [
			autoCapture: true,
			removeShadows: true,
			keepMarkerColors: true,
			companionTips: true,
		])
	}
}

// MARK: - Sharing

/// Presents the system share sheet from the frontmost view controller.
enum SharePresenter {
	@MainActor
	static func share(_ items: [Any], completion: ((UIActivity.ActivityType?, Bool) -> Void)? = nil) {
		guard let presenter = frontmostViewController() else { return }
		let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
		controller.completionWithItemsHandler = { type, completed, _, _ in
			completion?(type, completed)
		}
		controller.popoverPresentationController?.sourceView = presenter.view
		presenter.present(controller, animated: true)
	}

	@MainActor
	static func frontmostViewController() -> UIViewController? {
		let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
		let window = scenes.flatMap(\.windows).first { $0.isKeyWindow } ?? scenes.first?.windows.first
		var top = window?.rootViewController
		while let presented = top?.presentedViewController {
			top = presented
		}
		return top
	}
}
