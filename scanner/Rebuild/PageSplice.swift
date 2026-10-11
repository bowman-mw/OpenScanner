//
//  PageSplice.swift
//  Folio (fork of Open Scanner)
//
//  Re-making one page (PageReprocessor) redoes only that page of the scan's
//  rebuilt document. The page is marked stale at once; when its text has
//  been read again, Rebuilder rebuilds it through the same steps as a whole
//  rebuild, and this splices it in where the old one was. Every other page
//  keeps its content, notes, flags and text fingerprint.
//
//  On the new page, what still applies comes across and nothing else:
//    - the page's own notes;
//    - a block's notes and word choices, when the block reads exactly as it
//      did (word for word, with the choices undone) and it's the only block
//      on either page that reads that way. Word choices also need the same
//      uncertain words to come up again, in the same order.
//    - drawings made in Recreate, whole, with their notes, after what was
//      read: the user's own work, which no rebuild makes again.
//  The user's notes are never dropped: a note on a block that has no such
//  match (its words were read a little differently, or it was a figure)
//  becomes a page note, led by the block's first words. Word choices on
//  words that are gone are dropped, and so is the old page's formatting.
//  When the page gains or loses a diagram, the figures after it are
//  numbered again, as a whole rebuild would number them (a Recreate
//  drawing is counted but keeps its caption).
//
//  A spread split in two (the page editor) goes the same way: the page and
//  a copy of it for the new page after it are both marked stale, and each
//  half takes what still applies from the page it came from. A block note
//  that matches on neither half becomes a page note on the half spliced
//  last, so it isn't kept twice, and a Recreate drawing lands there too.
//

import Foundation

/// Splices a page rebuilt from re-made pixels into a rebuilt document (see the file header).
enum PageSplice {

	// MARK: Marking

	/// Where `captureID`'s page sits in `document`, when the document was rebuilt from exactly
	/// `captureIDs` (the scan's pages now, in order), one page each; nil otherwise. Such a
	/// document gets rebuilt whole anyway, so there's nothing to splice into.
	static func pageIndex(of captureID: UUID, in document: FolioDocument, captureIDs: [UUID]) -> Int? {
		guard let sources = document.sourceCaptureIDs, sources == captureIDs,
			  sources.count == document.pages.count else { return nil }
		return sources.firstIndex(of: captureID)
	}

	/// `document` with `captureID`'s page marked stale, to be rebuilt once the page has been read
	/// again; nil when it can't be spliced later (see `pageIndex`). The page's text fingerprint
	/// goes now: its lines are being read again, and until the new page lands the PDF's text layer
	/// keeps them as read.
	static func markingStale(_ captureID: UUID, in document: FolioDocument, captureIDs: [UUID]) -> FolioDocument? {
		guard let index = pageIndex(of: captureID, in: document, captureIDs: captureIDs) else { return nil }
		var result = document
		result.pages[index].sourceTextDigest = nil
		let stale = document.staleCaptureIDs ?? []
		result.staleCaptureIDs = stale.contains(captureID) ? stale : stale + [captureID]
		return result
	}

	/// `document` with `captureID`'s page split in two, as the scan's pages were (a spread split in
	/// the page editor): the page stays where it was for the first half, and a copy of it follows for
	/// `newID`, both stale, to be rebuilt once their pages have been read and spliced in as a re-made
	/// page is. The first keeps the page's identity and notes; the copy gets neither, but takes the
	/// block notes and word choices of the blocks that land on its half. `captureIDs` are the scan's
	/// pages before the split. Nil when the document can't take spliced pages (see `pageIndex`).
	static func splitting(_ captureID: UUID, adding newID: UUID, in document: FolioDocument, captureIDs: [UUID]) -> FolioDocument? {
		guard !captureIDs.contains(newID), let index = pageIndex(of: captureID, in: document, captureIDs: captureIDs) else { return nil }
		var result = document
		result.pages[index].sourceTextDigest = nil
		var copy = result.pages[index]
		copy.id = UUID()
		copy.notes = []
		result.pages.insert(copy, at: index + 1)
		var sources = captureIDs
		sources.insert(newID, at: index + 1)
		result.sourceCaptureIDs = sources
		let stale = (document.staleCaptureIDs ?? []).filter { $0 != captureID }
		result.staleCaptureIDs = stale + [captureID, newID]
		assert(result.pages.count == sources.count, "one page per capture")
		return result
	}

	// MARK: Splicing

