//
//  TextRenderers.swift
//  Rescriva (fork of Open Scanner)
//
//  Plain-text and Markdown ("Copy for AI") renderers, plus the small
//  IR-derived layout helpers every renderer shares: the table grid (spans
//  resolved into slots), list counters and the reading-order note list.
//

import Foundation

// MARK: - Shared layout helpers

/// A table's cells resolved onto a rectangular grid.
///
/// `BlockContent.table` is HTML-style: a spanning cell covers the slots to its
/// right and below, and those covered slots are omitted from later cells and
/// rows. The grid puts every cell at its origin slot, marks the slots it
/// covers, and pads short rows with empty slots so every row has
/// `columnCount` slots.
struct RescrivaTableGrid {
	/// What occupies one grid slot.
	enum Slot: Equatable {
		/// A cell starts here and spans `rowSpan` × `columnSpan` slots
		/// (already clamped to the grid).
		case origin(TableCell, rowSpan: Int, columnSpan: Int)
		/// Covered by the spanning cell whose origin is at (`row`, `column`).
		case covered(row: Int, column: Int)
		/// Nothing here; the source row was shorter than the grid.
		case empty
	}

	/// The widest row, in slots. Capped at `maxColumns`.
	let columnCount: Int
	/// `rows[r][c]`; every row has exactly `columnCount` slots.
	let rows: [[Slot]]

	/// Safety cap so a corrupt span cannot allocate a huge grid.
	static let maxColumns = 64

	init(rows source: [[TableCell]]) {
		var grid: [[Slot?]] = Array(repeating: [], count: source.count)
		let limit = Self.maxColumns
		func isFree(_ row: Int, _ column: Int) -> Bool {
			column >= grid[row].count || grid[row][column] == nil
		}
		func set(_ row: Int, _ column: Int, _ slot: Slot) {
			if grid[row].count <= column {
				grid[row].append(contentsOf: Array(repeating: nil, count: column + 1 - grid[row].count))
			}
			grid[row][column] = slot
		}
		for (rowIndex, cells) in source.enumerated() {
			var column = 0
			for cell in cells {
				while column < limit, !isFree(rowIndex, column) { column += 1 }
				guard column < limit else { break }
				var columnSpan = min(max(cell.columnSpan, 1), limit - column)
				for offset in 1..<max(columnSpan, 1) where !isFree(rowIndex, column + offset) {
					columnSpan = offset
					break
				}
				var rowSpan = min(max(cell.rowSpan, 1), source.count - rowIndex)
				for below in 1..<max(rowSpan, 1) {
					let blocked = (0..<columnSpan).contains { !isFree(rowIndex + below, column + $0) }
					if blocked {
						rowSpan = below
						break
					}
				}
				for rowOffset in 0..<rowSpan {
					for columnOffset in 0..<columnSpan {
						let slot: Slot = rowOffset == 0 && columnOffset == 0
							? .origin(cell, rowSpan: rowSpan, columnSpan: columnSpan)
							: .covered(row: rowIndex, column: column)
						set(rowIndex + rowOffset, column + columnOffset, slot)
					}
				}
				column += columnSpan
			}
		}
		let width = min(grid.map(\.count).max() ?? 0, limit)
		columnCount = width
		rows = grid.map { row in
			(0..<width).map { column in column < row.count ? (row[column] ?? .empty) : .empty }
		}
	}

	/// The cell covering (`row`, `column`), resolving covered slots to their origin.
	func originCell(row: Int, column: Int) -> (cell: TableCell, row: Int, column: Int)? {
		guard row >= 0, row < rows.count, column >= 0, column < columnCount else { return nil }
		switch rows[row][column] {
		case .origin(let cell, _, _):
			return (cell, row, column)
		case .covered(let originRow, let originColumn):
			guard case .origin(let cell, _, _) = rows[originRow][originColumn] else { return nil }
			return (cell, originRow, originColumn)
		case .empty:
			return nil
		}
	}
}

/// Per-level counters for ordered lists: counting at one level resets every
/// deeper level, the way Word and Markdown number nested lists.
struct RescrivaListCounter {
	/// Deepest nesting level honoured (Word supports nine, 0–8).
	static let maxLevel = 8

	private var counts: [Int] = []

	/// Clamps a list item level into 0…`maxLevel`.
	static func clamp(_ level: Int) -> Int { min(max(level, 0), maxLevel) }

