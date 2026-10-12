//
//  DocumentEditing.swift
//  Rescriva (fork of Open Scanner)
//
//  The review screen's edits, as pure changes to the RescrivaDocument: resolve a
//  flag, toggle bold/italic/underline, switch heading ↔ paragraph, tick a
//  checkbox, add or remove a note, remove a wrong figure. Every export
//  afterwards includes them.
//

import Foundation

/// Bold, italic or underline.
enum RunStyle: CaseIterable {
	case bold, italic, underline

	var keyPath: WritableKeyPath<RescrivaRun, Bool> {
		switch self {
		case .bold: return \.bold
		case .italic: return \.italic
		case .underline: return \.underline
		}
	}
}

extension RescrivaDocument {
	/// Finds a block by ID.
	func block(_ id: UUID) -> RescrivaBlock? {
		for page in pages {
			if let block = page.blocks.first(where: { $0.id == id }) { return block }
		}
		return nil
	}

	/// The flag with `id`, wherever it lives.
	func flag(_ id: UUID) -> RescrivaFlag? {
		for page in pages {
			for block in page.blocks {
				if let flag = block.content.flags.first(where: { $0.id == id }) { return flag }
			}
		}
		return nil
	}

	/// Applies `change` to the block with `id`.
	mutating func updateBlock(_ id: UUID, _ change: (inout RescrivaBlock) -> Void) {
		for pageIndex in pages.indices {
			if let blockIndex = pages[pageIndex].blocks.firstIndex(where: { $0.id == id }) {
				change(&pages[pageIndex].blocks[blockIndex])
				return
			}
		}
	}

	/// Removes the figure with `id`. The words read inside it and its caption come back as
	/// paragraphs where it was (the caption just below), so removing a wrong figure never loses
	/// text from the page, and the notes on it go to the first of them (to the page when there are
	/// none). Other blocks are left alone.
	mutating func removeFigure(_ id: UUID) {
		for pageIndex in pages.indices {
			guard let blockIndex = pages[pageIndex].blocks.firstIndex(where: { $0.id == id }) else { continue }
			let block = pages[pageIndex].blocks[blockIndex]
			guard case .figure(_, let caption, let altText) = block.content else { return }
			var restored: [RescrivaBlock] = []
			if let altText, !altText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
				restored.append(Self.restoredParagraph(altText, box: block.box))
			}
			if let caption, !caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
				restored.append(Self.restoredParagraph(caption, box: block.box.map(Self.captionBox(below:))))
			}
			// A figure has no words to anchor a note to, but clear the anchor all the same.
			let notes = block.notes.map { note in
				var note = note
				note.runID = nil
				return note
			}
			if restored.isEmpty {
				pages[pageIndex].notes += notes
			} else {
				restored[0].notes = notes
			}
			pages[pageIndex].blocks.replaceSubrange(blockIndex...blockIndex, with: restored)
			return
		}
	}

	private static func restoredParagraph(_ text: String, box: NormalizedBox?) -> RescrivaBlock {
		RescrivaBlock(content: .paragraph(runs: [RescrivaRun(text: text)], alignment: .leading), box: box,
				   provenance: Provenance(engine: "user", confidence: 1))
	}

	/// A one-line strip just below `box`, kept on the page: where a figure's caption most often sat.
	static func captionBox(below box: NormalizedBox) -> NormalizedBox {
		let height = 0.03
		let y = min(box.y + box.height + 0.005, 1 - height)
		return NormalizedBox(x: box.x, y: max(0, y), width: box.width, height: height)
	}

	/// Resolves a flag with one of its options, or with text the user typed.
	mutating func resolveFlag(_ id: UUID, option: RescrivaFlag.Option? = nil, typed: String? = nil) {
		for pageIndex in pages.indices {
			for blockIndex in pages[pageIndex].blocks.indices {
				pages[pageIndex].blocks[blockIndex].content.resolveFlag(id, option: option, typed: typed)
			}
		}
	}
}

