//
//  PageSpliceTests.swift
//  Rescriva (fork of Open Scanner)
//
//  Re-making one page of a rebuilt scan: the page is marked stale, rebuilt
//  alone and spliced in place. Other pages keep their content, notes, flags
//  and text fingerprint; the new page keeps its page notes and only the
//  block notes and word choices whose words still read the same (other
//  block notes become page notes, once even across a split) and its
//  Recreate drawings; figures are numbered again when needed; and neither a
//  whole rebuild of older pixels nor a splice of them can overwrite a newer
//  page.
//

import CoreData
import CoreImage
import UIKit
import XCTest
@testable import scanner

@MainActor
final class PageSpliceTests: XCTestCase {

	private let ids = [UUID(), UUID()]
	/// A fixed date, so notes compare equal after a JSON round trip.
	private let created = Date(timeIntervalSinceReferenceDate: 700_000_000)
	/// In-memory containers kept alive for the test's contexts.
	private var containers: [NSPersistentContainer] = []

	override func tearDown() {
		containers.removeAll()
		super.tearDown()
	}

	// MARK: Marking

	func testMarkingAPageStaleKeepsTheDocumentAndDropsOnlyItsFingerprint() throws {
		let document = twoPageDocument(ids: ids)
		XCTAssertFalse(document.hasStalePages)
		let marked = try XCTUnwrap(PageSplice.markingStale(ids[1], in: document, captureIDs: ids))
		XCTAssertEqual(marked.staleCaptureIDs, [ids[1]])
		XCTAssertTrue(marked.hasStalePages)
		XCTAssertEqual(marked.pages[0], document.pages[0])
		XCTAssertEqual(marked.pages[1].blocks, document.pages[1].blocks)
		XCTAssertNil(marked.pages[1].sourceTextDigest, "the text layer keeps the lines as read until the new page lands")

		let again = try XCTUnwrap(PageSplice.markingStale(ids[1], in: marked, captureIDs: ids))
		XCTAssertEqual(again.staleCaptureIDs, [ids[1]], "marked once")
		XCTAssertNil(PageSplice.markingStale(ids[1], in: document, captureIDs: ids + [UUID()]), "a page added since the rebuild")
		XCTAssertNil(PageSplice.markingStale(ids[1], in: document, captureIDs: ids.reversed()), "pages moved since the rebuild")
	}

	// MARK: Splicing

	func testSplicingReplacesOnlyThatPageAndKeepsWhatStillApplies() throws {
		let document = try XCTUnwrap(PageSplice.markingStale(ids[1], in: twoPageDocument(ids: ids), captureIDs: ids))
		let spliced = try XCTUnwrap(PageSplice.splicing(rebuiltPage(), for: ids[1], into: document, captureIDs: ids))

		XCTAssertEqual(spliced.pages[0], document.pages[0], "the other page keeps its content, notes, flags and fingerprint")
		XCTAssertNil(spliced.staleCaptureIDs)
		XCTAssertEqual(spliced.sourceCaptureIDs, ids)
		let page = spliced.pages[1]
		XCTAssertEqual(page.id, document.pages[1].id)
		XCTAssertEqual(page.notes.first?.text, "Whole page", "page notes stay")
		XCTAssertEqual(page.sourceTextDigest, "new-lines", "the new page's own fingerprint")
		XCTAssertEqual(page.blocks.map(\.content.plainText),
					   ["Reaction rate rises until the enzyme is saturated at last.", "Read differently now", "Total", "Total"])

		// The block that reads the same keeps its notes and the word chosen in Review, not its bold.
		let kept = page.blocks[0]
		XCTAssertEqual(kept.notes.map(\.text), ["Check the units", "On the word"])
		let runs = RescrivaRunLookup.allRuns(in: kept.content)
		let flagged = try XCTUnwrap(runs.first { $0.flag != nil })
		XCTAssertEqual(flagged.flag?.resolution, "saturated")
		XCTAssertNil(kept.notes[0].runID)
		XCTAssertEqual(kept.notes[1].runID, flagged.id, "re-anchored to the same word")
		XCTAssertFalse(runs.contains(where: \.bold), "formatting is redone")

		// Notes on blocks whose words are gone, or that are no longer one block, become page notes.
		XCTAssertTrue(page.blocks.dropFirst().allSatisfy(\.notes.isEmpty))
		XCTAssertEqual(page.notes.map(\.text), ["Whole page", "On “Words the new pixels no longer…”: Gone", "On “Total”: Which total?"])
		XCTAssertTrue(page.notes.allSatisfy { $0.runID == nil })

		XCTAssertNil(PageSplice.splicing(rebuiltPage(), for: ids[1], into: spliced, captureIDs: ids), "not stale any more")
		XCTAssertNil(PageSplice.splicing(rebuiltPage(), for: ids[1], into: document, captureIDs: ids + [UUID()]), "pages changed")
	}