	/// Advances the counter at `level` and returns its new 1-based value.
	mutating func next(level: Int) -> Int {
		let level = Self.clamp(level)
		if counts.count <= level {
			counts.append(contentsOf: Array(repeating: 0, count: level + 1 - counts.count))
		}
		counts[level] += 1
		if counts.count > level + 1 {
			counts.removeSubrange((level + 1)...)
		}
		return counts[level]
	}
}

/// One note in reading order with where it sits: each page's own notes first,
/// then the notes on its blocks in block order.
struct RescrivaNoteEntry {
	let pageIndex: Int
	/// The block the note is on; nil for a page note.
	let blockID: UUID?
	let note: RescrivaNote
	/// The text of the run the note is anchored to, when it is anchored to one.
	let anchorText: String?

	/// Every note in `document`, in reading order.
	static func all(in document: RescrivaDocument) -> [RescrivaNoteEntry] {
		var result: [RescrivaNoteEntry] = []
		for (pageIndex, page) in document.pages.enumerated() {
			for note in page.notes {
				result.append(RescrivaNoteEntry(pageIndex: pageIndex, blockID: nil, note: note, anchorText: nil))
			}
			for block in page.blocks {
				let runs = RescrivaRunLookup.allRuns(in: block.content)
				for note in block.notes {
					let anchor = note.runID.flatMap { id in runs.first { $0.id == id }?.text }
					result.append(RescrivaNoteEntry(pageIndex: pageIndex, blockID: block.id, note: note, anchorText: anchor))
				}
			}
		}
		return result
	}

	/// "Page 1, on “saturated”" — the human-readable location used by the
	/// text, Markdown and speaker-notes exports.
	var locationLabel: String {
		let page = "Page \(pageIndex + 1)"
		guard let anchor = anchorText?.trimmingCharacters(in: .whitespacesAndNewlines), !anchor.isEmpty else { return page }
		return "\(page), on \u{201C}\(anchor)\u{201D}"
	}
}

/// Finds runs inside block content.
enum RescrivaRunLookup {
	/// Every run in `content`, in reading order.
	static func allRuns(in content: BlockContent) -> [RescrivaRun] {
		switch content {
		case .heading(_, let runs), .paragraph(let runs, _):
			return runs
		case .list(_, let items):
			return items.flatMap(\.runs)
		case .table(let rows):
			return rows.flatMap { $0.flatMap(\.runs) }
		case .equation, .figure, .diagram:
			return []
		}
	}

	/// Whether a run carries a flag that is still open.
	static func isUncertain(_ run: RescrivaRun) -> Bool {
		guard let flag = run.flag else { return false }
		return flag.resolution == nil
	}
}

/// List markers for plain text: decimal, then lower letters, then lower roman,
/// cycling by level (the same scheme the Word numbering uses).
enum RescrivaListMarker {
	/// The ordered marker for `value` at `level`, e.g. `3.`, `c.`, `iii.`.
	static func ordered(_ value: Int, level: Int) -> String {
		switch level % 3 {
		case 1: return letters(value) + "."
		case 2: return roman(value) + "."
		default: return "\(value)."
		}
	}

	/// 1 → a, 26 → z, 27 → aa.
	static func letters(_ value: Int) -> String {
		guard value > 0 else { return "\(value)" }
		var remaining = value
		var output = ""
		// At most a handful of iterations: each divides by 26.
		while remaining > 0 {
			let digit = (remaining - 1) % 26
			output = String(UnicodeScalar(UInt8(97 + digit))) + output
			remaining = (remaining - 1) / 26
		}
		return output
	}

	/// Lower-case roman numerals for 1…3999; decimal otherwise.
	static func roman(_ value: Int) -> String {
		guard value > 0, value < 4000 else { return "\(value)" }
		let table: [(Int, String)] = [
			(1000, "m"), (900, "cm"), (500, "d"), (400, "cd"), (100, "c"), (90, "xc"),
			(50, "l"), (40, "xl"), (10, "x"), (9, "ix"), (5, "v"), (4, "iv"), (1, "i"),
		]
		var remaining = value
		var output = ""
		for (amount, symbol) in table {
			let repeats = remaining / amount
			output += String(repeating: symbol, count: repeats)
			remaining -= repeats * amount
		}
		return output
	}
}

// MARK: - Plain text

