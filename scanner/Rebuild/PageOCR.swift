//
//  PageOCR.swift
//  Folio (fork of Open Scanner)
//
//  Text recognition for a captured page. Replaces Open Scanner's CaptureOcr:
//  same Vision request settings, but it runs off the main thread and keeps
//  what the plan's review screen needs — each line's confidence, Vision's
//  alternative readings and where the line sits on the page.
//

import Foundation
import CoreData
import UIKit
import Vision

/// Captures whose text recognition is still running, so screens can say
/// "Reading…" instead of "No text found".
@MainActor
@Observable
final class RecognitionTracker {
	static let shared = RecognitionTracker()
	private(set) var pending: Set<NSManagedObjectID> = []

	func isReading(_ capture: ScanCapture) -> Bool {
		pending.contains(capture.objectID)
	}

	fileprivate func begin(_ id: NSManagedObjectID) { pending.insert(id) }
	fileprivate func end(_ id: NSManagedObjectID) { pending.remove(id) }
}

/// Vision text recognition for scanned pages.
enum PageOCR {
	/// Recognizes every line on `image`. Runs on a background queue.
	static func recognize(_ image: CGImage) async -> [RecognizedLine] {
		await withCheckedContinuation { continuation in
			DispatchQueue.global(qos: .userInitiated).async {
				let request = VNRecognizeTextRequest()
				request.recognitionLevel = .accurate
				request.automaticallyDetectsLanguage = true
				request.revision = VNRecognizeTextRequestRevision3
				request.usesLanguageCorrection = true
				let handler = VNImageRequestHandler(cgImage: image)
				do {
					try handler.perform([request])
				} catch {
					continuation.resume(returning: [])
					return
				}
				let lines = (request.results ?? []).compactMap { observation -> RecognizedLine? in
					let candidates = observation.topCandidates(3)
					guard let top = candidates.first else { return nil }
					let box = observation.boundingBox
					return RecognizedLine(
						text: top.string,
						confidence: top.confidence,
						alternatives: candidates.dropFirst().map(\.string).filter { $0 != top.string },
						box: CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
					)
				}
				continuation.resume(returning: lines)
			}
		}
	}

	/// Recognizes a page and stores each line as a `ScanRecognizedItem`.
	/// When the scan still carries `placeholderTitle`, the first line that reads
	/// like a title becomes the scan's title (Open Scanner's behaviour).
	@MainActor
	static func process(_ capture: ScanCapture, image: UIImage, placeholderTitle: String? = nil) async {
		guard let cgImage = image.cgImage else { return }
		let context = capture.managedObjectContext ?? PersistenceController.shared.container.viewContext
		if capture.objectID.isTemporaryID {
			do {
				try context.obtainPermanentIDs(for: [capture])
			} catch {
				// Reading still works with a temporary ID; the "Reading…" state just won't match after save.
				print("Folio: couldn't obtain a permanent ID for a page: \(error)")
			}
		}
		let id = capture.objectID
		RecognitionTracker.shared.begin(id)
		let lines = await recognize(cgImage)
		RecognitionTracker.shared.end(id)
		guard !capture.isDeleted, capture.managedObjectContext != nil else { return }
		store(lines, on: capture, in: context)
		if let placeholderTitle, let scan = capture.parent, scan.title == placeholderTitle,
		   let suggestion = lines.lazy.map(\.text).first(where: Self.readsLikeTitle) {
			scan.title = suggestion.whitespaceCondensed().truncate(to: 50)
		}
		capture.parent?.lastUpdate = Date()
		context.saveQuietly()
	}

	/// Replaces a page's recognized items with `lines`, in reading order.
	@MainActor
	static func store(_ lines: [RecognizedLine], on capture: ScanCapture, in context: NSManagedObjectContext) {
		for item in capture.recognizedItemsArray {
			context.delete(item)
		}
		let now = Date()
		for (index, line) in lines.enumerated() {
			let item = ScanRecognizedItem(context: context)
			item.id = UUID()
			item.order = Int32(index)
			item.timestamp = now.addingTimeInterval(Double(index) / 1000)
			item.transcript = line.text
			item.confidence = Double(line.confidence)
			item.alternatives = line.alternatives.isEmpty ? nil : line.alternatives.joined(separator: "\n")
			item.boxX = line.box.minX
			item.boxY = line.box.minY
			item.boxW = line.box.width
			item.boxH = line.box.height
			capture.addToRecognizedItems(item)
		}
	}

	private static func readsLikeTitle(_ text: String) -> Bool {
		let letters = text.filter(\.isLetter).count
		return letters >= 3 && text.count <= 60
	}
}

extension ScanRecognizedItem {
	/// The stored line as a `RecognizedLine`.
	var recognizedLine: RecognizedLine {
		RecognizedLine(
			text: transcript ?? "",
			confidence: Float(confidence),
			alternatives: (alternatives ?? "").split(separator: "\n").map(String.init),
			box: CGRect(x: boxX, y: boxY, width: boxW, height: boxH)
		)
	}
}

extension NSManagedObjectContext {
	/// Saves if there are changes; logs instead of crashing on failure.
	func saveQuietly() {
		guard hasChanges else { return }
		do {
			try save()
		} catch {
			print("Folio: save failed: \(error)")
		}
	}
}