	/// `document` with `rebuilt` in place of `captureID`'s stale page, carrying over what still
	/// applies (`carryingReview`), and that page no longer stale. Nil when the page isn't stale any
	/// more (another rebuild of it landed first) or the document no longer matches the scan's
	/// pages; the caller then writes nothing.
	static func splicing(_ rebuilt: FolioPage, for captureID: UUID, into document: FolioDocument,
						 captureIDs: [UUID]) -> FolioDocument? {
		guard document.staleCaptureIDs?.contains(captureID) == true,
			  let index = pageIndex(of: captureID, in: document, captureIDs: captureIDs),
			  let old = document.pages[safe: index] else { return nil }
		var result = document
		// A split's other half, still stale, may yet take this page's block notes and drawings.
		let others = document.pages.indices.filter { $0 != index }.map { document.pages[$0] }
		let page = carryingReview(from: old, to: rebuilt, notesElsewhere: Set(others.flatMap { noteIDs(on: $0) }),
								  blocksElsewhere: Set(others.flatMap { $0.blocks.map(\.id) }))
		result.pages[index] = page
		let remaining = (document.staleCaptureIDs ?? []).filter { $0 != captureID }
		result.staleCaptureIDs = remaining.isEmpty ? nil : remaining
		return numberingFigures(in: result, from: index, renumberingLater: diagramCount(old) != diagramCount(page))
	}

	// MARK: Figures

	/// Diagrams on `page`.
	static func diagramCount(_ page: FolioPage) -> Int {
		page.blocks.filter { block in
			if case .diagram = block.content { return true }
			return false
		}.count
	}

	/// `document` with the diagrams on page `index` numbered on from the pages before it, as a whole
	/// rebuild numbers them, and when `renumberingLater` (the page gained or lost one) the diagrams
	/// on every later page too. A Recreate drawing counts but keeps its caption (often the figure's,
	/// read from the page). Nothing else on other pages changes.
	static func numberingFigures(in document: FolioDocument, from index: Int, renumberingLater: Bool) -> FolioDocument {
		guard document.pages.indices.contains(index) else { return document }
		var result = document
		var number = document.pages[..<index].map(diagramCount).reduce(0, +)
		let last = renumberingLater ? document.pages.count - 1 : index
		for pageIndex in index...last {
			let source = result.pages[pageIndex].source
			for blockIndex in result.pages[pageIndex].blocks.indices {
				let block = result.pages[pageIndex].blocks[blockIndex]
				guard case .diagram(var diagram) = block.content else { continue }
				number += 1
				guard !isUserDrawing(block) else { continue }
				diagram.caption = Rebuilder.figureCaption(number, source: source)
				result.pages[pageIndex].blocks[blockIndex].content = .diagram(diagram)
			}
		}
		return result
	}

	// MARK: Carrying Review work

	/// `new`, the page rebuilt from re-made pixels, with what still applies from `old`, the page it
	/// replaces: its identity and page notes, and for each block that reads exactly as before (and
	/// is the only one that does, on either page) that block's notes and word choices, and its
	/// Recreate drawings whole, after what was read. The notes on the other blocks become page
	/// notes (`pageNote`), except those in `notesElsewhere`; drawings in `blocksElsewhere` stay out
	/// too (both are held by another page, the other half of a split). The rest of `old`'s Review
	/// work, formatting included, is dropped.
	static func carryingReview(from old: FolioPage, to new: FolioPage, notesElsewhere: Set<UUID> = [],
							   blocksElsewhere: Set<UUID> = []) -> FolioPage {
		var result = new
		result.id = old.id
		result.notes = old.notes
		let oldKeys = old.blocks.map { readingKey($0.content) }
		let newKeys = new.blocks.map { readingKey($0.content) }
		let oldCounts = Dictionary(oldKeys.map { ($0, 1) }, uniquingKeysWith: +)
		let newCounts = Dictionary(newKeys.map { ($0, 1) }, uniquingKeysWith: +)
		var carried: Set<UUID> = []
		for (oldIndex, block) in old.blocks.enumerated() where hasReviewWork(block) {
			let key = oldKeys[oldIndex]
			guard key.contains(where: { $0.isLetter || $0.isNumber }), oldCounts[key] == 1, newCounts[key] == 1,
				  let newIndex = newKeys.firstIndex(of: key) else { continue }
			result.blocks[newIndex] = carrying(block, onto: result.blocks[newIndex])
			carried.formUnion(block.notes.map(\.id))
		}
		for block in old.blocks where isUserDrawing(block) && !blocksElsewhere.contains(block.id) {
			result.blocks.append(block)
			carried.formUnion(block.notes.map(\.id))
		}
		for block in old.blocks {
			for note in block.notes where !carried.contains(note.id) && !notesElsewhere.contains(note.id) {
				result.notes.append(pageNote(note, from: block))
			}
		}
		return result
	}