/// Renders a document as plain text: block text in reading order, a blank
/// line between blocks, a `---` line between pages and, optionally, a Notes
/// appendix. Open flags render their run text as read, with no marker.
enum PlainTextRenderer {
	static func render(_ document: RescrivaDocument, options: RenderOptions = RenderOptions()) -> String {
		let pages = document.pages.map { page -> String in
			page.blocks.map { text(for: $0.content) }.filter { !$0.isEmpty }.joined(separator: "\n\n")
		}
		var output = pages.joined(separator: "\n\n---\n\n")
		if options.includeNotes {
			let entries = RescrivaNoteEntry.all(in: document)
			if !entries.isEmpty {
				let lines = entries.map { "- \($0.locationLabel): \(singleLine($0.note.text))" }
				output += (output.isEmpty ? "" : "\n\n") + "Notes\n" + lines.joined(separator: "\n")
			}
		}
		return output
	}

	/// The plain text of one block.
	static func text(for content: BlockContent) -> String {
		switch content {
		case .heading(_, let runs), .paragraph(let runs, _):
			return runs.plainText
		case .list(let style, let items):
			return listText(style: style, items: items)
		case .table(let rows):
			let grid = RescrivaTableGrid(rows: rows)
			return grid.rows.map { row in
				row.map { slot -> String in
					guard case .origin(let cell, _, _) = slot else { return "" }
					return singleLine(cell.runs.plainText)
				}.joined(separator: "\t")
			}.joined(separator: "\n")
		case .equation(let latex, let linear, _):
			return linear.isEmpty ? latex : linear
		case .figure(_, let caption, let altText):
			let label = [caption, altText].compactMap { $0 }.first { !$0.isEmpty }
			return label.map { "[Figure: \(singleLine($0))]" } ?? "[Figure]"
		case .diagram(let diagram):
			return diagramText(diagram)
		}
	}

	private static func listText(style: ListStyle, items: [ListItem]) -> String {
		var counter = RescrivaListCounter()
		return items.map { item -> String in
			let level = RescrivaListCounter.clamp(item.level)
			let marker: String
			switch style {
			case .bullet: marker = "\u{2022}"
			case .ordered: marker = RescrivaListMarker.ordered(counter.next(level: level), level: level)
			case .checkbox: marker = item.checked == true ? "\u{2611}" : "\u{2610}"
			}
			return String(repeating: "  ", count: level) + marker + " " + singleLine(item.runs.plainText)
		}.joined(separator: "\n")
	}

	private static func diagramText(_ diagram: Diagram) -> String {
		var lines: [String] = []
		if let caption = diagram.caption, !caption.isEmpty {
			lines.append("[Diagram: \(singleLine(caption))]")
		} else {
			lines.append("[Diagram]")
		}
		for edge in diagram.edges {
			guard let from = diagram.node(edge.from), let to = diagram.node(edge.to) else { continue }
			var line = "\(singleLine(from.label)) \(edge.direction.textConnector) \(singleLine(to.label))"
			if let label = edge.label, !label.isEmpty { line += " (\(singleLine(label)))" }
			lines.append(line)
		}
		return lines.joined(separator: "\n")
	}

	/// Collapses line breaks to spaces.
	static func singleLine(_ text: String) -> String {
		text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).joined(separator: " ")
	}
}

// MARK: - Markdown

/// Renders a document as Markdown for pasting into an AI assistant ("Copy for
/// AI"): `#` headings, `**bold**`/`*italic*`/`~~strike~~` (underline is
/// dropped), nested lists with two spaces per level, pipe tables with the
/// first row as header, `$…$`/`$$…$$` LaTeX, `![caption](figure-N)` figure
/// placeholders, Mermaid flowcharts for diagrams and an optional Notes
/// section. With `markUncertain`, every run with an open flag is followed by
/// ` (?)` and every open-flag diagram edge is preceded by `%% uncertain`.
enum MarkdownRenderer {
	static func render(_ document: RescrivaDocument, options: RenderOptions = RenderOptions(), markUncertain: Bool = true) -> String {
		var renderer = State(markUncertain: markUncertain)
		var blocks: [String] = []
		for page in document.pages {
			for block in page.blocks {
				let text = renderer.markdown(for: block.content)
				if !text.isEmpty { blocks.append(text) }
			}
		}
		if options.includeNotes {
			let entries = RescrivaNoteEntry.all(in: document)
			if !entries.isEmpty {
				let lines = entries.map { entry in
					"- \(escape(entry.locationLabel)): \(escape(PlainTextRenderer.singleLine(entry.note.text)))"
				}
				blocks.append("## Notes\n\n" + lines.joined(separator: "\n"))
			}
		}
		return blocks.joined(separator: "\n\n") + (blocks.isEmpty ? "" : "\n")
	}