	func testABlockNoteMatchingNeitherHalfOfASplitBecomesOnePageNote() throws {
		let pageIDs = [UUID()], newID = UUID()
		let note = RescrivaNote(text: "Ask Sam", created: created)
		let straddling = RescrivaBlock(content: .paragraph(runs: [RescrivaRun(text: "A paragraph across the fold")], alignment: .leading), notes: [note])
		let leftNote = RescrivaNote(text: "Left", created: created)
		let left = RescrivaBlock(content: .paragraph(runs: [RescrivaRun(text: "Left page text")], alignment: .leading), notes: [leftNote])
		let document = RescrivaDocument(title: "Book", pages: [RescrivaPage(blocks: [left, straddling])], sourceCaptureIDs: pageIDs)
		let split = try XCTUnwrap(PageSplice.splitting(pageIDs[0], adding: newID, in: document, captureIDs: pageIDs))
		let halves = pageIDs + [newID]
		let first = RescrivaPage(blocks: [paragraph("Left page text"), paragraph("A paragraph across")])
		let second = RescrivaPage(blocks: [paragraph("the fold")])

		let once = try XCTUnwrap(PageSplice.splicing(first, for: pageIDs[0], into: split, captureIDs: halves))
		let both = try XCTUnwrap(PageSplice.splicing(second, for: newID, into: once, captureIDs: halves))

		XCTAssertEqual(both.pages[0].blocks[0].notes.map(\.text), ["Left"], "matched on the first half")
		XCTAssertTrue(both.pages[0].notes.isEmpty, "the other half could still take it")
		XCTAssertEqual(both.pages[1].notes.map(\.text), ["On “A paragraph across the fold”: Ask Sam"], "kept once, on the half spliced last")
		XCTAssertEqual(both.pages.flatMap { PageSplice.noteIDs(on: $0) }.filter { $0 == note.id }.count, 1)
	}

	func testWordChoicesComeAcrossOnlyWhenTheSameWordsAreUncertain() throws {
		let resolved = flaggedRun(read: "teh", resolution: "the")
		let old = RescrivaBlock(content: .paragraph(runs: [RescrivaRun(text: "Read "), resolved, RescrivaRun(text: " page")], alignment: .leading),
							 notes: [RescrivaNote(text: "Kept", created: created)])
		// Read the same, but this time Vision was sure of the word: nothing to resolve.
		let sure = RescrivaBlock(content: .paragraph(runs: [RescrivaRun(text: "Read teh page")], alignment: .leading))
		let carried = PageSplice.carryingReview(from: RescrivaPage(blocks: [old]), to: RescrivaPage(blocks: [sure]))
		XCTAssertEqual(carried.blocks[0].content.plainText, "Read teh page")
		XCTAssertEqual(carried.blocks[0].notes.map(\.text), ["Kept"], "the words still read the same")
		XCTAssertEqual(PageSplice.readingKey(old.content), "Read teh page")
		XCTAssertEqual(PageSplice.readingKey(.diagram(Diagram(nodes: [], edges: []))), "")
	}

	func testFiguresAfterTheSplicedPageAreNumberedAgainOnlyWhenItGainsOrLosesOne() throws {
		let pageIDs = [UUID(), UUID(), UUID()]
		var document = RescrivaDocument(title: "Figures", pages: [
			RescrivaPage(blocks: [diagramBlock(Rebuilder.figureCaption(1, source: .typed))]),
			RescrivaPage(blocks: [paragraph("No drawing here yet")]),
			RescrivaPage(source: .whiteboard, blocks: [diagramBlock(Rebuilder.figureCaption(2, source: .whiteboard))]),
		], sourceCaptureIDs: pageIDs)
		document = try XCTUnwrap(PageSplice.markingStale(pageIDs[1], in: document, captureIDs: pageIDs))
		// Rebuilt alone, the page numbers its diagram from 1.
		let gained = RescrivaPage(blocks: [diagramBlock(Rebuilder.figureCaption(1, source: .typed))])
		let spliced = try XCTUnwrap(PageSplice.splicing(gained, for: pageIDs[1], into: document, captureIDs: pageIDs))
		XCTAssertEqual(captions(spliced.pages[1]), [Rebuilder.figureCaption(2, source: .typed)])
		XCTAssertEqual(captions(spliced.pages[2]), [Rebuilder.figureCaption(3, source: .whiteboard)])
		XCTAssertEqual(spliced.pages[0], document.pages[0])

		// The same number of diagrams: the later page stays exactly as it was.
		let again = try XCTUnwrap(PageSplice.markingStale(pageIDs[1], in: spliced, captureIDs: pageIDs))
		let redrawn = RescrivaPage(blocks: [diagramBlock(Rebuilder.figureCaption(1, source: .typed))])
		let respliced = try XCTUnwrap(PageSplice.splicing(redrawn, for: pageIDs[1], into: again, captureIDs: pageIDs))
		XCTAssertEqual(respliced.pages[2], again.pages[2])
		XCTAssertEqual(captions(respliced.pages[1]), [Rebuilder.figureCaption(2, source: .typed)])
	}

