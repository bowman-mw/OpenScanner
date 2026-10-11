//
//  ScannerWidget.swift
//  ScannerWidget
//
//  Created by Slaven Radic on 2024-09-01.
//


import WidgetKit
import SwiftUI
import CoreData

@main
struct ScannerWidgetBundle: WidgetBundle {

	// MARK: - View
	@WidgetBundleBuilder
	var body: some Widget {
		ClassicScanWidget()
	}
}

struct ClassicScanWidget: Widget {
	let persistenceController = PersistenceController.shared
	let kind: String = "ClassicScannerWidget"
	
	var body: some WidgetConfiguration {
		StaticConfiguration(kind: kind, provider: Provider(context: persistenceController.container.viewContext)) { entry in
			ScannerWidgetEntryView(entry: entry, viewState: .Page)
				.environment(\.managedObjectContext, persistenceController.container.viewContext)
				.widgetURL(URL(string: "openscanner://scan/classic"))
		}
		.configurationDisplayName("Document Scanner")
		.description("Open Scanner widget - Document Scanner")
		.supportedFamilies([.systemSmall, .accessoryCircular])
	}
}
