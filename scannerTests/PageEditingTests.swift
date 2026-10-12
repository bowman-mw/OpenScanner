//
//  PageEditingTests.swift
//  Folio (fork of Open Scanner)
//
//  Non-destructive pages: the crop editor's geometry, the originals kept on
//  disk, re-processing and what it invalidates, the editor's session model,
//  and the model versions: the recipe (version 2) on top of the library
//  (version 3) in version 4, and libraries on 1, 2 or 3 migrating to it.
//

import CoreData
import CoreImage
import UIKit
import XCTest
@testable import scanner

@MainActor
final class PageEditingTests: XCTestCase {

	/// A centred square crop.
	private let square = PageQuad(
		topLeft: CGPoint(x: 0.2, y: 0.2),
		topRight: CGPoint(x: 0.8, y: 0.2),
		bottomRight: CGPoint(x: 0.8, y: 0.8),
		bottomLeft: CGPoint(x: 0.2, y: 0.8)
	)

	/// In-memory containers kept alive for the test's contexts.
	private var containers: [NSPersistentContainer] = []

	override func tearDown() {
		containers.removeAll()
		super.tearDown()
	}

	// MARK: Storage and geometry

	func testQuadStorageRoundTripsAndRejectsJunk() throws {
		let quad = PageQuad(topLeft: CGPoint(x: 0.01234, y: 0.1), topRight: CGPoint(x: 0.9, y: 0.05),
							bottomRight: CGPoint(x: 0.95, y: 0.91), bottomLeft: CGPoint(x: 0.04, y: 0.88))
		let decoded = try XCTUnwrap(PageQuad(storageString: quad.storageString))
		XCTAssertEqual(decoded.maxCornerDistance(to: quad), 0, accuracy: 1e-5)
		XCTAssertNil(PageQuad(storageString: ""))
		XCTAssertNil(PageQuad(storageString: "0,0;1,0;1,1"))
		XCTAssertNil(PageQuad(storageString: "0,0;1,0;1,1;0,x"))
		XCTAssertNil(PageQuad(storageString: "0,0;1,0;1,1;0,nan"))
	}

