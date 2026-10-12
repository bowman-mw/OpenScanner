//
//  AppIntents.swift
//  Open Scanner
//
//  Created by Slaven Radic on 2024-09-01.
//

import Foundation
import AppIntents
import SwiftUI

struct ClassicScanIntent: AppIntent {
	static let title: LocalizedStringResource = "Scan Document"
	static let description = IntentDescription("Scan a document with Rescriva")
	static let openAppWhenRun: Bool = true

	@MainActor
	func perform() async throws -> some IntentResult {
		NavigationManager.shared.openClassic()
		return .result(dialog: "Okay, starting a scan.")
	}
}

struct OpenAppIntent: AppIntent {
	static let title: LocalizedStringResource = "Open Rescriva"
	static let description = IntentDescription("Run the Rescriva app")
	static let openAppWhenRun: Bool = true

	@MainActor
	func perform() async throws -> some IntentResult {
		NavigationManager.shared.openApp()
		return .result(dialog: "Okay, starting Rescriva.")
	}
}

struct ScannerShortcuts: AppShortcutsProvider {
	static var appShortcuts: [AppShortcut] {
		
		AppShortcut(intent: OpenAppIntent(), phrases: ["\(.applicationName)"], shortTitle: "Open Rescriva", systemImageName: "viewfinder")
		AppShortcut(intent: ClassicScanIntent(), phrases: ["Scan a document with \(.applicationName)", "Scan with \(.applicationName)"], shortTitle: "Scan Document", systemImageName: "doc.viewfinder")
	}
}