	/// Rendering state that spans blocks (figure numbering).
	private struct State {
		let markUncertain: Bool
		var figureCount = 0

		mutating func markdown(for content: BlockContent) -> String {
			switch content {
			case .heading(let level, let runs):
				let text = inline(runs, lineBreak: " ")
				guard !text.isEmpty else { return "" }
				return String(repeating: "#", count: min(max(level, 1), 4)) + " " + text
			case .paragraph(let runs, _):
				return escapeLineStarts(inline(runs, lineBreak: "\n"))
			case .list(let style, let items):
				return list(style: style, items: items)
			case .table(let rows):
				return table(rows)
			case .equation(let latex, let linear, let display):
				let source = latex.trimmingCharacters(in: .whitespacesAndNewlines)
				let body = source.isEmpty ? linear : source
				guard !body.isEmpty else { return "" }
				return display ? "$$\(body)$$" : "$\(PlainTextRenderer.singleLine(body))$"
			case .figure(_, let caption, let altText):
				figureCount += 1
				return figure(caption: caption, altText: altText, number: figureCount)
			case .diagram(let diagram):
				return mermaid(diagram)
			}
		}

		private func inline(_ runs: [RescrivaRun], lineBreak: String, inTable: Bool = false) -> String {
			var output = ""
			var index = 0
			// Each pass consumes at least one run.
			while index < runs.count {
				let run = runs[index]
				let uncertain = RescrivaRunLookup.isUncertain(run)
				var text = run.text
				var next = index + 1
				if !uncertain {
					while next < runs.count, !RescrivaRunLookup.isUncertain(runs[next]), sameStyle(run, runs[next]) {
						text += runs[next].text
						next += 1
					}
				}
				output += emphasize(text, run: run, inTable: inTable)
				if uncertain && markUncertain { output += " (?)" }
				index = next
			}
			return output.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).joined(separator: lineBreak)
		}

		private func sameStyle(_ a: RescrivaRun, _ b: RescrivaRun) -> Bool {
			a.bold == b.bold && a.italic == b.italic && a.strikethrough == b.strikethrough
		}

		/// Wraps the non-whitespace core of `text` in emphasis markers, keeping
		/// surrounding whitespace outside them so the Markdown stays valid.
		private func emphasize(_ text: String, run: RescrivaRun, inTable: Bool) -> String {
			let leading = String(text.prefix { $0.isWhitespace })
			let rest = text.dropFirst(leading.count)
			let trailing = String(rest.reversed().prefix { $0.isWhitespace }.reversed())
			let core = String(rest.dropLast(trailing.count))
			guard !core.isEmpty else { return text }
			var marker = ""
			if run.bold && run.italic {
				marker = "***"
			} else if run.bold {
				marker = "**"
			} else if run.italic {
				marker = "*"
			}
			var body = marker + escape(core, inTable: inTable) + marker
			if run.strikethrough { body = "~~" + body + "~~" }
			return leading + body + trailing
		}

		private func list(style: ListStyle, items: [ListItem]) -> String {
			var counter = RescrivaListCounter()
			return items.map { item -> String in
				let level = RescrivaListCounter.clamp(item.level)
				let marker: String
				switch style {
				case .bullet: marker = "-"
				case .ordered: marker = "\(counter.next(level: level))."
				case .checkbox: marker = item.checked == true ? "- [x]" : "- [ ]"
				}
				return String(repeating: "  ", count: level) + marker + " " + inline(item.runs, lineBreak: " ")
			}.joined(separator: "\n")
		}

		private func table(_ rows: [[TableCell]]) -> String {
			let grid = RescrivaTableGrid(rows: rows)
			guard grid.columnCount > 0, !grid.rows.isEmpty else { return "" }
			let lines = grid.rows.map { row -> String in
				let cells = row.map { slot -> String in
					guard case .origin(let cell, _, _) = slot else { return "" }
					return inline(cell.runs, lineBreak: "<br>", inTable: true)
				}
				return "| " + cells.joined(separator: " | ") + " |"
			}
			let separator = "| " + Array(repeating: "---", count: grid.columnCount).joined(separator: " | ") + " |"
			return ([lines[0], separator] + lines.dropFirst()).joined(separator: "\n")
		}