	func testARecreateDrawingComesAcrossOnceWithItsNoteAndCaption() throws {
		let pageIDs = [UUID()], newID = UUID()
		var drawing = diagramBlock("Figure 2: Enzyme activity")
		drawing.provenance = Provenance(engine: "user", confidence: 1)
		drawing.notes = [RescrivaNote(text: "Check the arrow", created: created)]
		let detected = diagramBlock(Rebuilder.figureCaption(1, source: .typed))
		let document = RescrivaDocument(title: "Lab", pages: [RescrivaPage(blocks: [paragraph("Results"), detected, drawing])],
									 sourceCaptureIDs: pageIDs)
		// Re-made, the page reads again with a figure where the detected diagram was.
		let stale = try XCTUnwrap(PageSplice.markingStale(pageIDs[0], in: document, captureIDs: pageIDs))
		let reread = RescrivaPage(blocks: [paragraph("Results"), RescrivaBlock(content: .figure(assetID: nil, caption: nil, altText: nil))])
		let spliced = try XCTUnwrap(PageSplice.splicing(reread, for: pageIDs[0], into: stale, captureIDs: pageIDs))
		let blocks = spliced.pages[0].blocks
		XCTAssertEqual(blocks.count, 3, "what was read, then the drawing")
		XCTAssertEqual(blocks.last?.id, drawing.id)
		XCTAssertEqual(blocks.last?.notes.map(\.text), ["Check the arrow"], "its note stays on it")
		XCTAssertTrue(spliced.pages[0].notes.isEmpty, "not repeated as a page note")
		XCTAssertEqual(captions(spliced.pages[0]), ["Figure 2: Enzyme activity"], "counted, but its caption is its own")

		// Split in two: the drawing lands once, on the half spliced last.
		let split = try XCTUnwrap(PageSplice.splitting(pageIDs[0], adding: newID, in: document, captureIDs: pageIDs))
		let halves = pageIDs + [newID]
		let once = try XCTUnwrap(PageSplice.splicing(RescrivaPage(blocks: [paragraph("Results")]), for: pageIDs[0], into: split, captureIDs: halves))
		let both = try XCTUnwrap(PageSplice.splicing(RescrivaPage(blocks: []), for: newID, into: once, captureIDs: halves))
		XCTAssertEqual(both.pages[0].blocks.map(\.content.plainText), ["Results"], "the half spliced first doesn't take it")
		XCTAssertEqual(both.pages[1].blocks.map(\.id), [drawing.id])
		XCTAssertEqual(both.pages.flatMap { PageSplice.noteIDs(on: $0) }, drawing.notes.map(\.id))
	}

	// MARK: Re-made pages

