//
//  scannerApp.swift
//  Open Scanner
//
//  Created by Slaven Radic on 2024-09-01.
//

import SwiftUI
import CoreSpotlight

@main
struct scannerApp: App {
	@Environment(\.scenePhase) var scenePhase
	let persistenceController = PersistenceController.shared
	
	init() {
		FolioPreference.registerDefaults()
		AppState.shared.viewState = .Home
		// Folio: originals staged by an earlier run whose pages were never saved. Here rather than
		// in a view's task, which a second window would run again mid-session.
		OriginalStore.sweepStagingAtLaunch()
		// Quick Look's copies of pages, from an earlier run (and Documents, where older versions kept them).
		QuickLookCopy.sweepAtLaunch()
	}
	
	var body: some Scene {
		WindowGroup {
			ContentView()
				.environment(\.managedObjectContext, persistenceController.container.viewContext)
				.onContinueUserActivity(CSSearchableItemActionType, perform: handleSpotlight)
				.onOpenURL { url in
					if url.absoluteString.contains("scan") {
						AppState.shared.viewState = .Page
					}
				}
		}
		.onChange(of: scenePhase) { _, newPhase in
			if newPhase == .inactive || newPhase == .background {
				saveAppState()
			}
		}
	}
	
	func handleSpotlight(_ userActivity: NSUserActivity) {
		if let id = userActivity.userInfo?[CSSearchableItemActivityIdentifier] as? String {
			if let uri = URL(string: id) {
				if let scan = persistenceController.scanFromUri(uri) {
					AppState.shared.openScan = scan
				} else if let recognizedItem = persistenceController.recognizedItemFromUri(uri) {
					AppState.shared.openScan = recognizedItem.parent?.parent
				}
			}
		}
	}
	
	func saveAppState() {
		persistenceController.container.viewContext.saveQuietly()
	}
}