		private func figure(caption: String?, altText: String?, number: Int) -> String {
			let caption = caption.map(PlainTextRenderer.singleLine)?.trimmingCharacters(in: .whitespaces) ?? ""
			let alt = altText.map(PlainTextRenderer.singleLine)?.trimmingCharacters(in: .whitespaces) ?? ""
			let label = caption.isEmpty ? alt : caption
			let escapedLabel = label.replacingOccurrences(of: "\\", with: "\\\\")
				.replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
			var title = ""
			if !alt.isEmpty, alt != label {
				title = " \"" + alt.replacingOccurrences(of: "\"", with: "\\\"") + "\""
			}
			return "![\(escapedLabel)](figure-\(number)\(title))"
		}

		private func mermaid(_ diagram: Diagram) -> String {
			var ids: [String: String] = [:]
			var lines = ["```mermaid", "flowchart TD"]
			for (index, node) in diagram.nodes.enumerated() where ids[node.id] == nil {
				let id = "n\(index + 1)"
				ids[node.id] = id
				let label = "\"" + mermaidText(node.label) + "\""
				switch node.shape {
				case .rectangle: lines.append("    \(id)[\(label)]")
				case .roundedRectangle: lines.append("    \(id)(\(label))")
				case .ellipse: lines.append("    \(id)((\(label)))")
				case .diamond: lines.append("    \(id){\(label)}")
				case .parallelogram: lines.append("    \(id)[/\(label)/]")
				}
			}
			for edge in diagram.edges {
				guard let from = ids[edge.from], let to = ids[edge.to] else { continue }
				if markUncertain, let flag = edge.flag, flag.resolution == nil {
					lines.append("    %% uncertain")
				}
				let link: String
				switch edge.direction {
				case .forward: link = "-->"
				case .none: link = "---"
				case .both: link = "<-->"
				}
				if let label = edge.label, !label.isEmpty {
					lines.append("    \(from) \(link)|\"\(mermaidText(label))\"| \(to)")
				} else {
					lines.append("    \(from) \(link) \(to)")
				}
			}
			lines.append("```")
			if let caption = diagram.caption?.trimmingCharacters(in: .whitespacesAndNewlines), !caption.isEmpty {
				lines.append("")
				lines.append("*" + escape(PlainTextRenderer.singleLine(caption)) + "*")
			}
			return lines.joined(separator: "\n")
		}

		/// Mermaid label text: quotes and pipes become entity codes, line breaks spaces.
		private func mermaidText(_ text: String) -> String {
			PlainTextRenderer.singleLine(text)
				.replacingOccurrences(of: "\"", with: "#quot;")
				.replacingOccurrences(of: "|", with: "#124;")
		}

		/// Escapes characters that would start block structure at a line start.
		private func escapeLineStarts(_ text: String) -> String {
			text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" }).map { line -> String in
				let body = line.drop { $0 == " " }
				let indent = String(line.prefix(line.count - body.count))
				guard let first = body.first else { return String(line) }
				if "#>-+=".contains(first) { return indent + "\\" + body }
				let digits = body.prefix { $0.isASCII && $0.isNumber }
				let after = body.dropFirst(digits.count)
				if !digits.isEmpty, let mark = after.first, mark == "." || mark == ")",
				   after.dropFirst().first.map({ $0 == " " }) ?? true {
					return indent + digits + "\\" + after
				}
				return String(line)
			}.joined(separator: "\n")
		}
	}

	/// Backslash-escapes Markdown inline syntax (and `|` inside table cells).
	/// `<` is escaped only where it could open an HTML tag (`<before>`), so
	/// "x < y" stays readable.
	static func escape(_ text: String, inTable: Bool = false) -> String {
		var output = ""
		output.reserveCapacity(text.count)
		let characters = Array(text)
		for (index, character) in characters.enumerated() {
			switch character {
			case "\\", "*", "_", "`", "$", "~":
				output.append("\\")
				output.append(character)
			case "|" where inTable:
				output += "\\|"
			case "<":
				let next = index + 1 < characters.count ? characters[index + 1] : " "
				if next.isLetter || next == "/" || next == "!" || next == "?" { output.append("\\") }
				output.append(character)
			default:
				output.append(character)
			}
		}
		return output
	}
}