	func testReMakingAPageOfARebuiltScanRedoesOnlyThatPage() async throws {
		let context = try makeContext()
		let store = makeStore()
		let scan = try makeScan(pageCount: 2, in: context)
		let captureIDs = scan.capturesArray.compactMap(\.id)
		let original = twoPageDocument(ids: captureIDs)
		scan.rebuiltDocument = original
		try context.save()
		let target = try XCTUnwrap(scan.capturesArray.last)
		try store.save(try XCTUnwrap(OriginalStore.encode(CIImage(cgImage: try makeImage(width: 200, height: 100)))), for: captureIDs[1])
		XCTAssertTrue(PageReprocessor.splicesRebuiltPage(of: target))

		var recipe = try XCTUnwrap(target.recipe)
		recipe.rotation = 1
		let reading = try await PageReprocessor.apply(recipe, to: target, originals: store)

		let marked = try XCTUnwrap(scan.rebuiltDocument, "the rebuilt document is kept")
		XCTAssertEqual(marked.staleCaptureIDs, [captureIDs[1]])
		XCTAssertEqual(marked.pages[0], original.pages[0])
		XCTAssertNil(marked.pages[1].sourceTextDigest)

		await reading.value

		let spliced = try XCTUnwrap(scan.rebuiltDocument)
		XCTAssertFalse(spliced.hasStalePages)
		XCTAssertEqual(spliced.sourceCaptureIDs, captureIDs)
		XCTAssertEqual(spliced.pages[0], original.pages[0], "the other page keeps its content, notes, flags and fingerprint")
		XCTAssertEqual(spliced.pages[1].id, original.pages[1].id)
		XCTAssertEqual(Array(spliced.pages[1].notes.prefix(original.pages[1].notes.count)), original.pages[1].notes, "page notes stay")
		// No block reads as before on the new pixels, so every block note follows as a page note.
		let blockNotes = original.pages[1].blocks.flatMap(\.notes)
		XCTAssertEqual(Set(spliced.pages[1].notes.map(\.id)), Set((original.pages[1].notes + blockNotes).map(\.id)))
		XCTAssertFalse(spliced.pages[1].blocks.contains { $0.content.plainText.contains("Reaction rate") }, "rebuilt from the new pixels")
		XCTAssertEqual(spliced.pages[1].sourceTextDigest, TextLayerReconciler.digest(of: target.recognizedItemsArray.map(\.recognizedLine)))
		XCTAssertFalse(scan.managedObjectContext?.hasChanges ?? true, "saved")

		// The cache holds: asking for the document now hands back the spliced one, no rebuild.
		let current = await Rebuilder(tier: .basic).document(for: scan) { _ in }
		XCTAssertEqual(current, spliced)
	}

	func testRebuildsOfOlderPixelsCannotOverwriteASplicedPage() async throws {
		let context = try makeContext()
		let store = makeStore()
		let scan = try makeScan(pageCount: 2, in: context)
		let captureIDs = scan.capturesArray.compactMap(\.id)
		scan.rebuiltDocument = twoPageDocument(ids: captureIDs)
		try context.save()
		let target = try XCTUnwrap(scan.capturesArray.last)
		try store.save(try XCTUnwrap(OriginalStore.encode(CIImage(cgImage: try makeImage(width: 200, height: 100)))), for: captureIDs[1])

		// A whole rebuild that copied the pages before the re-make…
		let before = scan.capturesArray.map(Rebuilder.snapshot(of:))
		let startingData = scan.rebuiltData
		var recipe = try XCTUnwrap(target.recipe)
		recipe.rotation = 2
		let reading = try await PageReprocessor.apply(recipe, to: target, originals: store)
		// …and one that copied them after it, while the page waited to be spliced.
		let after = scan.capturesArray.map(Rebuilder.snapshot(of:))
		let markedData = scan.rebuiltData
		let page = Rebuilder.snapshot(of: target)
		await reading.value
		XCTAssertFalse(try XCTUnwrap(scan.rebuiltDocument).hasStalePages)

		XCTAssertFalse(Rebuilder.mayCache(before, captureIDs: captureIDs, startedWith: startingData, of: scan), "built from the old pixels")
		XCTAssertFalse(Rebuilder.mayCache(after, captureIDs: captureIDs, startedWith: markedData, of: scan), "would drop the splice")
		XCTAssertTrue(Rebuilder.mayCache(scan.capturesArray.map(Rebuilder.snapshot(of:)), captureIDs: captureIDs,
										 startedWith: scan.rebuiltData, of: scan), "nothing changed meanwhile")

		// A page built from pixels the page no longer has isn't spliced either.
		XCTAssertTrue(Rebuilder.isCurrent(page, captureID: captureIDs[1], of: scan))
		recipe.rotation = 3
		let second = try await PageReprocessor.apply(recipe, to: target, originals: store)
		XCTAssertFalse(Rebuilder.isCurrent(page, captureID: captureIDs[1], of: scan))
		await second.value
		XCTAssertFalse(try XCTUnwrap(scan.rebuiltDocument).hasStalePages)
	}

	// MARK: Fixtures