extension BlockContent {
	/// True when the block holds styled text the format buttons can change.
	var hasRuns: Bool {
		switch self {
		case .heading, .paragraph, .list, .table: return true
		case .equation, .figure, .diagram: return false
		}
	}

	var isHeading: Bool {
		if case .heading = self { return true }
		return false
	}

	var isFigure: Bool {
		if case .figure = self { return true }
		return false
	}

	/// True when every run in the block has `style` (and there is at least one).
	func allRuns(_ style: RunStyle) -> Bool {
		let runs = allRuns.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
		return !runs.isEmpty && runs.allSatisfy { $0[keyPath: style.keyPath] }
	}

	private var allRuns: [RescrivaRun] {
		switch self {
		case .heading(_, let runs), .paragraph(let runs, _): return runs
		case .list(_, let items): return items.flatMap(\.runs)
		case .table(let rows): return rows.flatMap { $0.flatMap(\.runs) }
		default: return []
		}
	}

	/// Sets `style` on every run.
	mutating func setStyle(_ style: RunStyle, to value: Bool) {
		mapRuns { runs in
			runs.map { run in
				var run = run
				run[keyPath: style.keyPath] = value
				return run
			}
		}
	}

	/// Paragraph → heading (level 2); heading → paragraph.
	mutating func toggleHeading() {
		switch self {
		case .heading(_, let runs):
			self = .paragraph(runs: runs, alignment: .leading)
		case .paragraph(let runs, _):
			self = .heading(level: 2, runs: runs)
		default:
			break
		}
	}

	/// Ticks or unticks a checkbox item.
	mutating func toggleChecked(item id: UUID) {
		guard case .list(let style, var items) = self, let index = items.firstIndex(where: { $0.id == id }) else { return }
		items[index].checked = !(items[index].checked ?? false)
		self = .list(style: style, items: items)
	}

	mutating func resolveFlag(_ id: UUID, option: RescrivaFlag.Option?, typed: String?) {
		if case .diagram(var diagram) = self {
			guard let index = diagram.edges.firstIndex(where: { $0.flag?.id == id }), let option else { return }
			switch option.edgeAction ?? .keep {
			case .keep:
				diagram.edges[index].direction = .forward
				diagram.edges[index].flag?.resolution = option.label
			case .reverse:
				let edge = diagram.edges[index]
				diagram.edges[index].from = edge.to
				diagram.edges[index].to = edge.from
				diagram.edges[index].direction = .forward
				diagram.edges[index].flag?.resolution = option.label
			case .plain:
				diagram.edges[index].direction = .none
				diagram.edges[index].flag?.resolution = option.label
			case .both:
				diagram.edges[index].direction = .both
				diagram.edges[index].flag?.resolution = option.label
			case .remove:
				diagram.edges.remove(at: index)
			}
			self = .diagram(diagram)
			return
		}
		mapRuns { runs in
			runs.map { run in
				guard var flag = run.flag, flag.id == id else { return run }
				var run = run
				let choice = typed ?? option?.label ?? flag.read
				run.text = choice
				flag.resolution = choice
				run.flag = flag
				return run
			}
		}
	}

	/// Rewrites every run in the block (headings, paragraphs, list items, cells).
	mutating func mapRuns(_ transform: ([RescrivaRun]) -> [RescrivaRun]) {
		switch self {
		case .heading(let level, let runs):
			self = .heading(level: level, runs: transform(runs))
		case .paragraph(let runs, let alignment):
			self = .paragraph(runs: transform(runs), alignment: alignment)
		case .list(let style, let items):
			self = .list(style: style, items: items.map { item in
				var item = item
				item.runs = transform(item.runs)
				return item
			})
		case .table(let rows):
			self = .table(rows: rows.map { row in
				row.map { cell in
					var cell = cell
					cell.runs = transform(cell.runs)
					return cell
				}
			})
		case .equation, .figure, .diagram:
			break
		}
	}
}