	/// `note`, from a block with no match on the new page, as a page note: anchored to no word, and
	/// led by the block's first words, so it still says what it was about.
	static func pageNote(_ note: FolioNote, from block: FolioBlock) -> FolioNote {
		var moved = note
		moved.runID = nil
		let words = block.content.plainText.split(whereSeparator: \.isWhitespace)
		guard !words.isEmpty else { return moved }
		let quote = words.prefix(6).joined(separator: " ") + (words.count > 6 ? "…" : "")
		moved.text = String(localized: "On “\(quote)”: \(note.text)")
		return moved
	}

	/// A diagram drawn in Recreate, which marks what it writes as the user's.
	static func isUserDrawing(_ block: FolioBlock) -> Bool {
		guard case .diagram = block.content else { return false }
		return block.provenance?.engine == "user"
	}

	/// The ids of every note on `page`, its own and its blocks'.
	static func noteIDs(on page: FolioPage) -> [UUID] {
		page.notes.map(\.id) + page.blocks.flatMap { $0.notes.map(\.id) }
	}

	/// True when Review left something on the block that could come across: notes or a word choice.
	static func hasReviewWork(_ block: FolioBlock) -> Bool {
		!block.notes.isEmpty || block.content.flags.contains { $0.kind == .word && $0.resolution != nil }
	}

	/// The block's words as recognition read them (a word chosen in Review reads back as what was
	/// read): one line per paragraph, list item or table cell, white space collapsed. Empty for
	/// equations, figures and diagrams, which never match.
	static func readingKey(_ content: BlockContent) -> String {
		let groups: [[FolioRun]]
		switch content {
		case .heading(_, let runs), .paragraph(let runs, _):
			groups = [runs]
		case .list(_, let items):
			groups = items.map(\.runs)
		case .table(let rows):
			groups = rows.flatMap { $0.map(\.runs) }
		case .equation, .figure, .diagram:
			return ""
		}
		return groups.map { runs in
			runs.map(asRead).joined().split(whereSeparator: \.isWhitespace).joined(separator: " ")
		}.joined(separator: "\n")
	}

	/// A run's text as read: a resolved word flag reads back as what was read.
	static func asRead(_ run: FolioRun) -> String {
		guard let flag = run.flag, flag.kind == .word, flag.resolution != nil else { return run.text }
		return flag.read
	}

	/// `new`, which reads like `old`, with `old`'s notes (re-anchored) and word choices.
	static func carrying(_ old: FolioBlock, onto new: FolioBlock) -> FolioBlock {
		var result = new
		let oldRuns = FolioRunLookup.allRuns(in: old.content)
		let newRuns = FolioRunLookup.allRuns(in: new.content)
		result.notes = old.notes.map { reanchored($0, from: oldRuns, to: newRuns) }
		result.content = carryingChoices(from: old.content, onto: new.content)
		return result
	}

	/// A note anchored to a word moves to the new run that reads the same, when exactly one does;
	/// otherwise it stays on the block, whose words are all still there.
	static func reanchored(_ note: FolioNote, from oldRuns: [FolioRun], to newRuns: [FolioRun]) -> FolioNote {
		guard let runID = note.runID else { return note }
		var moved = note
		moved.runID = nil
		guard let run = oldRuns.first(where: { $0.id == runID }) else { return moved }
		let read = asRead(run)
		let matches = newRuns.filter { asRead($0) == read }
		guard matches.count == 1, let match = matches.first else { return moved }
		moved.runID = match.id
		return moved
	}

	/// `new` with the word choices made on `old`, when both came up with the same uncertain words in
	/// the same order; `new` unchanged otherwise.
	static func carryingChoices(from old: BlockContent, onto new: BlockContent) -> BlockContent {
		let oldFlags = old.flags.filter { $0.kind == .word }
		let newFlags = new.flags.filter { $0.kind == .word }
		guard oldFlags.contains(where: { $0.resolution != nil }),
			  oldFlags.map(\.read) == newFlags.map(\.read) else { return new }
		var result = new
		for (oldFlag, newFlag) in zip(oldFlags, newFlags) {
			guard let choice = oldFlag.resolution else { continue }
			result.resolveFlag(newFlag.id, option: nil, typed: choice)
		}
		return result
	}
}