	/// Page one: a fixed word and a note. Page two (the one re-made): a paragraph with a fixed word,
	/// bold, a block note and a note on the word; a paragraph whose words will be gone; a "Total"
	/// that the new page will have twice; and a page note.
	private func twoPageDocument(ids: [UUID]) -> RescrivaDocument {
		let kept = RescrivaPage(blocks: [
			RescrivaBlock(content: .paragraph(runs: [RescrivaRun(text: "A "), flaggedRun(read: "chioce", resolution: "choice")], alignment: .leading),
					   notes: [RescrivaNote(text: "First page", created: created)]),
		], notes: [RescrivaNote(text: "Page one", created: created)], sourceTextDigest: "old-one")
		let fixed = flaggedRun(read: "saturuted", resolution: "saturated")
		let remade = RescrivaPage(blocks: [
			RescrivaBlock(content: .paragraph(runs: [RescrivaRun(text: "Reaction rate rises until the enzyme is ", bold: true), fixed,
												  RescrivaRun(text: " at last.", bold: true)], alignment: .leading),
					   notes: [RescrivaNote(text: "Check the units", created: created),
							   RescrivaNote(text: "On the word", created: created, runID: fixed.id)]),
			RescrivaBlock(content: .paragraph(runs: [RescrivaRun(text: "Words the new pixels no longer show")], alignment: .leading),
					   notes: [RescrivaNote(text: "Gone", created: created)]),
			RescrivaBlock(content: .paragraph(runs: [RescrivaRun(text: "Total")], alignment: .leading),
					   notes: [RescrivaNote(text: "Which total?", created: created)]),
		], notes: [RescrivaNote(text: "Whole page", created: created)], sourceTextDigest: "old-two")
		return RescrivaDocument(title: "Splice", pages: [kept, remade], sourceCaptureIDs: ids)
	}

	/// The re-made page as the rebuild reads it now.
	private func rebuiltPage() -> RescrivaPage {
		RescrivaPage(blocks: [
			RescrivaBlock(content: .paragraph(runs: [RescrivaRun(text: "Reaction rate rises until the enzyme is "),
												  flaggedRun(read: "saturuted", resolution: nil), RescrivaRun(text: " at last.")],
										   alignment: .leading)),
			paragraph("Read differently now"),
			paragraph("Total"),
			paragraph("Total"),
		], sourceTextDigest: "new-lines")
	}

	private func flaggedRun(read: String, resolution: String?) -> RescrivaRun {
		var flag = RescrivaFlag(kind: .word, title: "Did you mean…", detail: "", read: read,
							 options: [RescrivaFlag.Option(label: resolution ?? read), RescrivaFlag.Option(label: read, note: "keep as read")])
		flag.resolution = resolution
		return RescrivaRun(text: resolution ?? read, flag: flag)
	}

	private func paragraph(_ text: String) -> RescrivaBlock {
		RescrivaBlock(content: .paragraph(runs: [RescrivaRun(text: text)], alignment: .leading))
	}

	private func diagramBlock(_ caption: String) -> RescrivaBlock {
		let node = Diagram.Node(id: "a", label: "A", shape: .rectangle, box: NormalizedBox(x: 0, y: 0, width: 1, height: 1),
								stroke: RGBColor(hex: 0x333333))
		return RescrivaBlock(content: .diagram(Diagram(nodes: [node], edges: [], caption: caption)))
	}

	private func captions(_ page: RescrivaPage) -> [String?] {
		page.blocks.compactMap { block in
			guard case .diagram(let diagram) = block.content else { return nil }
			return diagram.caption
		}
	}

	// MARK: Helpers

	/// A temporary originals folder, removed after the test.
	private func makeStore() -> OriginalStore {
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RescrivaSplice-\(UUID().uuidString)", isDirectory: true)
		addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
		return OriginalStore(directory: directory)
	}

	/// An in-memory library on the app's own model.
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

	/// A scan of `pageCount` pages, each with a recipe, a stored image and one recognized line.
	private func makeScan(pageCount: Int, in context: NSManagedObjectContext) throws -> Scan {
		let scan = try insert(Scan.self, "Scan", into: context)
		scan.id = UUID()
		for index in 0..<pageCount {
			let capture = try insert(ScanCapture.self, "ScanCapture", into: context)
			capture.id = UUID()
			capture.order = Int32(index)
			capture.createImage(fullSizedImage: UIImage(cgImage: try makeImage(width: 200, height: 100)))
			capture.createThumbnail()
			capture.recipe = PageRecipe(quad: .fullFrame, mode: nil, rotation: 0, removeShadows: true, keepMarkerColors: true)
			scan.addToCaptures(capture)
			let item = try insert(ScanRecognizedItem.self, "ScanRecognizedItem", into: context)
			item.transcript = "Page \(index + 1)"
			capture.addToRecognizedItems(item)
		}
		try context.save()
		return scan
	}

	/// A white image with a red block in its top-left corner.
	private func makeImage(width: Int, height: Int) throws -> CGImage {
		let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
		let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
											  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
		context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
		context.fill(CGRect(x: 0, y: 0, width: width, height: height))
		context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
		context.fill(CGRect(x: 0, y: height - height / 4, width: width / 5, height: height / 4))
		return try XCTUnwrap(context.makeImage())
	}
}