	func testATouchGrabsTheNearestCornerMidpointOrMiddle() {
		let corners = [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 100), CGPoint(x: 0, y: 100)]
		XCTAssertEqual(QuadEditing.nearestHandle(to: CGPoint(x: 5, y: 3), corners: corners), .corner(0))
		XCTAssertEqual(QuadEditing.nearestHandle(to: CGPoint(x: 97, y: 96), corners: corners), .corner(2))
		XCTAssertEqual(QuadEditing.nearestHandle(to: CGPoint(x: 52, y: 4), corners: corners), .edge(0))
		XCTAssertEqual(QuadEditing.nearestHandle(to: CGPoint(x: 104, y: 48), corners: corners), .edge(1))
		XCTAssertEqual(QuadEditing.nearestHandle(to: CGPoint(x: 55, y: 45), corners: corners), .body)
	}

	func testACornerMovesAloneAndSlidesAlongTheBorder() throws {
		let moved = try XCTUnwrap(QuadEditing.moved(square, handle: .corner(0), by: CGVector(dx: -0.5, dy: -0.1)))
		XCTAssertEqual(moved.topLeft.x, 0, accuracy: 1e-9)
		XCTAssertEqual(moved.topLeft.y, 0.1, accuracy: 1e-9)
		XCTAssertEqual(moved.topRight, square.topRight)
		XCTAssertEqual(moved.bottomRight, square.bottomRight)
		XCTAssertEqual(moved.bottomLeft, square.bottomLeft)
	}

	func testAnEdgeMovesBothItsCornersAndStopsAtTheBorder() throws {
		let moved = try XCTUnwrap(QuadEditing.moved(square, handle: .edge(1), by: CGVector(dx: 0.5, dy: 0.05)))
		XCTAssertEqual(moved.topRight.x, 1, accuracy: 1e-9)
		XCTAssertEqual(moved.bottomRight.x, 1, accuracy: 1e-9)
		XCTAssertEqual(moved.topRight.y, 0.25, accuracy: 1e-9)
		XCTAssertEqual(moved.bottomRight.y, 0.85, accuracy: 1e-9)
		XCTAssertEqual(moved.topLeft, square.topLeft)
		XCTAssertEqual(moved.bottomLeft, square.bottomLeft)
	}

	func testTheMiddleMovesTheWholeCropWithoutChangingItsShape() throws {
		let moved = try XCTUnwrap(QuadEditing.moved(square, handle: .body, by: CGVector(dx: 0.5, dy: -0.05)))
		XCTAssertEqual(moved.topLeft.x, 0.4, accuracy: 1e-9)
		XCTAssertEqual(moved.topLeft.y, 0.15, accuracy: 1e-9)
		XCTAssertEqual(moved.bottomRight.x, 1, accuracy: 1e-9)
		XCTAssertEqual(moved.area, square.area, accuracy: 1e-9)
	}

	func testMovesThatFoldShrinkOrLeaveThePhotoAreRefused() {
		// Top-left pushed inside the crop: concave.
		XCTAssertNil(QuadEditing.moved(square, handle: .corner(0), by: CGVector(dx: 0.5, dy: 0.5)))
		// Top edge dragged onto the bottom edge: collapsed.
		XCTAssertNil(QuadEditing.moved(square, handle: .edge(0), by: CGVector(dx: 0, dy: 0.6)))
		// A sliver below the minimum area.
		XCTAssertNil(QuadEditing.moved(square, handle: .edge(0), by: CGVector(dx: 0, dy: 0.59)))
		XCTAssertNil(QuadEditing.moved(square, handle: .body, by: CGVector(dx: CGFloat.nan, dy: 0)))
		// An edge dragged past the opposite edge in one step: convex and big enough, but inside out.
		XCTAssertNil(QuadEditing.moved(square, handle: .edge(0), by: CGVector(dx: 0, dy: 0.7)))
		XCTAssertNil(QuadEditing.moved(square, handle: .edge(0), by: CGVector(dx: 0, dy: 0.75)))
		XCTAssertNil(QuadEditing.moved(square, handle: .edge(3), by: CGVector(dx: 0.75, dy: 0)))
		let mirrored = PageQuad(topLeft: square.topRight, topRight: square.topLeft,
								bottomRight: square.bottomLeft, bottomLeft: square.bottomRight)
		XCTAssertTrue(mirrored.isConvex)
		XCTAssertFalse(QuadEditing.isClockwise(mirrored))
		XCTAssertFalse(QuadEditing.isAcceptable(mirrored))
		XCTAssertTrue(QuadEditing.isClockwise(square))
		let outside = PageQuad(topLeft: CGPoint(x: -0.1, y: 0), topRight: CGPoint(x: 1, y: 0),
							   bottomRight: CGPoint(x: 1, y: 1), bottomLeft: CGPoint(x: 0, y: 1))
		XCTAssertFalse(QuadEditing.isAcceptable(outside))
		XCTAssertTrue(QuadEditing.isAcceptable(QuadEditing.clamped(outside)))
		XCTAssertTrue(QuadEditing.isAcceptable(.fullFrame))
	}

	func testViewMappingRoundTripsAtEveryRotation() {
		let imageSize = CGSize(width: 4000, height: 3000)
		let bounds = CGRect(x: 10, y: 20, width: 300, height: 500)
		let point = CGPoint(x: 0.3, y: 0.7)
		for turns in -1...4 {
			let mapping = QuadViewMapping(imageSize: imageSize, quarterTurns: turns, fittingIn: bounds)
			let back = mapping.normalizedPoint(mapping.viewPoint(point))
			XCTAssertEqual(back.x, point.x, accuracy: 1e-9, "turns \(turns)")
			XCTAssertEqual(back.y, point.y, accuracy: 1e-9, "turns \(turns)")
			XCTAssertTrue(bounds.insetBy(dx: -0.001, dy: -0.001).contains(mapping.frame), "turns \(turns)")
		}
	}

	func testAQuarterTurnPutsTheTopLeftAtTheTopRight() {
		let mapping = QuadViewMapping(imageSize: CGSize(width: 400, height: 300), quarterTurns: 1,
									  fittingIn: CGRect(x: 0, y: 0, width: 300, height: 400))
		XCTAssertEqual(mapping.frame, CGRect(x: 0, y: 0, width: 300, height: 400))
		let topLeft = mapping.viewPoint(.zero)
		XCTAssertEqual(topLeft.x, 300, accuracy: 1e-9)
		XCTAssertEqual(topLeft.y, 0, accuracy: 1e-9)
		// Turned clockwise, the original's top faces right: a drag right moves up the original.
		let right = mapping.normalizedDelta(CGSize(width: 30, height: 0))
		XCTAssertEqual(right.dx, 0, accuracy: 1e-9)
		XCTAssertEqual(right.dy, -0.1, accuracy: 1e-9)
		let down = mapping.normalizedDelta(CGSize(width: 0, height: 40))
		XCTAssertEqual(down.dx, 0.1, accuracy: 1e-9)
		XCTAssertEqual(down.dy, 0, accuracy: 1e-9)
	}

	func testAspectFitCentresAndRotationSwapsTheSize() {
		let frame = QuadViewMapping.aspectFit(CGSize(width: 200, height: 100), in: CGRect(x: 0, y: 0, width: 100, height: 100))
		XCTAssertEqual(frame, CGRect(x: 0, y: 25, width: 100, height: 50))
		XCTAssertEqual(QuadViewMapping.rotatedSize(CGSize(width: 4, height: 3), quarterTurns: 3), CGSize(width: 3, height: 4))
		XCTAssertEqual(QuadViewMapping.rotatedSize(CGSize(width: 4, height: 3), quarterTurns: 2), CGSize(width: 4, height: 3))
	}

	func testHandleNamesFollowTheRotation() {
		XCTAssertEqual(QuarterTurns.normalized(-1), 3)
		XCTAssertEqual(QuarterTurns.normalized(5), 1)
		XCTAssertEqual(QuadEditing.visualIndex(0, quarterTurns: 1), 1)
		XCTAssertEqual(QuadEditing.visualIndex(3, quarterTurns: 1), 0)
		XCTAssertEqual(QuadEditing.visualIndex(2, quarterTurns: -1), 1)
		XCTAssertEqual(PageEditorLabels.handle(.corner(0), quarterTurns: 0), "Top-left corner")
		XCTAssertEqual(PageEditorLabels.handle(.corner(0), quarterTurns: 1), "Top-right corner")
		XCTAssertEqual(PageEditorLabels.handle(.edge(0), quarterTurns: 3), "Left edge")
		XCTAssertEqual(PageEditorLabels.handle(.body, quarterTurns: 2), "Crop area")
	}

	func testTheLoupeSitsAboveTheFingerOrBesideItNearTheTop() {
		let bounds = CGSize(width: 390, height: 600)
		XCTAssertEqual(LoupePlacement.center(touch: CGPoint(x: 200, y: 400), diameter: 100, gap: 40, in: bounds),
					   CGPoint(x: 200, y: 310))
		// No room above: beside the finger, on the roomier side.
		XCTAssertEqual(LoupePlacement.center(touch: CGPoint(x: 300, y: 60), diameter: 100, gap: 40, in: bounds),
					   CGPoint(x: 210, y: 60))
		XCTAssertEqual(LoupePlacement.center(touch: CGPoint(x: 10, y: 10), diameter: 100, gap: 40, in: bounds),
					   CGPoint(x: 100, y: 50))
	}

	func testHistoryUndoesRedoesAndForgetsTheOldest() {
		var history = EditHistory<Int>(limit: 3)
		var state = 0
		for next in 1...4 {
			history.record(state)
			state = next
		}
		XCTAssertEqual(history.undoStack, [1, 2, 3])
		state = history.undo(from: state) ?? state
		XCTAssertEqual(state, 3)
		XCTAssertTrue(history.canRedo)
		state = history.redo(from: state) ?? state
		XCTAssertEqual(state, 4)
		state = history.undo(from: state) ?? state
		history.record(state)
		state = 9
		XCTAssertFalse(history.canRedo, "a new edit clears redo")
		var empty = EditHistory<Int>()
		XCTAssertNil(empty.undo(from: 0))
		XCTAssertNil(empty.redo(from: 0))
	}

	// MARK: Originals

	func testOriginalsSaveLoadAndDelete() throws {
		let store = makeStore()
		let id = UUID()
		let encoded = try XCTUnwrap(OriginalStore.encode(CIImage(cgImage: try makeImage(width: 64, height: 48))))
		XCTAssertFalse(store.contains(id))
		try store.save(encoded, for: id)
		XCTAssertTrue(store.contains(id))
		let loaded = try XCTUnwrap(store.loadImage(for: id))
		XCTAssertEqual(loaded.width, 64)
		XCTAssertEqual(loaded.height, 48)
		XCTAssertEqual(store.usage().count, 1)
		XCTAssertGreaterThan(store.usage().bytes, 0)
		store.remove(id)
		XCTAssertFalse(store.contains(id))
		XCTAssertNil(store.loadImage(for: id))
		XCTAssertEqual(store.usage(), OriginalStore.Usage(count: 0, bytes: 0))
	}

	func testOriginalsAreCappedAt4032Pixels() throws {
		let store = makeStore()
		let id = UUID()
		let wide = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 6048, height: 1000))
		try store.save(try XCTUnwrap(OriginalStore.encode(wide)), for: id)
		let loaded = try XCTUnwrap(store.loadImage(for: id))
		XCTAssertEqual(loaded.width, 4032)
		XCTAssertEqual(loaded.height, 666, accuracy: 1)
	}

	func testPruningKeepsLivePagesAndFilesBeingWritten() throws {
		let store = makeStore()
		let encoded = try XCTUnwrap(OriginalStore.encode(CIImage(cgImage: try makeImage(width: 32, height: 32))))
		let kept = UUID()
		let orphan = UUID()
		try store.save(encoded, for: kept)
		try store.save(encoded, for: orphan)
		XCTAssertEqual(store.pruneOrphans(keeping: [kept, orphan], olderThan: Date().addingTimeInterval(60)), 0)
		XCTAssertEqual(store.pruneOrphans(keeping: [kept], olderThan: Date().addingTimeInterval(-60)), 0, "too new to prune")
		XCTAssertEqual(store.pruneOrphans(keeping: [kept], olderThan: Date().addingTimeInterval(60)), 1)
		XCTAssertTrue(store.contains(kept))
		XCTAssertFalse(store.contains(orphan))
		XCTAssertEqual(store.removeAll(), 1)
		XCTAssertFalse(store.contains(kept))
	}

	func testPruningSkipsALibraryThatEmptiedAtOnce() throws {
		// Signing out of iCloud empties the local mirror; the pages come back under the same ids.
		let store = makeStore()
		let encoded = try XCTUnwrap(OriginalStore.encode(CIImage(cgImage: try makeImage(width: 32, height: 32))))
		let ids = [UUID(), UUID(), UUID()]
		for id in ids {
			try store.save(encoded, for: id)
		}
		let later = Date().addingTimeInterval(60)
		XCTAssertEqual(store.pruneOrphans(keeping: [], olderThan: later), 0)
		XCTAssertEqual(store.pruneOrphans(keeping: [ids[0]], olderThan: later), 0, "two of three would go")
		XCTAssertEqual(store.usage().count, 3)
		XCTAssertEqual(store.pruneOrphans(keeping: [ids[0], ids[1]], olderThan: later), 1)
		XCTAssertFalse(store.contains(ids[2]))
	}

	func testDeletingAScanDeletesItsPagesAndTheirOriginals() throws {
		let context = try makeContext()
		let store = makeStore()
		let (annotations, marksFolder) = makeAnnotationStore()
		let encoded = try XCTUnwrap(OriginalStore.encode(CIImage(cgImage: try makeImage(width: 32, height: 32))))
		let scan = try insert(Scan.self, "Scan", into: context)
		var ids: [UUID] = []
		for index in 0..<2 {
			let capture = try insert(ScanCapture.self, "ScanCapture", into: context)
			let id = UUID()
			capture.id = id
			// Distinct orders, so capturesArray (sorted by order) puts ids[0] first.
			capture.order = Int32(index)
			scan.addToCaptures(capture)
			let line = try insert(ScanRecognizedItem.self, "ScanRecognizedItem", into: context)
			line.transcript = "Page \(index + 1)"
			capture.addToRecognizedItems(line)
			try store.save(encoded, for: id)
			try annotations.save([sampleMark()], for: id)
			ids.append(id)
		}
		try context.save()
		let lines = NSFetchRequest<NSManagedObject>(entityName: "ScanRecognizedItem")

		XCTAssertEqual(scan.capturesArray.first?.id, ids[0])
		let pageFiles = scan.capturesArray[0].deleteWithOriginal(originals: store, annotations: annotations)
		XCTAssertTrue(store.contains(ids[0]), "the files wait for the deletion to be saved")
		XCTAssertTrue(context.saveDeletion(removing: pageFiles))
		XCTAssertFalse(store.contains(ids[0]))
		XCTAssertTrue(store.contains(ids[1]))
		XCTAssertFalse(hasMarksFile(ids[0], in: marksFolder), "a page deleted for good takes its marks")
		XCTAssertTrue(hasMarksFile(ids[1], in: marksFolder))
		XCTAssertEqual(try context.count(for: lines), 1, "the page's recognized lines go with it")
		XCTAssertTrue(context.saveDeletion(removing: scan.deleteWithPages(originals: store, annotations: annotations)))
		XCTAssertEqual(store.usage().count, 0)
		XCTAssertFalse(hasMarksFile(ids[1], in: marksFolder))
		XCTAssertTrue(AnnotationStore(folder: marksFolder).marks(for: ids[1]).isEmpty)
		XCTAssertEqual(try context.count(for: NSFetchRequest<NSManagedObject>(entityName: "ScanCapture")), 0)
		XCTAssertEqual(try context.count(for: NSFetchRequest<NSManagedObject>(entityName: "Scan")), 0)
		XCTAssertEqual(try context.count(for: lines), 0, "no orphaned lines left for Spotlight or iCloud")
	}

	func testRecentlyDeletedKeepsEveryFileUntilThePurgeTakesThemAll() async throws {
		let context = try makeLibraryOnDisk()
		let originals = makeStore(), figures = makeFigureStore()
		let (annotations, marksFolder) = makeAnnotationStore()
		let (scan, capture) = try makeScanWithPage(in: context)
		let scanID = try XCTUnwrap(scan.id), pageID = try XCTUnwrap(capture.id), orphanID = UUID()
		let encoded = try XCTUnwrap(OriginalStore.encode(CIImage(cgImage: try makeImage(width: 32, height: 32))))
		for id in [pageID, orphanID] {
			try originals.save(encoded, for: id)
			// Old enough for the launch-time cleanup, which spares files written in the last hour.
			let url = try XCTUnwrap(originals.url(for: id))
			try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-7200)], ofItemAtPath: url.path)
		}
		let assetID = UUID().uuidString
		try figures.save(Data([1]), for: assetID, scanID: scanID)
		try annotations.save([sampleMark()], for: pageID)
		let lines = NSFetchRequest<NSManagedObject>(entityName: "ScanRecognizedItem")

		Library.moveToRecentlyDeleted([scan], in: context)
		await OriginalStore.pruneOrphans(in: context, store: originals)
		await FigureAssets.pruneOrphans(in: context, store: figures)
		XCTAssertTrue(originals.contains(pageID), "a scan in Recently Deleted counts as still here, to come back whole")
		XCTAssertFalse(originals.contains(orphanID), "the cleanup itself ran")
		XCTAssertNotNil(figures.data(for: assetID, scanID: scanID))
		XCTAssertTrue(hasMarksFile(pageID, in: marksFolder), "moving to Recently Deleted keeps the marks")
		XCTAssertEqual(try context.count(for: lines), 2)

		Library.purge([scan], in: context, originals: originals, figures: figures, annotations: annotations)
		XCTAssertFalse(originals.contains(pageID))
		XCTAssertNil(figures.data(for: assetID, scanID: scanID))
		XCTAssertFalse(hasMarksFile(pageID, in: marksFolder), "the purge takes the marks")
		XCTAssertEqual(try context.count(for: NSFetchRequest<NSManagedObject>(entityName: "Scan")), 0)
		XCTAssertEqual(try context.count(for: NSFetchRequest<NSManagedObject>(entityName: "ScanCapture")), 0)
		XCTAssertEqual(try context.count(for: lines), 0)
		XCTAssertFalse(context.hasChanges, "saved")
		try closeLibrary(context)
	}

	func testAPurgeThatCannotBeSavedIsUndoneAndKeepsEveryFile() throws {
		let context = try makeFailingContext()
		let originals = makeStore(), figures = makeFigureStore()
		let (annotations, marksFolder) = makeAnnotationStore()
		let (scan, capture) = try makeScanWithPage(in: context)
		let scanID = try XCTUnwrap(scan.id), pageID = try XCTUnwrap(capture.id)
		try context.save()
		try originals.save(try XCTUnwrap(OriginalStore.encode(CIImage(cgImage: try makeImage(width: 32, height: 32)))), for: pageID)
		let assetID = UUID().uuidString
		try figures.save(Data([1]), for: assetID, scanID: scanID)
		try annotations.save([sampleMark()], for: pageID)
		try QuickLookCopy.prepareDirectory()
		let preview = QuickLookCopy.url(for: pageID)
		try Data([1]).write(to: preview)
		addTeardownBlock { try? FileManager.default.removeItem(at: preview) }

		// As on a full disk: the deletion can't be written.
		context.failsSaves = true
		Library.purge([scan], in: context, originals: originals, figures: figures, annotations: annotations)
		XCTAssertFalse(scan.isDeleted, "the purge is undone, so the scan stays in the library")
		XCTAssertFalse(context.hasChanges)
		XCTAssertEqual(try context.count(for: NSFetchRequest<NSManagedObject>(entityName: "ScanCapture")), 1)
		XCTAssertTrue(originals.contains(pageID), "it keeps its original")
		XCTAssertNotNil(figures.data(for: assetID, scanID: scanID), "and its figures")
		XCTAssertTrue(hasMarksFile(pageID, in: marksFolder), "and its marks")
		XCTAssertTrue(FileManager.default.fileExists(atPath: preview.path))

		context.failsSaves = false
		Library.purge([scan], in: context, originals: originals, figures: figures, annotations: annotations)
		XCTAssertEqual(try context.count(for: NSFetchRequest<NSManagedObject>(entityName: "Scan")), 0)
		XCTAssertFalse(originals.contains(pageID), "saved, the files go")
		XCTAssertNil(figures.data(for: assetID, scanID: scanID))
		XCTAssertFalse(hasMarksFile(pageID, in: marksFolder))
		XCTAssertFalse(FileManager.default.fileExists(atPath: preview.path), "and so does its Quick Look copy")
	}

	func testQuickLookCopiesAreSweptButNothingElse() throws {
		let folder = try makeTemporaryFolder("FolioQuickLook"), documents = try makeTemporaryFolder("FolioDocuments")
		let page = UUID()
		let copies = [QuickLookCopy.url(for: page, in: folder), QuickLookCopy.url(for: UUID(), in: documents),
					  QuickLookCopy.url(for: nil, in: documents)]
		let others = [documents.appendingPathComponent("Notes.jpg"), documents.appendingPathComponent("\(UUID().uuidString).json")]
		for url in copies + others {
			try Data([1]).write(to: url)
		}

		QuickLookCopy.remove(for: page, from: [folder, documents])
		XCTAssertFalse(FileManager.default.fileExists(atPath: copies[0].path), "a page's copy goes with it")
		XCTAssertEqual(QuickLookCopy.sweep([folder, documents], before: Date().addingTimeInterval(-60)), 0,
					   "a copy written since the cutoff is being previewed")
		XCTAssertEqual(QuickLookCopy.sweep([folder, documents], before: Date().addingTimeInterval(60)), 2)
		XCTAssertFalse(copies.contains { FileManager.default.fileExists(atPath: $0.path) })
		XCTAssertTrue(others.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }, "only copies are swept")
	}

	func testRecoveringAScanFromRecentlyDeletedBringsBackEveryFile() async throws {
		let context = try makeLibraryOnDisk()
		let originals = makeStore(), figures = makeFigureStore()
		let (annotations, marksFolder) = makeAnnotationStore()
		let pdfs = try makePDFOriginalsFolder()
		let (scan, capture) = try makeScanWithPage(in: context)
		let (other, _) = try makeScanWithPage(in: context)
		let scanID = try XCTUnwrap(scan.id), pageID = try XCTUnwrap(capture.id)
		let encoded = try XCTUnwrap(OriginalStore.encode(CIImage(cgImage: try makeImage(width: 32, height: 32))))
		try originals.save(encoded, for: pageID)
		let original = try XCTUnwrap(originals.url(for: pageID))
		try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-7200)], ofItemAtPath: original.path)
		let assetID = UUID().uuidString
		try figures.save(Data([1]), for: assetID, scanID: scanID)
		try annotations.save([sampleMark()], for: pageID)
		// The scan's PDF, a live scan's and one whose scan was deleted on another device.
		let pdf = try keepPDF(for: scanID, in: pdfs)
		let otherPDF = try keepPDF(for: try XCTUnwrap(other.id), in: pdfs)
		let orphanPDF = try keepPDF(for: UUID(), in: pdfs)

		Library.moveToRecentlyDeleted([scan], in: context)
		await OriginalStore.pruneOrphans(in: context, store: originals)
		await FigureAssets.pruneOrphans(in: context, store: figures)
		await PDFImport.pruneOriginals(in: context, directory: pdfs)
		XCTAssertFalse(FileManager.default.fileExists(atPath: orphanPDF.path), "the PDF cleanup itself ran")
		XCTAssertTrue(FileManager.default.fileExists(atPath: otherPDF.path))

		Library.recover([scan], in: context)
		XCTAssertNil(scan.deletedAt)
		XCTAssertTrue(capture.canReprocess(originals: originals), "its original is back for Adjust page")
		XCTAssertNotNil(figures.data(for: assetID, scanID: scanID))
		XCTAssertEqual(AnnotationStore(folder: marksFolder).marks(for: pageID), [sampleMark()])
		XCTAssertTrue(FileManager.default.fileExists(atPath: pdf.path), "View original still has its PDF")
		XCTAssertEqual(capture.recognizedItemsArray.count, 2)
		try closeLibrary(context)
	}

	func testSettingsCountsAndRemovesKeptPDFsBesidePageOriginals() throws {
		let pdfs = try makePDFOriginalsFolder()
		XCTAssertEqual(PDFImport.originalsUsage(in: pdfs), OriginalStore.Usage(count: 0, bytes: 0))
		let first = try keepPDF(for: UUID(), in: pdfs)
		let second = try keepPDF(for: UUID(), in: pdfs)
		// Not a scan's folder: neither counted nor removed.
		let stray = pdfs.appendingPathComponent("Staging", isDirectory: true)
		try FileManager.default.createDirectory(at: stray, withIntermediateDirectories: true)
		try Data("%PDF-1.4".utf8).write(to: stray.appendingPathComponent("Loose.pdf"))

		let usage = PDFImport.originalsUsage(in: pdfs)
		XCTAssertEqual(usage.count, 2)
		XCTAssertEqual(usage.bytes, Int64(2 * "%PDF-1.4".utf8.count))

		XCTAssertEqual(PDFImport.removeAllOriginals(in: pdfs), 2)
		XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
		XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
		XCTAssertTrue(FileManager.default.fileExists(atPath: stray.path), "only scan folders go")
		XCTAssertEqual(PDFImport.originalsUsage(in: pdfs).count, 0)
	}

	// MARK: Staging

	func testAStagedOriginalIsAFileUntilItsPageKeepsIt() throws {
		let store = makeStore()
		let staged = try XCTUnwrap(store.stage(CIImage(cgImage: try makeImage(width: 64, height: 48))))
		XCTAssertEqual(staged.url.deletingLastPathComponent().standardizedFileURL, store.stagingDirectory.standardizedFileURL)
		XCTAssertTrue(FileManager.default.fileExists(atPath: staged.url.path))
		XCTAssertEqual(store.usage().count, 0, "a staged original isn't one of the store's yet")

		// Staged long ago (a long camera session), kept now.
		try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-7200)], ofItemAtPath: staged.url.path)
		let id = UUID()
		try store.keep(staged, for: id)
		XCTAssertFalse(FileManager.default.fileExists(atPath: staged.url.path), "moved, not copied")
		XCTAssertTrue(store.contains(id))
		let loaded = try XCTUnwrap(store.loadImage(for: id))
		XCTAssertEqual(loaded.width, 64)
		XCTAssertEqual(store.usage().count, 1)
		XCTAssertEqual(store.pruneOrphans(keeping: [], olderThan: Date().addingTimeInterval(-60)), 0,
					   "a kept original counts as new, so the orphan cleanup spares it")
	}

	func testAppendingPagesMovesTheirStagedOriginalsIntoPlace() async throws {
		let context = try makeContext()
		let store = makeStore()
		let scan = try insert(Scan.self, "Scan", into: context)
		scan.id = UUID()
		let staged = try XCTUnwrap(store.stage(CIImage(cgImage: try makeImage(width: 40, height: 30))))
		let recipe = PageRecipe(quad: .fullFrame, mode: nil, rotation: 0, removeShadows: true, keepMarkerColors: true)
		let pages = [CapturedPage(image: UIImage(cgImage: try makeImage(width: 40, height: 30)), original: staged, recipe: recipe),
					 CapturedPage(image: UIImage(cgImage: try makeImage(width: 40, height: 30)))]

		scan.append(pages, in: context, originals: store)

		let captures = scan.capturesArray
		XCTAssertEqual(captures.count, 2)
		let id = try XCTUnwrap(captures.first?.id)
		XCTAssertTrue(store.contains(id), "in place by the time the page is saved")
		XCTAssertFalse(FileManager.default.fileExists(atPath: staged.url.path))
		XCTAssertFalse(store.contains(try XCTUnwrap(captures.last?.id)), "a page without an original gets none")
		XCTAssertEqual(store.usage().count, 1)
	}

	func testUnsavedStagedOriginalsAreDiscardedAndLeftoversSweptAtLaunch() throws {
		let store = makeStore()
		let encoded = try XCTUnwrap(OriginalStore.encode(CIImage(cgImage: try makeImage(width: 32, height: 32))))
		let dropped = try store.stage(encoded)
		let leftovers = [try store.stage(encoded), try store.stage(encoded)]

		store.discard([dropped])
		XCTAssertFalse(FileManager.default.fileExists(atPath: dropped.url.path))
		store.discard([dropped])  // already gone: harmless

		XCTAssertEqual(store.sweepStaging(before: Date().addingTimeInterval(-60)), 0, "staged during this run")
		XCTAssertTrue(leftovers.allSatisfy { FileManager.default.fileExists(atPath: $0.url.path) })
		XCTAssertEqual(store.sweepStaging(before: Date().addingTimeInterval(60)), 2)
		XCTAssertFalse(leftovers.contains { FileManager.default.fileExists(atPath: $0.url.path) })
		XCTAssertEqual(makeStore().sweepStaging(before: Date()), 0, "no staging folder yet")
	}

	func testAnImportedPhotoStagesItsOriginalAsSoonAsItIsPrepared() async throws {
		let store = makeStore()
		let photo = UIImage(cgImage: try makeImage(width: 120, height: 90))
		let kept = await ImportCleanup.prepare(photo, removeShadows: true, keepsOriginal: true, originals: store)
		let staged = try XCTUnwrap(kept.original)
		XCTAssertTrue(FileManager.default.fileExists(atPath: staged.url.path))
		XCTAssertEqual(staged.url.deletingLastPathComponent().standardizedFileURL, store.stagingDirectory.standardizedFileURL)
		XCTAssertNotNil(kept.recipe)

		let unkept = await ImportCleanup.prepare(photo, removeShadows: true, keepsOriginal: false, originals: store)
		XCTAssertNil(unkept.original)
		XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.stagingDirectory.path).count, 1)
	}

	// MARK: Re-processing

	func testRotationTurnsClockwiseAndMatchesTheEditorsDisplay() throws {
		let source = try makeImage(width: 40, height: 20)
		let turned = try XCTUnwrap(PageReprocessor.rotated(source, quarterTurns: 1))
		XCTAssertEqual(turned.width, 20)
		XCTAssertEqual(turned.height, 40)
		// The red marker in the top-left corner ends up top-right.
		XCTAssertTrue(try isRed(turned, x: 18, y: 1))
		XCTAssertFalse(try isRed(turned, x: 1, y: 1))

		let format = UIGraphicsImageRendererFormat()
		format.scale = 1
		let displayed = UIImage(cgImage: source, scale: 1, orientation: QuarterTurns.imageOrientation(1))
		let drawn = UIGraphicsImageRenderer(size: displayed.size, format: format).image { _ in displayed.draw(at: .zero) }
		let drawnImage = try XCTUnwrap(drawn.cgImage)
		XCTAssertEqual(drawnImage.width, 20)
		XCTAssertTrue(try isRed(drawnImage, x: 18, y: 1))
		XCTAssertFalse(try isRed(drawnImage, x: 1, y: 1))
	}

	func testTheRecipeIsStoredOnThePage() throws {
		let context = try makeContext()
		let capture = try insert(ScanCapture.self, "ScanCapture", into: context)
		XCTAssertNil(capture.recipe)
		XCTAssertEqual(capture.rotation, 0)
		XCTAssertTrue(capture.removeShadows)
		let recipe = PageRecipe(quad: square, mode: .whiteboard, rotation: 3, removeShadows: false, keepMarkerColors: false)
		capture.recipe = recipe
		let stored = try XCTUnwrap(capture.recipe)
		XCTAssertEqual(stored.quad.maxCornerDistance(to: square), 0, accuracy: 1e-5)
		XCTAssertEqual(stored.mode, .whiteboard)
		XCTAssertEqual(stored.rotation, 3)
		XCTAssertFalse(stored.removeShadows)
		XCTAssertFalse(stored.keepMarkerColors)
		XCTAssertFalse(capture.canReprocess(originals: makeStore()), "no id, no original")
	}

	func testReprocessingRemakesThePageAndDropsStaleTextAndTheRebuiltDocument() async throws {
		let context = try makeContext()
		let store = makeStore()
		let (scan, capture) = try makeScanWithPage(in: context)
		let id = try XCTUnwrap(capture.id)
		try store.save(try XCTUnwrap(OriginalStore.encode(CIImage(cgImage: try makeImage(width: 200, height: 100)))), for: id)
		XCTAssertTrue(capture.canReprocess(originals: store))
		// The sample document has four pages for this one-page scan: it can't take a spliced page,
		// so re-making the page clears it, as before (PageSpliceTests covers the splice).
		XCTAssertFalse(PageReprocessor.splicesRebuiltPage(of: capture))

		var recipe = try XCTUnwrap(capture.recipe)
		recipe.quad = square
		recipe.rotation = 1
		recipe.mode = .document
		let revision = PageRevisions.shared.revision(of: capture.objectID)
		let reading = try await PageReprocessor.apply(recipe, to: capture, originals: store)

		XCTAssertGreaterThan(PageRevisions.shared.revision(of: capture.objectID), revision,
							 "a reading of the old pixels still running must not store its lines")

		XCTAssertNil(scan.rebuiltData, "Rebuilder must not hand back the old document")
		XCTAssertFalse(capture.recognizedItemsArray.contains { $0.transcript == "stale" })
		XCTAssertEqual(capture.recipe, recipe)
		let page = try XCTUnwrap(capture.image)
		XCTAssertLessThan(page.size.width, page.size.height, "turned a quarter")
		XCTAssertNotNil(capture.thumbnailData)
		await reading.value
		XCTAssertFalse(capture.recognizedItemsArray.contains { $0.transcript == "stale" })
		XCTAssertFalse(context.hasChanges, "saved")
	}

	func testTurningAPageWithoutItsOriginalStillDropsStaleText() async throws {
		let context = try makeContext()
		let (scan, capture) = try makeScanWithPage(in: context)
		let reading = try await PageReprocessor.rotateStoredPage(capture, to: 3)
		XCTAssertEqual(capture.rotation, 3)
		let page = try XCTUnwrap(capture.image)
		XCTAssertLessThan(page.size.width, page.size.height)
		XCTAssertNil(scan.rebuiltData)
		XCTAssertFalse(capture.recognizedItemsArray.contains { $0.transcript == "stale" })
		await reading.value
		do {
			try await PageReprocessor.apply(try XCTUnwrap(capture.recipe), to: capture, originals: makeStore())
			XCTFail("there is no original to re-make the page from")
		} catch PageReprocessor.ReprocessError.missingOriginal {
			// Expected.
		}
	}

	func testAPageEditedInQuickLookIsReadAgainAndLeavesItsRecipe() async throws {
		let context = try makeContext()
		let (scan, capture) = try makeScanWithPage(in: context)
		capture.rotation = 2
		let edited = try XCTUnwrap(UIImage(cgImage: try makeImage(width: 100, height: 200)).jpegData(compressionQuality: 0.9))

		XCTAssertNil(PageReprocessor.storeEdited(Data("not an image".utf8), on: capture), "nothing stored")
		XCTAssertNotNil(capture.cropQuad)
		let reading = try XCTUnwrap(PageReprocessor.storeEdited(edited, on: capture))

		XCTAssertEqual(capture.imageData, edited)
		XCTAssertNil(capture.recipe, "can't be re-made from the original without losing the edit")
		XCTAssertEqual(capture.rotation, 2, "the turn stays")
		XCTAssertFalse(capture.recognizedItemsArray.contains { $0.transcript == "stale" })
		XCTAssertNil(scan.rebuiltData, "the sample document can't take a spliced page, so it goes")
		XCTAssertFalse(context.hasChanges, "saved")
		await reading.value
	}

	func testTurningAPageWithoutItsOriginalKeepsEveryPixel() async throws {
		let context = try makeContext()
		let (_, capture) = try makeScanWithPage(in: context)
		// A full-width portrait page: once turned it is wider than the 2400 px cap, and it must not shrink.
		capture.createImage(fullSizedImage: UIImage(cgImage: try makeImage(width: 2400, height: 2600)))
		let reading = try await PageReprocessor.rotateStoredPage(capture, to: 1)
		let turned = try XCTUnwrap(capture.image?.cgImage)
		XCTAssertEqual(turned.width, 2600)
		XCTAssertEqual(turned.height, 2400)
		await reading.value
	}

	func testRemakingAPageMakesReadingsAlreadyRunningStale() throws {
		let context = try makeContext()
		let (_, capture) = try makeScanWithPage(in: context)
		let (_, other) = try makeScanWithPage(in: context)
		let revisions = PageRevisions()
		let id = capture.objectID
		// The page's first reading starts, then the page is re-made before it has finished.
		let first = revisions.revision(of: id)
		revisions.pageRemade(id)
		XCTAssertNotEqual(revisions.revision(of: id), first, "the first reading's lines are dropped")
		XCTAssertEqual(revisions.revision(of: other.objectID), 0, "other pages' readings stand")
	}

	// MARK: Editor session

	func testTheEditorOffersRotationOnlyWithoutAnOriginal() async throws {
		let context = try makeContext()
		let (_, capture) = try makeScanWithPage(in: context)
		let model = PageEditorModel(capture: capture, originals: makeStore())
		await model.load()
		guard case .rotateOnly = model.availability else { return XCTFail("expected rotation only") }
		XCTAssertNotNil(model.baseImage)
		XCTAssertFalse(model.nudge(.corner(0), by: CGVector(dx: 0.01, dy: 0)))
		model.rotate(by: -1)
		XCTAssertEqual(model.state.rotation, 3)
		XCTAssertEqual(model.displayTurns, 3)
		XCTAssertTrue(model.hasChanges)
		model.undo()
		XCTAssertFalse(model.hasChanges)
	}

	func testTheEditorEditsTheCropWithUndoAndRedo() async throws {
		let context = try makeContext()
		let store = makeStore()
		let (_, capture) = try makeScanWithPage(in: context)
		capture.recipe = PageRecipe(quad: square, mode: .document, rotation: 0, removeShadows: true, keepMarkerColors: true)
		try store.save(try XCTUnwrap(OriginalStore.encode(CIImage(cgImage: try makeImage(width: 120, height: 160)))), for: try XCTUnwrap(capture.id))
		let model = PageEditorModel(capture: capture, originals: store)
		await model.load()
		XCTAssertEqual(model.availability, .full)
		XCTAssertEqual(model.modeOptions, [.document, .whiteboard])

		XCTAssertTrue(model.nudge(.corner(0), by: CGVector(dx: -0.1, dy: 0)))
		XCTAssertEqual(model.state.quad.topLeft.x, 0.1, accuracy: 1e-9)
		model.useFullImage()
		XCTAssertEqual(model.state.quad, .fullFrame)
		model.setMode(.whiteboard)
		model.undo()
		model.undo()
		model.undo()
		XCTAssertEqual(model.state, model.initial)
		model.redo()
		XCTAssertEqual(model.state.quad.topLeft.x, 0.1, accuracy: 1e-9)
		model.finishDrag(from: model.state.quad)
		XCTAssertTrue(model.history.canRedo, "a drag that went nowhere records nothing")
	}

	// MARK: Model version

	/// Version 4 is version 3 (the library: folders, tags, smart folders, pinned, Recently Deleted)
	/// plus the page recipe exactly as version 2 has it, so a library on any earlier version
	/// migrates to it with an inferred mapping.
	func testTheCurrentModelIsTheLibraryPlusThePageRecipe() throws {
		let v1 = try plainModel("scanner"), v2 = try plainModel("scanner 2"), v3 = try plainModel("scanner 3")
		let v4 = try plainModel(Self.currentModelVersion)
		let current = PersistenceController.shared.container.managedObjectModel
		XCTAssertEqual(current.entityVersionHashesByName, v4.entityVersionHashesByName)
		XCTAssertEqual(v4.entityVersionHashesByName["ScanCapture"], v2.entityVersionHashesByName["ScanCapture"])
		for name in ["Scan", "ScanRecognizedItem", "ScanFolder", "ScanTag", "SmartFolder"] {
			XCTAssertEqual(v4.entityVersionHashesByName[name], v3.entityVersionHashesByName[name], name)
		}
		let attributes = try XCTUnwrap(current.entitiesByName["ScanCapture"]).attributesByName
		for name in ["cropQuad", "cleanupMode", "rotation", "removeShadows", "keepMarkerColors"] {
			let attribute = try XCTUnwrap(attributes[name], name)
			XCTAssertTrue(attribute.isOptional, "\(name) must be optional for CloudKit")
		}
		XCTAssertEqual((attributes["rotation"]?.defaultValue as? NSNumber)?.intValue, 0)
		XCTAssertEqual((attributes["removeShadows"]?.defaultValue as? NSNumber)?.boolValue, true)
		XCTAssertEqual((attributes["keepMarkerColors"]?.defaultValue as? NSNumber)?.boolValue, true)
		for (version, old) in [("scanner", v1), ("scanner 2", v2), ("scanner 3", v3)] {
			XCTAssertNoThrow(try NSMappingModel.inferredMappingModel(forSourceModel: old, destinationModel: v4), version)
		}
	}

	func testAVersion1LibraryMigratesAndItsPagesGetDefaults() throws {
		let id = UUID()
		let context = try migratedLibrary(from: "scanner") { old in
			NSEntityDescription.insertNewObject(forEntityName: "ScanCapture", into: old).setValue(id, forKey: "id")
		}
		let page = try onlyObject("ScanCapture", in: context)
		XCTAssertEqual(page.value(forKey: "id") as? UUID, id)
		XCTAssertNil(page.value(forKey: "cropQuad"))
		XCTAssertNil(page.value(forKey: "cleanupMode"))
		XCTAssertEqual((page.value(forKey: "rotation") as? NSNumber)?.intValue, 0)
		XCTAssertEqual((page.value(forKey: "removeShadows") as? NSNumber)?.boolValue, true)
	}

	func testAVersion2LibraryKeepsItsPagesRecipes() throws {
		let quad = square.storageString
		let context = try migratedLibrary(from: "scanner 2") { old in
			let page = NSEntityDescription.insertNewObject(forEntityName: "ScanCapture", into: old)
			page.setValue(quad, forKey: "cropQuad")
			page.setValue("whiteboard", forKey: "cleanupMode")
			page.setValue(3, forKey: "rotation")
			page.setValue(false, forKey: "removeShadows")
			page.setValue(false, forKey: "keepMarkerColors")
		}
		let page = try onlyObject("ScanCapture", in: context)
		XCTAssertEqual(page.value(forKey: "cropQuad") as? String, quad)
		XCTAssertEqual(page.value(forKey: "cleanupMode") as? String, "whiteboard")
		XCTAssertEqual((page.value(forKey: "rotation") as? NSNumber)?.intValue, 3)
		XCTAssertEqual((page.value(forKey: "removeShadows") as? NSNumber)?.boolValue, false)
		XCTAssertEqual((page.value(forKey: "keepMarkerColors") as? NSNumber)?.boolValue, false)
		XCTAssertEqual(try context.count(for: NSFetchRequest<NSManagedObject>(entityName: "Scan")), 0)
	}

	func testAVersion3LibraryKeepsItsFoldersAndRecentlyDeleted() throws {
		let deleted = Date(timeIntervalSinceReferenceDate: 800_000_000)
		let context = try migratedLibrary(from: "scanner 3") { old in
			let folder = NSEntityDescription.insertNewObject(forEntityName: "ScanFolder", into: old)
			folder.setValue("Biology", forKey: "name")
			let scan = NSEntityDescription.insertNewObject(forEntityName: "Scan", into: old)
			scan.setValue(deleted, forKey: "deletedAt")
			scan.setValue(true, forKey: "pinned")
			scan.setValue(folder, forKey: "folder")
			let page = NSEntityDescription.insertNewObject(forEntityName: "ScanCapture", into: old)
			page.setValue(scan, forKey: "parent")
		}
		let scan = try onlyObject("Scan", in: context)
		XCTAssertEqual(scan.value(forKey: "deletedAt") as? Date, deleted)
		XCTAssertEqual((scan.value(forKey: "pinned") as? NSNumber)?.boolValue, true)
		XCTAssertEqual((scan.value(forKey: "folder") as? NSManagedObject)?.value(forKey: "name") as? String, "Biology")
		let page = try onlyObject("ScanCapture", in: context)
		XCTAssertEqual(page.value(forKey: "parent") as? NSManagedObject, scan)
		XCTAssertNil(page.value(forKey: "cropQuad"))
		XCTAssertEqual((page.value(forKey: "rotation") as? NSNumber)?.intValue, 0)
		XCTAssertEqual((page.value(forKey: "keepMarkerColors") as? NSNumber)?.boolValue, true)
	}

	// MARK: Helpers

	/// A temporary originals folder, removed after the test.
	private func makeStore() -> OriginalStore {
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FolioOriginals-\(UUID().uuidString)", isDirectory: true)
		addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
		return OriginalStore(directory: directory)
	}

	/// A temporary figures folder, removed after the test.
	private func makeFigureStore() -> FigureStore {
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FolioFigures-\(UUID().uuidString)", isDirectory: true)
		addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
		return FigureStore(directory: directory)
	}

	/// A store in a temporary annotations folder, removed after the test, and the folder.
	private func makeAnnotationStore() -> (store: AnnotationStore, folder: URL) {
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FolioMarks-\(UUID().uuidString)", isDirectory: true)
		addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
		return (AnnotationStore(folder: directory), directory)
	}

	/// The same pen stroke every time (one id), so tests can compare what comes back.
	private func sampleMark() -> PageMark {
		PageMark(id: Self.sampleMarkID, kind: .pen, points: [CGPoint(x: 0.1, y: 0.2), CGPoint(x: 0.3, y: 0.4)], color: 0xD0392B, width: 0.004)
	}

	private static let sampleMarkID = UUID()

	private func hasMarksFile(_ pageID: UUID, in folder: URL) -> Bool {
		FileManager.default.fileExists(atPath: folder.appendingPathComponent(pageID.uuidString).appendingPathExtension("json").path)
	}

	/// A new temporary folder, removed after the test.
	private func makeTemporaryFolder(_ name: String) throws -> URL {
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
		return directory
	}

	/// A temporary folder for original PDFs (as Originals/PDF holds them), removed after the test.
	private func makePDFOriginalsFolder() throws -> URL {
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FolioPDFs-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
		return directory
	}

	/// A kept PDF for scan `id` in `directory` (<id>/Original.pdf), its folder old enough to prune.
	private func keepPDF(for id: UUID, in directory: URL) throws -> URL {
		let folder = directory.appendingPathComponent(id.uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		let file = folder.appendingPathComponent("Original.pdf")
		try Data("%PDF-1.4".utf8).write(to: file)
		try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-7200)], ofItemAtPath: folder.path)
		return file
	}

	/// A library in a temporary SQLite file on the app's own model: the launch-time cleanup skips
	/// in-memory libraries. Close it with `closeLibrary(_:)`.
	private func makeLibraryOnDisk() throws -> NSManagedObjectContext {
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FolioLibrary-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
		let container = NSPersistentContainer(name: "scanner", managedObjectModel: PersistenceController.shared.container.managedObjectModel)
		let description = NSPersistentStoreDescription(url: directory.appendingPathComponent("library.sqlite"))
		description.type = NSSQLiteStoreType
		container.persistentStoreDescriptions = [description]
		var loadError: Error?
		container.loadPersistentStores { _, error in loadError = error }
		if let loadError { throw loadError }
		containers.append(container)
		return container.viewContext
	}

	/// Closes a library from `makeLibraryOnDisk()` before its folder goes.
	private func closeLibrary(_ context: NSManagedObjectContext) throws {
		let coordinator = try XCTUnwrap(context.persistentStoreCoordinator)
		for store in coordinator.persistentStores {
			try coordinator.remove(store)
		}
	}

	/// An in-memory library whose saves fail while `failsSaves` is set.
	private func makeFailingContext() throws -> FailingSaveContext {
		let coordinator = try XCTUnwrap(try makeContext().persistentStoreCoordinator)
		let context = FailingSaveContext(concurrencyType: .mainQueueConcurrencyType)
		context.persistentStoreCoordinator = coordinator
		return context
	}

	/// An in-memory library on the app's own model (one model instance, so entity lookup by class
	/// stays unambiguous).
	private func makeContext() throws -> NSManagedObjectContext {
		let container = NSPersistentContainer(name: "scanner", managedObjectModel: PersistenceController.shared.container.managedObjectModel)
		let description = NSPersistentStoreDescription()
		description.type = NSInMemoryStoreType
		container.persistentStoreDescriptions = [description]
		var loadError: Error?
		container.loadPersistentStores { _, error in loadError = error }
		if let loadError { throw loadError }
		containers.append(container)
		return container.viewContext
	}

	private func insert<Object: NSManagedObject>(_ type: Object.Type, _ entityName: String, into context: NSManagedObjectContext) throws -> Object {
		try XCTUnwrap(NSEntityDescription.insertNewObject(forEntityName: entityName, into: context) as? Object)
	}

	/// A rebuilt scan with one page that has a recipe, a stored image and two stale lines.
	private func makeScanWithPage(in context: NSManagedObjectContext) throws -> (Scan, ScanCapture) {
		let scan = try insert(Scan.self, "Scan", into: context)
		scan.id = UUID()
		let capture = try insert(ScanCapture.self, "ScanCapture", into: context)
		capture.id = UUID()
		capture.createImage(fullSizedImage: UIImage(cgImage: try makeImage(width: 200, height: 100)))
		capture.createThumbnail()
		capture.recipe = PageRecipe(quad: .fullFrame, mode: nil, rotation: 0, removeShadows: true, keepMarkerColors: true)
		scan.addToCaptures(capture)
		for index in 0..<2 {
			let item = try insert(ScanRecognizedItem.self, "ScanRecognizedItem", into: context)
			item.transcript = "stale"
			item.order = Int32(index)
			capture.addToRecognizedItems(item)
		}
		var document = SampleLibrary.labNotesDocument
		document.sourceCaptureIDs = scan.capturesArray.compactMap(\.id)
		scan.rebuiltDocument = document
		try context.save()
		XCTAssertNotNil(scan.rebuiltData)
		return (scan, capture)
	}

	/// A white image with a red block in its top-left corner.
	private func makeImage(width: Int, height: Int) throws -> CGImage {
		let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
		let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
											  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
		context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
		context.fill(CGRect(x: 0, y: 0, width: width, height: height))
		context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
		let block = CGSize(width: max(2, width / 5), height: max(2, height / 4))
		// Core Graphics' origin is the bottom-left, so the top-left block sits at the top of the y range.
		context.fill(CGRect(x: 0, y: CGFloat(height) - block.height, width: block.width, height: block.height))
		return try XCTUnwrap(context.makeImage())
	}

	/// True when the pixel at (x, y), counted from the top-left, is clearly red.
	private func isRed(_ image: CGImage, x: Int, y: Int) throws -> Bool {
		var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
		let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
		let drawn: Bool = bytes.withUnsafeMutableBytes { buffer in
			guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
										  bytesPerRow: image.width * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
				return false
			}
			context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
			return true
		}
		XCTAssertTrue(drawn)
		let index = (y * image.width + x) * 4
		return bytes[index] > 200 && bytes[index + 1] < 80 && bytes[index + 2] < 80
	}

	/// The model version the app opens its library on (scanner.xcdatamodeld's current version).
	private static let currentModelVersion = "scanner 4"

	/// A library saved on model `version` after `fill`, then opened on the current version the way
	/// the app opens it: migrated in place with an inferred mapping.
	private func migratedLibrary(from version: String, fill: (NSManagedObjectContext) throws -> Void) throws -> NSManagedObjectContext {
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FolioMigration-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
		let url = directory.appendingPathComponent("library.sqlite")

		let oldCoordinator = NSPersistentStoreCoordinator(managedObjectModel: try plainModel(version))
		let oldStore = try oldCoordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: url, options: nil)
		let oldContext = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
		oldContext.persistentStoreCoordinator = oldCoordinator
		try fill(oldContext)
		try oldContext.save()
		try oldCoordinator.remove(oldStore)

		let coordinator = NSPersistentStoreCoordinator(managedObjectModel: try plainModel(Self.currentModelVersion))
		let options = [NSMigratePersistentStoresAutomaticallyOption: true, NSInferMappingModelAutomaticallyOption: true]
		try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: url, options: options)
		let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
		context.persistentStoreCoordinator = coordinator
		return context
	}

	/// The one `entityName` object in `context`.
	private func onlyObject(_ entityName: String, in context: NSManagedObjectContext) throws -> NSManagedObject {
		let objects = try context.fetch(NSFetchRequest<NSManagedObject>(entityName: entityName))
		XCTAssertEqual(objects.count, 1, entityName)
		return try XCTUnwrap(objects.first, entityName)
	}

	/// A version of the model from the app's bundle, with every entity as a plain NSManagedObject so
	/// it doesn't compete with the app's model for the generated classes.
	private func plainModel(_ version: String) throws -> NSManagedObjectModel {
		let momd = try XCTUnwrap(Bundle.main.url(forResource: "scanner", withExtension: "momd"))
		let model = try XCTUnwrap(NSManagedObjectModel(contentsOf: momd.appendingPathComponent("\(version).mom")), version)
		for entity in model.entities {
			entity.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
		}
		return model
	}
}

/// A library context whose saves can be made to fail, as they do on a full disk.
private final class FailingSaveContext: NSManagedObjectContext, @unchecked Sendable {
	var failsSaves = false

	override func save() throws {
		if failsSaves {
			throw CocoaError(.fileWriteOutOfSpace)
		}
		try super.save()
	}
}
