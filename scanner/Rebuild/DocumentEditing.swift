//
//  DocumentEditing.swift
//  Folio (fork of Open Scanner)
//
//  The review screen's edits, as pure changes to the FolioDocument: resolve a
//  flag, toggle bold/italic/underline, switch heading ↔ paragraph, tick a
//  checkbox, add or remove a note. Every export afterwards includes them.
//

import Foundation

/// Bold, italic or underline.
enum RunStyle: CaseIterable {
	case bold, italic, underline

	var keyPath: WritableKeyPath<FolioRun, Bool> {
		switch self {
		case .bold: return \.bold
		case .italic: return \.italic
		case .underline: return \.underline
		}
	}
}

extension FolioDocument {
	/// Finds a block by ID.
	func block(_ id: UUID) -> FolioBlock? {
		for page in pages {
			if let block = page.blocks.first(where: { $0.id == id }) { return block }
		}
		return nil
	}

	/// The flag with `id`, wherever it lives.
	func flag(_ id: UUID) -> FolioFlag? {
		for page in pages {
			for block in page.blocks {
				if let flag = block.content.flags.first(where: { $0.id == id }) { return flag }
			}
		}
		return nil
	}

	/// Applies `change` to the block with `id`.
	mutating func updateBlock(_ id: UUID, _ change: (inout FolioBlock) -> Void) {
		for pageIndex in pages.indices {
			if let blockIndex = pages[pageIndex].blocks.firstIndex(where: { $0.id == id }) {
				change(&pages[pageIndex].blocks[blockIndex])
				return
			}
		}
	}

	/// Resolves a flag with one of its options, or with text the user typed.
	mutating func resolveFlag(_ id: UUID, option: FolioFlag.Option? = nil, typed: String? = nil) {
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

	/// True when every run in the block has `style` (and there is at least one).
	func allRuns(_ style: RunStyle) -> Bool {
		let runs = allRuns.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
		return !runs.isEmpty && runs.allSatisfy { $0[keyPath: style.keyPath] }
	}

	private var allRuns: [FolioRun] {
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

	mutating func resolveFlag(_ id: UUID, option: FolioFlag.Option?, typed: String?) {
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
	mutating func mapRuns(_ transform: ([FolioRun]) -> [FolioRun]) {
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
