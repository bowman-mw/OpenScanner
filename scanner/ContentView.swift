//
//  ContentView.swift
//  Open Scanner → Folio
//
//  Created by Slaven Radic on 2024-09-01.
//  Folio: the Library is the root; every other screen floats in above it.
//

import SwiftUI
import CoreData

struct ContentView: View {
	@Environment(\.managedObjectContext) private var viewContext
	@State private var router = FolioRouter()
	@ObservedObject private var appState = AppState.shared
	@ObservedObject private var navigationManager = NavigationManager.shared

	var body: some View {
		ZStack {
			let covered = !router.stack.isEmpty
			HomeView()
				.opacity(covered ? 0 : 1)
				.allowsHitTesting(!covered)
				.accessibilityHidden(covered)

			ForEach(Array(router.stack.enumerated()), id: \.element.id) { index, entry in
				let isTop = index == router.stack.count - 1
				screen(for: entry.route)
					.opacity(isTop ? 1 : 0)
					.allowsHitTesting(isTop)
					.accessibilityHidden(!isTop)
					.zIndex(Double(index + 1))
					.transition(.floatIn)
			}

			if let toast = router.toast {
				VStack {
					ToastView(message: toast.message, actionLabel: toast.actionLabel, action: toast.action.map { action in
						{
							action()
							router.dismissToast()
						}
					})
					.padding(.top, 8)
					.onTapGesture { router.dismissToast() }
					Spacer()
				}
				.zIndex(100)
				.transition(.floatIn)
			}
		}
		.overlay(alignment: .leading) { edgeSwipeBack }
		.environment(router)
		.preferredColorScheme(router.isCameraVisible ? .dark : .light)
		.onChange(of: appState.openScan) { _, scan in
			// Spotlight result or widget link.
			guard let scan else { return }
			router.popToRoot()
			router.push(.preview(scan))
			appState.openScan = nil
		}
		.onChange(of: appState.viewState) { _, state in
			// "Scan Now" / "Folio settings" from a URL or shortcut.
			guard state != .Home else { return }
			appState.viewState = .Home
			router.popToRoot()
			router.push(state == .Page ? .camera(.document, appendingTo: nil) : .settings)
		}
		.onChange(of: navigationManager.requestedClassicScan) { _, requested in
			guard requested else { return }
			navigationManager.requestedClassicScan = false
			router.popToRoot()
			router.push(.camera(.document, appendingTo: nil))
		}
		.task {
			ScannerShortcuts.updateAppShortcutParameters()
			if UserDefaults.standard.bool(forKey: FolioPreference.seedSampleLibrary) {
				SampleLibrary.seedIfEmpty(in: viewContext)
			}
		}
	}

	@ViewBuilder
	private func screen(for route: FolioRoute) -> some View {
		switch route {
		case .camera(let kind, let scan):
			CaptureView(kind: kind, appendingTo: scan)
		case .preview(let scan):
			ScanPreviewView(scan: scan)
		case .scan(let scan):
			LiveScanSummary(scan: scan)
		case .page(let scan, let capture):
			LiveCaptureSummary(scan: scan, capture: capture)
		case .processing(let scan):
			ProcessingView(scan: scan)
		case .review(let scan):
			ReviewView(scan: scan)
		case .settings:
			SettingsView()
		}
	}

	/// A thin leading strip that pops the screen on a rightward swipe, standing
	/// in for the system back gesture the custom stack doesn't get for free.
	@ViewBuilder
	private var edgeSwipeBack: some View {
		if canSwipeBack {
			Color.clear
				.frame(width: 18)
				.contentShape(Rectangle())
				.gesture(
					DragGesture(minimumDistance: 16)
						.onEnded { value in
							if value.translation.width > 70, abs(value.translation.height) < 80 {
								router.pop()
							}
						}
				)
				.accessibilityHidden(true)
		}
	}

	private var canSwipeBack: Bool {
		switch router.top {
		case .none, .camera, .processing: return false
		default: return true
		}
	}
}

struct ContentView_Previews: PreviewProvider {
	static var previews: some View {
		ContentView().environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
	}
}
