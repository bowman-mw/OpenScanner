//
//  Persistence.swift
//  Open Scanner
//
//  Created by Slaven Radic on 2024-09-01.
//

import CoreData

struct PersistenceController {
	static let shared = PersistenceController()
	
	private(set) var spotlightIndexer: NSCoreDataCoreSpotlightDelegate?
	
	let container: NSPersistentCloudKitContainer
	/// Why the library on this device couldn't be opened, when the app is running on a temporary
	/// in-memory one instead (nothing made now is kept). The app warns about it (ContentView).
	private(set) var loadFailure: Error?
	
	init(inMemory: Bool = false) {
		container = NSPersistentCloudKitContainer(name: "scanner")
		
		guard let description = container.persistentStoreDescriptions.first else {
			// NSPersistentContainer always creates a default description; without one there is nothing to load.
			print("Rescriva: no persistent store description")
			return
		}
		
		description.type = NSSQLiteStoreType
		description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
		description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
		// New model versions (scanner.xcdatamodeld) only add optional attributes, relationships
		// and entities, so the existing store upgrades in place with an inferred mapping: version 4
		// is the library (3) plus the page recipe (2), and stores on 1, 2 or 3 all reach it.
		description.shouldMigrateStoreAutomatically = true
		description.shouldInferMappingModelAutomatically = true
		
		if inMemory {
			// Preview and in memory experiments
			description.url = URL(fileURLWithPath: "/dev/null")
			description.cloudKitContainerOptions = nil
		}
		
		loadFailure = Self.loadFallingBackToMemory(container)
		
		spotlightIndexer = NSCoreDataCoreSpotlightDelegate(
			forStoreWith: description,
			coordinator: container.persistentStoreCoordinator
		)
		spotlightIndexer?.startSpotlightIndexing()
		
		if !inMemory {
			// Permanent store options
			container.viewContext.automaticallyMergesChangesFromParent = true
			container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
		}
	}
	
	func scanFromUri(_ uri: URL) -> Scan? {
		guard let objectID = container.viewContext.persistentStoreCoordinator?.managedObjectID(forURIRepresentation: uri)
		else {
			return nil
		}
		return container.viewContext.object(with: objectID) as? Scan
	}
	
	/// Loads the container's store. If it can't be opened, the app runs on a temporary in-memory
	/// store instead of crashing, and this returns why. The file on disk is left as it was.
	static func loadFallingBackToMemory(_ container: NSPersistentContainer) -> Error? {
		guard let error = loadStores(of: container) else { return nil }
		print("Rescriva: the library store failed to load (\(error)); using a temporary in-memory store")
		guard let description = container.persistentStoreDescriptions.first else { return error }
		description.url = URL(fileURLWithPath: "/dev/null")
		description.cloudKitContainerOptions = nil
		if let second = loadStores(of: container) {
			print("Rescriva: the in-memory store failed too: \(second)")
		}
		return error
	}

	/// Loads the container's stores (synchronously, the default) and returns the first error.
	private static func loadStores(of container: NSPersistentContainer) -> Error? {
		let result = LoadResult()
		container.loadPersistentStores { _, error in
			if let error, result.error == nil {
				result.error = error
			}
		}
		return result.error
	}

	/// Collects a store-loading error from Core Data's callback.
	private final class LoadResult {
		var error: Error?
	}

	func recognizedItemFromUri(_ uri: URL) -> ScanRecognizedItem? {
		guard let objectID = container.viewContext.persistentStoreCoordinator?.managedObjectID(forURIRepresentation: uri)
		else {
			return nil
		}
		return container.viewContext.object(with: objectID) as? ScanRecognizedItem
	}
	
	static let preview: PersistenceController = {
		let result = PersistenceController(inMemory: true)
		let viewContext = result.container.viewContext
		for _ in 0..<2 {
			let newScan = Scan(context: viewContext)
			newScan.timestamp = Date()
			for _ in 0..<4 {
				let newPage = ScanCapture(context: viewContext)
				newPage.timestamp = Date()
				for index in 0..<3 {
					let newItem = ScanRecognizedItem(context: viewContext)
					newItem.timestamp = Date()
					newItem.transcript = "Transcript \(index)"
				}
			}
		}
		do {
			try viewContext.save()
		} catch {
			print("Rescriva: preview store save failed: \(error)")
		}
		return result
	}()
	
}
