//
//  PDFMarkupEditingTests.swift
//  Rescriva (fork of Open Scanner)
//
//  Marking up a PDF beyond drawing: the notched sizes and any-color choice, hitting thin marks
//  precisely, the pointer's select, move, resize and recolor (each one undo step, dragging the
//  color well coalesced), moved marks staying put through a save, the note margin's geometry on
//  rotated pages and its round trip through a save, and who marks up on an iPad. Then saving in
//  the background from a snapshot (bookmarks kept, edits made meanwhile not lost, readers waiting
//  for it), page thumbnails redrawn only when their page changes, and the "With marks" filter.
//

import PDFKit
import UIKit
import XCTest
@testable import scanner

@MainActor
final class PDFMarkupEditingTests: XCTestCase {

	// MARK: Sizes and colors

	func testEveryToolOffersMoreSizesThanBefore() {
		for group in [PDFMarkupStyleGroup.highlighter, .pen, .shape, .text] {
			XCTAssertGreaterThanOrEqual(group.sizes.count, 10, "\(group)")
			XCTAssertEqual(group.sizes, group.sizes.sorted(), "notches run thin to thick")
			XCTAssertTrue(group.sizes.contains(group.defaultSize), "\(group) starts on a notch")
		}
		XCTAssertTrue(PDFMarkupStyleGroup.textLine.sizes.isEmpty, "underlines follow the text")
		XCTAssertFalse(PDFMarkupTool.highlight.hasSizes)
		XCTAssertFalse(PDFMarkupTool.note.hasSizes)
		XCTAssertTrue(PDFMarkupTool.pen.hasSizes)
		XCTAssertEqual(PDFMarkupStyleGroup.pen.nearestSize(2.7), 3)
		XCTAssertEqual(PDFMarkupStyleGroup.text.nearestSize(100), 40)
	}

	func testPaletteColorsAreRecognizedAndAnyOtherIsCustom() {
		let group = PDFMarkupStyleGroup.pen
		XCTAssertEqual(group.markupColor(for: group.swatches[2].uiColor), .swatch(2))
		XCTAssertEqual(group.markupColor(for: UIColor(markRGB: 0x123456)), .custom(0x123456))
		XCTAssertEqual(UIColor(markRGB: 0xABCDEF).markRGB, 0xABCDEF)
		XCTAssertEqual(UIColor(red: 1, green: 0.5, blue: 0, alpha: 0.4).markRGB, 0xFF8000, "alpha is ignored")
	}

	func testChoosingAnyColorAndSizeSetsWhatNewMarksGet() throws {
		let (session, _) = try makeSession()
		session.tool = .pen
		session.selectColor(.custom(0x336699))
		session.selectSize(8)
		XCTAssertEqual(session.currentColor.markRGB, 0x336699)
		XCTAssertEqual(session.currentSize, 8)
		session.tool = .rectangle
		XCTAssertEqual(session.currentSize, PDFMarkupStyleGroup.shape.defaultSize, "shapes keep their own size")
		session.tool = .pen
		XCTAssertEqual(session.currentStyle, PDFMarkupStyle(color: .custom(0x336699), size: 8), "and the pen remembers its own")
	}

	// MARK: Hitting marks

	func testThinMarksAreHitNearTheirStrokeNotAcrossTheirBox() throws {
		let line = try XCTUnwrap(PDFMarkupFactory.shape(.line, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 300), color: .red, width: 2))
		XCTAssertTrue(PDFMarkupFactory.hitTest(line, CGPoint(x: 200, y: 203)))
		XCTAssertFalse(PDFMarkupFactory.hitTest(line, CGPoint(x: 280, y: 120)), "inside the box, far from the line")

