//
//  TimelineProvider.swift
//  ScannerWidgetExtension
//
//  Created by Slaven Radic on 2024-09-01.
//


import WidgetKit
import CoreData

struct Provider: TimelineProvider {
	
	var viewContext : NSManagedObjectContext

	init(context : NSManagedObjectContext) {
		self.viewContext = context
	}
	
	func placeholder(in context: Context) -> ScanArrayEntry {
		createEntry()
	}

	func getSnapshot(in context: Context, completion: @escaping (ScanArrayEntry) -> ()) {
		let entry = createEntry()
		completion(entry)
	}

	func getTimeline(in context: Context, completion: @escaping (Timeline<ScanArrayEntry>) -> ()) {
		
		// The view context is main-queue bound; WidgetKit calls this off the main thread.
		viewContext.perform {
			do {
				try viewContext.setQueryGenerationFrom(.current)
			} catch {
				// Without a pinned generation the fetch still works; it may just see a newer snapshot.
				print("Folio widget: couldn't pin the query generation: \(error)")
			}
			viewContext.refreshAllObjects()

			let request = NSFetchRequest<Scan>(entityName: "Scan")
			request.sortDescriptors = [NSSortDescriptor(keyPath: \Scan.order, ascending: true)]
			let scans = (try? viewContext.fetch(request)) ?? []

			let timeline = Timeline(entries: [createEntry(scans)], policy: .atEnd)
			completion(timeline)
		}
	}
	
	func createEntry(_ scans: [Scan] = []) -> ScanArrayEntry {
		
		var entries: [ScanEntry] = []
		if scans.count > 0 {
			for scan in scans {
				let entry = ScanEntry(title: scan.title)
				entries.append(entry)
				if entries.count > 5 {
					break
				}
			}
		} else {
			entries.append(ScanEntry(title: ""))
		}
		return ScanArrayEntry(
			date: Date(),
			entries: entries
		)
	}
}