		let ink = try XCTUnwrap(PDFMarkupFactory.ink([CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 100), CGPoint(x: 300, y: 300)], color: .black, width: 3))
		XCTAssertTrue(PDFMarkupFactory.hitTest(ink, CGPoint(x: 200, y: 104)))
		XCTAssertFalse(PDFMarkupFactory.hitTest(ink, CGPoint(x: 150, y: 250)), "the empty corner of the stroke's box")

		let box = try XCTUnwrap(PDFMarkupFactory.shape(.rectangle, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 200, y: 200), color: .red, width: 2))
		XCTAssertTrue(PDFMarkupFactory.hitTest(box, CGPoint(x: 150, y: 150)), "a box is easy to grab from inside")
	}

	// MARK: The pointer

	func testPickMoveAndUndo() throws {
		let (session, page) = try makeSession()
		let box = try XCTUnwrap(PDFMarkupFactory.shape(.rectangle, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 200, y: 160), color: .red, width: 2))
		session.add([box], on: page)
		session.tool = .select
		let picked = try XCTUnwrap(session.mark(at: CGPoint(x: 150, y: 130), on: page))
		XCTAssertTrue(picked === box)
		session.select(picked, on: page)
		let before = box.bounds
		session.moveSelection(by: CGVector(dx: 40, dy: -30))
		XCTAssertEqual(box.bounds, before.offsetBy(dx: 40, dy: -30))
		session.moveSelection(by: CGVector(dx: 5000, dy: 0))
		XCTAssertEqual(box.bounds.maxX, page.bounds(for: .cropBox).maxX, accuracy: 0.01, "a mark stays on its page")
		session.undo()
		session.undo()
		XCTAssertEqual(box.bounds, before)
		session.redo()
		XCTAssertEqual(box.bounds, before.offsetBy(dx: 40, dy: -30))
	}

	func testHighlightsCanBePickedAndDeletedButNotMoved() throws {
		let (session, page) = try makeSession()
		let highlight = PDFAnnotation(bounds: CGRect(x: 72, y: 690, width: 150, height: 14), forType: .highlight, withProperties: nil)
		session.add([highlight], on: page)
		XCTAssertTrue(PDFMarkupFactory.isSelectable(highlight))
		XCTAssertFalse(PDFMarkupFactory.isMovable(highlight))
		session.tool = .select
		session.select(highlight, on: page)
		session.deleteSelection()
		XCTAssertNil(session.selection)
		XCTAssertFalse(page.annotations.contains { $0 === highlight })
		session.undo()
		XCTAssertTrue(page.annotations.contains { $0 === highlight })
	}

	func testRecoloringFromTheColorWellIsOneUndoStep() throws {
		let (session, page) = try makeSession()
		let ink = try XCTUnwrap(PDFMarkupFactory.ink([CGPoint(x: 100, y: 100), CGPoint(x: 160, y: 120)], color: .black, width: 3))
		session.add([ink], on: page)
		session.tool = .select
		session.select(ink, on: page)
		for rgb: UInt32 in [0x110000, 0x330000, 0x550000, 0x770000] {
			session.selectColor(.custom(rgb))
		}
		XCTAssertEqual(ink.color.markRGB, 0x770000)
		XCTAssertEqual(session.selectionStyle?.color, .custom(0x770000))
		session.undo()
		XCTAssertEqual(ink.color.markRGB, 0x000000, "the whole drag across the well undoes at once")
		XCTAssertTrue(page.annotations.contains { $0 === ink }, "and the mark is still there")
	}

	func testHighlighterStrokesStaySeeThroughWhenRecolored() throws {
		let (session, page) = try makeSession()
		let stroke = try XCTUnwrap(PDFMarkupFactory.ink([CGPoint(x: 100, y: 100), CGPoint(x: 200, y: 100)], color: .yellow, width: 14,
														alpha: PDFMarkupPalette.highlighterAlpha))
		session.add([stroke], on: page)
		session.tool = .select
		session.select(stroke, on: page)
		XCTAssertEqual(session.currentStyleGroup, .highlighter)
		session.selectColor(.swatch(2))
		XCTAssertEqual(stroke.color.cgColor.alpha, PDFMarkupPalette.highlighterAlpha, accuracy: 0.01)
	}

	func testThickerStrokesKeepTheirMarkInPlace() throws {
		let (session, page) = try makeSession()
		let line = try XCTUnwrap(PDFMarkupFactory.shape(.arrow, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 200, y: 150), color: .red, width: 2))
		let ink = try XCTUnwrap(PDFMarkupFactory.ink([CGPoint(x: 300, y: 300), CGPoint(x: 350, y: 320)], color: .black, width: 2))
		session.add([line, ink], on: page)
		session.tool = .select
		session.select(line, on: page)
		session.selectSize(8)
		XCTAssertEqual(line.border?.lineWidth, 8)
		XCTAssertEqual(line.bounds.minX + line.startPoint.x, 100, accuracy: 0.01)
		XCTAssertEqual(line.bounds.minY + line.endPoint.y, 150, accuracy: 0.01)
		session.select(ink, on: page)
		session.selectSize(6)
		let path = try XCTUnwrap(ink.paths?.first)
		XCTAssertEqual(path.bounds.minX + ink.bounds.minX, 300, accuracy: 0.5)
		XCTAssertEqual(path.bounds.maxY + ink.bounds.minY, 320, accuracy: 0.5)
	}

	func testTextBoxesRefitWhenTheirTextOrSizeChanges() throws {
		let (session, page) = try makeSession()
		let crop = page.bounds(for: .cropBox)
		let box = PDFMarkupFactory.textBox(at: CGPoint(x: 100, y: 500), text: "Hi", color: .black, fontSize: 12, pageBounds: crop)
		session.add([box], on: page)
		let small = box.bounds
		session.setContents(of: box, to: "A much longer note that needs more room on the page")
		XCTAssertGreaterThan(box.bounds.width, small.width)
		XCTAssertEqual(box.bounds.maxY, small.maxY, accuracy: 0.5, "the top stays put")
		session.undo()
		XCTAssertEqual(box.contents, "Hi")
		XCTAssertEqual(box.bounds, small)
		session.tool = .select
		session.select(box, on: page)
		session.selectSize(32)
		XCTAssertEqual(box.font?.pointSize, 32)
		XCTAssertGreaterThan(box.bounds.height, small.height)
	}

	func testMovedMarksStayWhereTheyWereMovedThroughASave() throws {
		let (session, page) = try makeSession()
		let ink = try XCTUnwrap(PDFMarkupFactory.ink([CGPoint(x: 100, y: 100), CGPoint(x: 150, y: 130)], color: .black, width: 3))
		let line = try XCTUnwrap(PDFMarkupFactory.shape(.line, from: CGPoint(x: 300, y: 300), to: CGPoint(x: 400, y: 340), color: .red, width: 2))
		session.add([ink, line], on: page)
		session.tool = .select
		for mark in [ink, line] {
			session.select(mark, on: page)
			session.moveSelection(by: CGVector(dx: 60, dy: 200))
		}
		let reopened = try XCTUnwrap(PDFDocument(data: try XCTUnwrap(session.document.dataRepresentation())))
		let marks = try XCTUnwrap(reopened.page(at: 0)).annotations
		let savedInk = try XCTUnwrap(marks.first { $0.type == "Ink" })
		let savedPath = try XCTUnwrap(savedInk.paths?.first)
		XCTAssertEqual(savedPath.bounds.minX + savedInk.bounds.minX, 160, accuracy: 1)
		XCTAssertEqual(savedPath.bounds.minY + savedInk.bounds.minY, 300, accuracy: 1)
		let savedLine = try XCTUnwrap(marks.first { $0.type == "Line" })
		XCTAssertEqual(savedLine.startPoint.x + savedLine.bounds.minX, 360, accuracy: 1)
		XCTAssertEqual(savedLine.endPoint.y + savedLine.bounds.minY, 540, accuracy: 1)
	}

	func testTheSelectionGoesWhenItsMarkOrTheToolDoes() throws {
		let (session, page) = try makeSession()
		let box = try XCTUnwrap(PDFMarkupFactory.shape(.ellipse, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 200, y: 200), color: .red, width: 2))
		session.add([box], on: page)
		session.tool = .select
		session.select(box, on: page)
		session.undo()
		XCTAssertNil(session.selection, "undoing the mark drops it")
		session.redo()
		session.select(box, on: page)
		session.tool = .pen
		XCTAssertNil(session.selection)
	}

	// MARK: Note margin

	func testMarginSidesFollowThePagesRotation() {
		XCTAssertEqual(PDFNoteMargin.left.edge(rotation: 0), .minX)
		XCTAssertEqual(PDFNoteMargin.right.edge(rotation: 0), .maxX)
		XCTAssertEqual(PDFNoteMargin.left.edge(rotation: 90), .minY, "turned clockwise, the bottom shows on the left")
		XCTAssertEqual(PDFNoteMargin.right.edge(rotation: 90), .maxY)
		XCTAssertEqual(PDFNoteMargin.left.edge(rotation: 180), .maxX)
		XCTAssertEqual(PDFNoteMargin.left.edge(rotation: 270), .maxY)
		XCTAssertEqual(PDFNoteMargin.right.edge(rotation: -90), .minY)

		let box = CGRect(x: 0, y: 0, width: 600, height: 800)
		for rotation in [0, 90, 180, 270] {
			for side in PDFNoteMargin.allCases {
				let (grown, strip) = side.expand(box, rotation: rotation)
				let shown = rotation % 180 == 0 ? box.width : box.height
				XCTAssertEqual(rotation % 180 == 0 ? strip.width : strip.height, shown * PDFNoteMargin.widthFraction, accuracy: 0.01)
				XCTAssertEqual(PDFNoteMargin.side(of: strip, in: grown, rotation: rotation), side, "\(side) at \(rotation)°")
				XCTAssertEqual(PDFNoteMargin.shrink(grown, removing: strip), box)
			}
		}
		XCTAssertNil(PDFNoteMargin.shrink(box, removing: CGRect(x: 100, y: 100, width: 50, height: 50)), "not along an edge")
	}

	func testMarginsSavedBeforeTheRenameAreStillFound() {
		let panel = PDFNoteMargin.panel(filling: CGRect(x: 612, y: 0, width: 306, height: 792))
		XCTAssertTrue(PDFNoteMargin.isPanel(panel))
		panel.userName = PDFNoteMargin.earlierPanelName
		XCTAssertTrue(PDFNoteMargin.isPanel(panel), "PDFs saved under the old name keep their margin")
		panel.userName = "Someone's square"
		XCTAssertFalse(PDFNoteMargin.isPanel(panel))
	}

	func testMarginOnEveryPageMovesAndGoesInOneUndoStepEach() throws {
		let (session, page) = try makeSession(pages: 2)
		let original = PDFPageBoxes(of: page)
		session.setNoteMargin(.right)
		XCTAssertEqual(page.bounds(for: .cropBox).width, original.crop.width * 1.5, accuracy: 0.01)
		XCTAssertEqual(session.document.page(at: 1)?.bounds(for: .mediaBox).width ?? 0, original.media.width * 1.5, accuracy: 0.01)
		XCTAssertEqual(session.currentNoteMargin, .right)
		let panel = try XCTUnwrap(page.annotations.first(where: PDFNoteMargin.isPanel))
		XCTAssertFalse(PDFMarkupFactory.isErasable(panel), "the eraser and the pointer leave the margin alone")
		XCTAssertNil(session.mark(at: CGPoint(x: panel.bounds.midX, y: panel.bounds.midY), on: page))

		let note = try XCTUnwrap(PDFMarkupFactory.ink([CGPoint(x: panel.bounds.midX, y: 400), CGPoint(x: panel.bounds.midX + 40, y: 420)],
													  color: .black, width: 2))
		session.add([note], on: page)
		XCTAssertEqual(session.marksInNoteMargins, 1)

		session.setNoteMargin(.left)
		XCTAssertEqual(session.currentNoteMargin, .left)
		XCTAssertEqual(page.bounds(for: .cropBox).minX, original.crop.minX - original.crop.width * 0.5, accuracy: 0.01)
		XCTAssertFalse(page.annotations.contains { $0 === note }, "what was written in the old margin goes with it")
		XCTAssertEqual(page.annotations.filter(PDFNoteMargin.isPanel).count, 1)

		session.undo()
		XCTAssertEqual(session.currentNoteMargin, .right)
		XCTAssertTrue(page.annotations.contains { $0 === note })

		session.setNoteMargin(nil)
		XCTAssertNil(session.currentNoteMargin)
		XCTAssertEqual(PDFPageBoxes(of: page), original)
		XCTAssertTrue(page.annotations.isEmpty)
		session.undo()
		XCTAssertEqual(session.currentNoteMargin, .right, "the margin and its note are back")
		XCTAssertTrue(page.annotations.contains { $0 === note })
		session.undo()
		session.undo()
		XCTAssertNil(session.currentNoteMargin, "back to how it opened")
		XCTAssertEqual(PDFPageBoxes(of: page), original)
	}

	func testMarginSurvivesASaveAndIsFoundAgain() throws {
		let (session, _) = try makeSession(pages: 2)
		session.setNoteMargin(.left)
		let data = try XCTUnwrap(session.document.dataRepresentation())
		let reopened = try XCTUnwrap(PDFDocument(data: data))
		let again = PDFEditSession(item: Self.item, document: reopened, report: PDFFormatReport(), originalReport: PDFFormatReport())
		let page = try XCTUnwrap(reopened.page(at: 1))
		XCTAssertEqual(page.bounds(for: .mediaBox).width, 612 * 1.5, accuracy: 0.5)
		XCTAssertEqual(again.noteMargin(on: page), .left)
		again.setNoteMargin(nil)
		XCTAssertEqual(page.bounds(for: .mediaBox).width, 612, accuracy: 0.5)
	}

	func testMarginOnATurnedPageGrowsTheEdgeThatShowsOnThatSide() throws {
		let (session, page) = try makeSession()
		page.rotation = 90
		let before = page.bounds(for: .cropBox)
		session.setNoteMargin(.left)
		let after = page.bounds(for: .cropBox)
		XCTAssertEqual(after.minY, before.minY - before.height * 0.5, accuracy: 0.01, "the bottom edge shows on the left")
		XCTAssertEqual(after.width, before.width, accuracy: 0.01)
		XCTAssertEqual(session.noteMargin(on: page), .left)
	}

	// MARK: Apple Pencil

	func testOnlyAnIPadWithApplePencilLeavesScrollingToFingers() {
		XCTAssertFalse(PDFMarkupInput.pencilOnly(idiom: .phone, choice: true, pencilSeen: true, systemPrefersPencil: true), "an iPhone has no Apple Pencil")
		XCTAssertFalse(PDFMarkupInput.pencilOnly(idiom: .pad, choice: nil, pencilSeen: false, systemPrefersPencil: false), "no pencil yet: fingers draw")
		XCTAssertTrue(PDFMarkupInput.pencilOnly(idiom: .pad, choice: nil, pencilSeen: true, systemPrefersPencil: false), "once the pencil is used")
		XCTAssertTrue(PDFMarkupInput.pencilOnly(idiom: .pad, choice: nil, pencilSeen: false, systemPrefersPencil: true), "Only Draw with Apple Pencil")
		XCTAssertFalse(PDFMarkupInput.pencilOnly(idiom: .pad, choice: false, pencilSeen: true, systemPrefersPencil: true), "the reader's choice wins")
		XCTAssertTrue(PDFMarkupInput.pencilOnly(idiom: .pad, choice: true, pencilSeen: false, systemPrefersPencil: false))
		XCTAssertFalse(PDFMarkupInput.pencilOnly(idiom: .mac, choice: nil, pencilSeen: true, systemPrefersPencil: true), "a Mac's pointer draws")
	}

	func testPencilDoubleTapSwitchesToTheEraserAndBack() throws {
		let (session, _) = try makeSession()
		session.tool = .pen
		session.pencilDoubleTapped(switchesToEraser: true)
		XCTAssertEqual(session.tool, .eraser)
		session.pencilDoubleTapped(switchesToEraser: true)
		XCTAssertEqual(session.tool, .pen)
		session.tool = .highlighter
		session.pencilDoubleTapped(switchesToEraser: false)
		XCTAssertEqual(session.tool, .pen, "or to the tool before")
	}

	// MARK: Background saving

	func testASnapshotKeepsBookmarksAndIsUntouchedByLaterEdits() throws {
		let (session, page) = try makeSession(pages: 3)
		let document = session.document
		let root = PDFOutline()
		for index in 0..<3 {
			let entry = PDFOutline()
			entry.label = "Chapter \(index + 1)"
			entry.destination = document.page(at: index).map { PDFDestination(page: $0, at: CGPoint(x: 0, y: 700)) }
			root.insertChild(entry, at: index)
		}
		document.outlineRoot = root
		session.add([try XCTUnwrap(PDFMarkupFactory.ink([CGPoint(x: 10, y: 10), CGPoint(x: 60, y: 40)], color: .red, width: 2))], on: page)

		let snapshot = try XCTUnwrap(PDFEditSession.snapshot(of: document))
		session.add([try XCTUnwrap(PDFMarkupFactory.ink([CGPoint(x: 100, y: 100), CGPoint(x: 160, y: 140)], color: .blue, width: 2))], on: page)
		XCTAssertEqual(snapshot.page(at: 0)?.annotations.count, 1, "edits after the snapshot aren't in it")
		XCTAssertFalse(snapshot.page(at: 0) === page)

		let reopened = try XCTUnwrap(PDFDocument(data: try XCTUnwrap(snapshot.dataRepresentation())))
		let outline = try XCTUnwrap(reopened.outlineRoot)
		XCTAssertEqual(outline.numberOfChildren, 3, "PDFKit's own copy drops the bookmarks; the snapshot keeps them")
		let third = try XCTUnwrap(outline.child(at: 2))
		XCTAssertEqual(third.label, "Chapter 3")
		XCTAssertEqual(third.destination?.page.map { reopened.index(for: $0) }, 2)
	}

	func testEditsMadeWhileSavingAreSavedNextTime() async throws {
		let folder = FileManager.default.temporaryDirectory.appendingPathComponent("BackgroundSave-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: folder) }
		let library = PDFLibrary(root: folder.appendingPathComponent("PDFs"))
		let item = try library.add(TestPDF.quartz(pages: 2) { TestPDF.draw("Save me", in: $0) }, title: "Save me")
		let session = try XCTUnwrap(PDFEditSession.open(item, in: library))
		let page = try XCTUnwrap(session.document.page(at: 0))
		session.add([PDFMarkupFactory.note(at: CGPoint(x: 72, y: 700), text: "First", color: .orange)], on: page)

		let saving = Task { try await session.save(in: library) }
		await Task.yield()
		session.add([PDFMarkupFactory.note(at: CGPoint(x: 72, y: 600), text: "Second", color: .orange)], on: page)
		try await session.save(in: library)
		try await saving.value
		XCTAssertFalse(session.needsSave)
		XCTAssertFalse(session.isSaving)

		await library.waitForSave(of: item.id)
		let saved = try XCTUnwrap(PDFDocument(url: library.currentURL(for: try XCTUnwrap(library.item(item.id)))))
		XCTAssertEqual(Set(saved.page(at: 0)?.annotations.compactMap(\.contents) ?? []), ["First", "Second"])
	}

	func testReadersWaitForASaveUnderWay() async throws {
		let folder = FileManager.default.temporaryDirectory.appendingPathComponent("WaitForSave-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: folder) }
		let library = PDFLibrary(root: folder.appendingPathComponent("PDFs"))
		let item = try library.add(TestPDF.quartz { TestPDF.draw("Wait", in: $0) }, title: "Wait")
		let session = try XCTUnwrap(PDFEditSession.open(item, in: library))
		session.add([PDFMarkupFactory.note(at: CGPoint(x: 72, y: 700), text: "Kept", color: .orange)], on: try XCTUnwrap(session.document.page(at: 0)))
		let saving = Task { try await session.save(in: library) }
		await Task.yield()
		await library.waitForSave(of: item.id)
		let reopened = try XCTUnwrap(PDFEditSession.open(try XCTUnwrap(library.item(item.id)), in: library))
		XCTAssertEqual(reopened.document.page(at: 0)?.annotations.first?.contents, "Kept", "reopening sees the save that was under way")
		try await saving.value
	}

	// MARK: Thumbnails

	func testOnlyPagesThatChangeGetNewThumbnails() throws {
		let (session, page) = try makeSession(pages: 3)
		let other = try XCTUnwrap(session.document.page(at: 1))
		XCTAssertEqual(session.version(of: page), 0)
		session.add([try XCTUnwrap(PDFMarkupFactory.ink([CGPoint(x: 10, y: 10), CGPoint(x: 60, y: 40)], color: .red, width: 2))], on: page)
		let marked = session.version(of: page)
		XCTAssertNotEqual(marked, 0)
		XCTAssertEqual(session.version(of: other), 0, "marking one page leaves the others' thumbnails")
		session.movePage(from: 0, to: 2)
		XCTAssertEqual(session.version(of: page), marked, "moving a page doesn't change how it looks")
		XCTAssertEqual(session.document.index(for: other), 0)
		session.rotate([0], degrees: 90)
		XCTAssertNotEqual(session.version(of: other), 0)
		session.undo()
		session.undo()
		session.undo()
		XCTAssertNotEqual(session.version(of: page), marked, "undoing a mark changes the page again")
	}

	func testThumbnailsDrawOffTheMainThreadFromAPageCopy() async throws {
		let (session, page) = try makeSession()
		page.rotation = 90
		let copy = try XCTUnwrap(page.copy() as? PDFPage)
		let rendered = await PDFThumbnailRenderer.shared.render(copy, size: CGSize(width: 320, height: 248))
		let image = try XCTUnwrap(rendered)
		XCTAssertGreaterThan(image.size.width, image.size.height, "a turned page draws turned")
		XCTAssertEqual(session.document.page(at: 0)?.rotation, 90, "the open page is untouched")
	}

	// MARK: With marks

	func testWithMarksFindsMarkedPagesButNotLinksFormsOrTheMargin() throws {
		let (session, _) = try makeSession(pages: 4)
		let pages = (0..<4).compactMap { session.document.page(at: $0) }
		pages[0].addAnnotation(PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 50, height: 20), forType: .link, withProperties: nil))
		pages[1].addAnnotation(PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 50, height: 20), forType: .widget, withProperties: nil))
		session.add([PDFMarkupFactory.note(at: CGPoint(x: 72, y: 700), text: "Here", color: .orange)], on: pages[2])
		pages[3].addAnnotation(PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 50, height: 20), forType: .stamp, withProperties: nil))
		XCTAssertEqual(session.markedPageIndexes, [2, 3], "Rescriva's notes and other apps' stamps count")
		session.setNoteMargin(.right)
		XCTAssertEqual(session.markedPageIndexes, [2, 3], "a margin alone isn't a mark")
		session.movePage(from: 2, to: 0)
		XCTAssertEqual(session.markedPageIndexes, [0, 3], "it follows the pages as they move")
	}

	// MARK: Helpers

	private static let item = PDFItem(id: UUID(), title: "T", sourceName: "T.pdf", importedAt: Date(), pageCount: 1, byteCount: 0)

	private func makeSession(pages: Int = 1) throws -> (PDFEditSession, PDFPage) {
		let document = PDFDocument()
		for index in 0..<pages {
			let data = TestPDF.quartz { TestPDF.draw("Page \(index + 1) for markup", in: $0) }
			let page = try XCTUnwrap(PDFDocument(data: data)?.page(at: 0))
			document.insert(page, at: index)
		}
		let session = PDFEditSession(item: Self.item, document: document, report: PDFFormatReport(), originalReport: PDFFormatReport())
		return (session, try XCTUnwrap(document.page(at: 0)))
	}
}
