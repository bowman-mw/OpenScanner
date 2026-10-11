//
//  RebuiltDocumentView.swift
//  Folio (fork of Open Scanner)
//
//  Draws a FolioDocument the way it will come out in Word: headings,
//  paragraphs, checklists, tables, the equation and the diagram. Uncertain
//  words are dotted goldenrod and open their flag when tapped; tapping a
//  block selects it for the format buttons.
//

import SwiftUI

struct RebuiltDocumentView: View {
	let document: FolioDocument
	let output: OutputKind
	let selectedBlock: UUID?
	let activeFlag: UUID?
	let onSelectBlock: (UUID) -> Void
	let onOpenFlag: (UUID) -> Void
	let onToggleItem: (UUID, UUID) -> Void

	var body: some View {
		VStack(alignment: .leading, spacing: 14) {
			ForEach(Array(document.pages.enumerated()), id: \.element.id) { pageIndex, page in
				if pageIndex > 0 {
					PageDivider(number: pageIndex + 1)
				}
				ForEach(page.blocks) { block in
					BlockView(block: block, output: output, activeFlag: activeFlag,
							  onOpenFlag: onOpenFlag, onToggleItem: { onToggleItem(block.id, $0) })
						.padding(.vertical, 2)
						.padding(.horizontal, 4)
						.background {
							RoundedRectangle(cornerRadius: 8, style: .continuous)
								.strokeBorder(Color.moss.opacity(selectedBlock == block.id ? 0.55 : 0), lineWidth: 1.5)
								.padding(-4)
						}
						.contentShape(Rectangle())
						.onTapGesture { onSelectBlock(block.id) }
						.accessibilityAddTraits(selectedBlock == block.id ? .isSelected : [])
				}
			}
		}
		.environment(\.openURL, OpenURLAction { url in
			guard url.scheme == "folio-flag", let host = url.host(), let id = UUID(uuidString: host) else {
				return .systemAction
			}
			onOpenFlag(id)
			return .handled
		})
		.tint(.bark)
	}
}

private struct PageDivider: View {
	let number: Int

	var body: some View {
		HStack(spacing: 8) {
			Rectangle().fill(Color.bark.opacity(0.12)).frame(height: 1)
			Text("Page \(number)")
				.font(FolioFont.ui(11))
				.foregroundStyle(.slate)
			Rectangle().fill(Color.bark.opacity(0.12)).frame(height: 1)
		}
		.accessibilityHidden(true)
	}
}

/// One block of the rebuilt document.
private struct BlockView: View {
	let block: FolioBlock
	let output: OutputKind
	let activeFlag: UUID?
	let onOpenFlag: (UUID) -> Void
	let onToggleItem: (UUID) -> Void

	var body: some View {
		VStack(alignment: .leading, spacing: 10) {
			content
			ForEach(block.notes) { note in
				NoteView(note: note, output: output)
			}
		}
	}

	@ViewBuilder
	private var content: some View {
		switch block.content {
		case .heading(let level, let runs):
			Text(styled(runs, font: headingFont(level), activeFlag: activeFlag))
				.lineSpacing(2)
				.accessibilityAddTraits(.isHeader)
		case .paragraph(let runs, let alignment):
			Text(styled(runs, font: FolioFont.body(16), activeFlag: activeFlag))
				.lineSpacing(6)
				.multilineTextAlignment(alignment.swiftUI)
				.frame(maxWidth: .infinity, alignment: alignment.frame)
		case .list(let style, let items):
			VStack(alignment: .leading, spacing: 8) {
				ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
					HStack(alignment: .firstTextBaseline, spacing: 10) {
						marker(style: style, index: index, item: item)
						Text(styled(item.runs, font: FolioFont.body(16), activeFlag: activeFlag))
							.lineSpacing(4)
					}
					.padding(.leading, CGFloat(item.level) * 18)
				}
			}
		case .table(let rows):
			TableBlock(rows: rows, activeFlag: activeFlag)
		case .equation(let latex, let linear, _):
			VStack(spacing: 6) {
				EquationView(latex: latex, fallback: linear)
				Text(output == .docx ? "Equation · editable in Word" : "Equation")
					.font(FolioFont.ui(11, weight: .medium))
					.foregroundStyle(.moss)
			}
			.frame(maxWidth: .infinity)
			.padding(.vertical, 10)
			.background(Color.lichen.opacity(0.28), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
			.accessibilityElement(children: .ignore)
			.accessibilityLabel(Text("Equation: \(linear)"))
		case .figure(_, let caption, let altText):
			VStack(alignment: .leading, spacing: 6) {
				RoundedRectangle(cornerRadius: 8, style: .continuous)
					.fill(Color.scanBackdrop)
					.frame(height: 120)
					.overlay(Image(systemName: "photo").font(.system(size: 24, weight: .light)).foregroundStyle(.slate))
				if let caption {
					Text(caption).font(FolioFont.ui(12)).foregroundStyle(.slate)
				}
			}
			.accessibilityLabel(Text(altText ?? caption ?? String(localized: "Figure")))
		case .diagram(let diagram):
			VStack(alignment: .leading, spacing: 6) {
				if let caption = diagram.caption {
					Text(caption).folioSectionLabel()
				}
				DiagramView(diagram: diagram, onOpenFlag: onOpenFlag)
					.frame(maxWidth: .infinity)
			}
		}
	}

	@ViewBuilder
	private func marker(style: ListStyle, index: Int, item: ListItem) -> some View {
		switch style {
		case .checkbox:
			Button {
				onToggleItem(item.id)
			} label: {
				ZStack {
					if item.checked == true {
						RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.moss)
						Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.cream)
					} else {
						RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.bark, lineWidth: 1.5)
					}
				}
				.frame(width: 18, height: 18)
				.alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
			}
			.buttonStyle(PressScaleStyle())
			.accessibilityLabel(item.checked == true ? "Checked" : "Not checked")
		case .bullet:
			Text("•").font(FolioFont.body(16)).foregroundStyle(.bark)
		case .ordered:
			Text("\(index + 1).").font(FolioFont.body(16)).foregroundStyle(.bark)
		}
	}

	private func headingFont(_ level: Int) -> Font {
		switch level {
		case 1: return FolioFont.header(24)
		case 2: return FolioFont.header(20)
		default: return FolioFont.header(18)
		}
	}
}

/// Styled runs as an attributed string. Unresolved flags are dotted goldenrod
/// links that open the flag sheet.
func styled(_ runs: [FolioRun], font: Font, activeFlag: UUID?) -> AttributedString {
	var result = AttributedString()
	for run in runs {
		var piece = AttributedString(run.text)
		var runFont = font
		if run.bold { runFont = runFont.bold() }
		if run.italic { runFont = runFont.italic() }
		piece.font = runFont
		piece.foregroundColor = .bark
		if run.underline {
			piece.underlineStyle = Text.LineStyle(pattern: .solid, color: .bark)
		}
		if run.strikethrough {
			piece.strikethroughStyle = Text.LineStyle(pattern: .solid, color: .bark)
		}
		if let flag = run.flag, flag.resolution == nil {
			piece.underlineStyle = Text.LineStyle(pattern: .dot, color: .goldenrod)
			piece.link = URL(string: "folio-flag://\(flag.id.uuidString)")
			if activeFlag == flag.id {
				piece.backgroundColor = Color.goldenrod.opacity(0.22)
			}
		}
		result.append(piece)
	}
	return result
}

/// A block note, with where it will end up in the export.
private struct NoteView: View {
	let note: FolioNote
	let output: OutputKind

	var body: some View {
		HStack(alignment: .top, spacing: 8) {
			Image(systemName: "text.bubble")
				.font(.system(size: 14, weight: .light))
				.foregroundStyle(.bark)
				.padding(.top, 1)
			(Text(note.text).foregroundStyle(Color.bark)
			 + Text(" · \(destination)").foregroundStyle(Color.slate))
				.font(FolioFont.ui(13))
				.lineSpacing(3)
		}
		.padding(.vertical, 10)
		.padding(.horizontal, 12)
		.frame(maxWidth: .infinity, alignment: .leading)
		.background(Color.goldenrod.opacity(0.16), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
	}

	private var destination: String {
		switch output {
		case .docx: return String(localized: "becomes a Word comment")
		case .pptx: return String(localized: "becomes a speaker note")
		case .pdf: return String(localized: "becomes a PDF note")
		}
	}
}

/// A simple bordered table; spanning cells stretch across columns.
private struct TableBlock: View {
	let rows: [[TableCell]]
	let activeFlag: UUID?

	var body: some View {
		VStack(spacing: 0) {
			ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
				HStack(spacing: 0) {
					ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
						Text(styled(cell.runs, font: rowIndex == 0 ? FolioFont.ui(13, weight: .medium) : FolioFont.ui(13), activeFlag: activeFlag))
							.frame(maxWidth: .infinity, alignment: .leading)
							.padding(8)
							.layoutPriority(Double(cell.columnSpan))
							.overlay(Rectangle().strokeBorder(Color.bark.opacity(0.18), lineWidth: 0.5))
					}
				}
			}
		}
		.background(Color.paper)
		.clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
		.overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.bark.opacity(0.25), lineWidth: 1))
	}
}

private extension TextAlignment {
	var swiftUI: SwiftUI.TextAlignment {
		switch self {
		case .center: return .center
		case .trailing: return .trailing
		case .leading, .justified: return .leading
		}
	}

	var frame: Alignment {
		switch self {
		case .center: return .center
		case .trailing: return .trailing
		case .leading, .justified: return .leading
		}
	}
}

// MARK: - Equation

/// Typesets a small LaTeX subset — fractions, sub/superscripts, Greek and a
/// few operators — and falls back to the linear form for anything else.
struct EquationView: View {
	let latex: String
	let fallback: String

	private var parsed: MathNode? {
		var parser = MathParser(latex)
		return parser.parse()
	}

	var body: some View {
		if let node = parsed {
			MathNodeView(node: node, size: 19)
				.foregroundStyle(.bark)
		} else {
			Text(fallback)
				.font(FolioFont.body(19, italic: true))
				.foregroundStyle(.bark)
		}
	}
}

/// Parsed math.
indirect enum MathNode: Equatable {
	case symbol(String)
	case row([MathNode])
	case fraction(MathNode, MathNode)
	case scripts(base: MathNode, sub: MathNode?, sup: MathNode?)
}

/// Recursive-descent parser for the supported subset.
struct MathParser {
	private let characters: [Character]
	private var index = 0

	init(_ latex: String) {
		characters = Array(latex)
	}

	mutating func parse() -> MathNode? {
		let row = parseRow(until: nil)
		return index == characters.count ? row : nil
	}

	private static let symbols: [String: String] = [
		"alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε", "theta": "θ", "lambda": "λ",
		"mu": "μ", "pi": "π", "rho": "ρ", "sigma": "σ", "tau": "τ", "phi": "φ", "omega": "ω",
		"Delta": "Δ", "Sigma": "Σ", "Omega": "Ω", "cdot": "·", "times": "×", "pm": "±", "leq": "≤",
		"geq": "≥", "neq": "≠", "approx": "≈", "infty": "∞", "rightarrow": "→", "to": "→",
	]

	private mutating func parseRow(until terminator: Character?) -> MathNode? {
		var nodes: [MathNode] = []
		while index < characters.count {
			let character = characters[index]
			if let terminator, character == terminator {
				break
			}
			switch character {
			case "{":
				index += 1
				guard let group = parseRow(until: "}"), consume("}") else { return nil }
				nodes.append(group)
			case "}":
				return nil
			case "_", "^":
				index += 1
				guard let script = parseAtom() else { return nil }
				let base = nodes.popLast() ?? .symbol("")
				if case .scripts(let b, let sub, let sup) = base {
					nodes.append(character == "_" ? .scripts(base: b, sub: script, sup: sup) : .scripts(base: b, sub: sub, sup: script))
				} else {
					nodes.append(character == "_" ? .scripts(base: base, sub: script, sup: nil) : .scripts(base: base, sub: nil, sup: script))
				}
			case "\\":
				index += 1
				let name = readCommand()
				if name == "frac" {
					guard let numerator = parseAtom(), let denominator = parseAtom() else { return nil }
					nodes.append(.fraction(numerator, denominator))
				} else if name == "left" || name == "right" {
					continue
				} else if let symbol = Self.symbols[name] {
					nodes.append(.symbol(symbol))
				} else if name == " " || name == "," {
					nodes.append(.symbol(" "))
				} else {
					return nil
				}
			default:
				index += 1
				nodes.append(.symbol(String(character)))
			}
		}
		return nodes.count == 1 ? nodes[0] : .row(nodes)
	}

	private mutating func parseAtom() -> MathNode? {
		guard index < characters.count else { return nil }
		if characters[index] == "{" {
			index += 1
			guard let group = parseRow(until: "}"), consume("}") else { return nil }
			return group
		}
		if characters[index] == "\\" {
			index += 1
			let name = readCommand()
			return Self.symbols[name].map { .symbol($0) }
		}
		defer { index += 1 }
		return .symbol(String(characters[index]))
	}

	private mutating func readCommand() -> String {
		var name = ""
		while index < characters.count, characters[index].isLetter {
			name.append(characters[index])
			index += 1
		}
		if name.isEmpty, index < characters.count {
			name = String(characters[index])
			index += 1
		}
		return name
	}

	private mutating func consume(_ character: Character) -> Bool {
		guard index < characters.count, characters[index] == character else { return false }
		index += 1
		return true
	}
}

/// Lays out a parsed math node: text rows as one Text, fractions stacked.
struct MathNodeView: View {
	let node: MathNode
	let size: CGFloat

	var body: some View {
		if let text = Self.text(node, size: size) {
			text
		} else {
			switch node {
			case .fraction(let numerator, let denominator):
				VStack(spacing: 2) {
					MathNodeView(node: numerator, size: size * 0.9)
						.padding(.horizontal, 6)
					Rectangle().fill(Color.bark).frame(height: 1.5)
					MathNodeView(node: denominator, size: size * 0.9)
						.padding(.horizontal, 6)
				}
				.fixedSize()
			case .row(let nodes):
				HStack(spacing: 0) {
					ForEach(Array(nodes.enumerated()), id: \.offset) { _, child in
						MathNodeView(node: child, size: size)
					}
				}
			default:
				EmptyView()
			}
		}
	}

	/// A single Text for nodes without fractions, using baseline offsets for scripts.
	static func text(_ node: MathNode, size: CGFloat) -> Text? {
		switch node {
		case .symbol(let value):
			let spaced = ["=", "+", "−", "-", "×", "·", "≤", "≥", "≠", "≈", "→"].contains(value) ? " \(value) " : value
			let italic = value.count == 1 && value.first?.isLetter == true
			return Text(spaced).font(FolioFont.body(size, italic: italic))
		case .row(let nodes):
			var result = Text("")
			for child in nodes {
				guard let piece = text(child, size: size) else { return nil }
				result = result + piece
			}
			return result
		case .scripts(let base, let sub, let sup):
			guard var result = text(base, size: size) else { return nil }
			if let sub {
				guard let piece = text(sub, size: size * 0.62) else { return nil }
				result = result + piece.baselineOffset(-size * 0.22)
			}
			if let sup {
				guard let piece = text(sup, size: size * 0.62) else { return nil }
				result = result + piece.baselineOffset(size * 0.38)
			}
			return result
		case .fraction:
			return nil
		}
	}
}

// MARK: - Diagram

/// A diagram as shapes and arrows. An uncertain arrow is dashed goldenrod
/// with a "?" badge that opens its flag.
struct DiagramView: View {
	let diagram: Diagram
	let onOpenFlag: (UUID) -> Void

	var body: some View {
		GeometryReader { proxy in
			let size = proxy.size
			ZStack(alignment: .topLeading) {
				Canvas { context, _ in
					for edge in diagram.edges {
						guard let segment = segment(for: edge, in: size) else { continue }
						let uncertain = edge.flag != nil && edge.flag?.resolution == nil
						let color = uncertain ? Color.goldenrod : Color.bark
						var line = Path()
						line.move(to: segment.start)
						line.addLine(to: segment.end)
						context.stroke(line, with: .color(color),
									   style: StrokeStyle(lineWidth: uncertain ? 2 : 1.5, dash: uncertain ? [5, 4] : []))
						context.fill(arrowhead(at: segment.end, from: segment.start), with: .color(color))
					}
				}
				ForEach(diagram.nodes) { node in
					NodeShapeView(node: node)
						.frame(width: node.box.width * size.width, height: node.box.height * size.height)
						.position(x: (node.box.x + node.box.width / 2) * size.width,
								  y: (node.box.y + node.box.height / 2) * size.height)
				}
				ForEach(diagram.edges) { edge in
					if let flag = edge.flag, flag.resolution == nil, let segment = segment(for: edge, in: size) {
						Button {
							onOpenFlag(flag.id)
						} label: {
							Text("?")
								.font(FolioFont.ui(14, weight: .medium))
								.foregroundStyle(.bark)
								.frame(width: 26, height: 26)
								.background(Color.goldenrod, in: Circle())
								.folioShadow(.small)
						}
						.buttonStyle(PressScaleStyle())
						.position(x: (segment.start.x + segment.end.x) / 2 + 22, y: (segment.start.y + segment.end.y) / 2)
						.accessibilityLabel("Check this arrow")
					}
				}
			}
		}
		.aspectRatio(diagram.aspect, contentMode: .fit)
		.frame(maxWidth: 340)
		.accessibilityElement(children: .contain)
		.accessibilityLabel(Text("Diagram"))
	}

	private func rect(_ node: Diagram.Node, in size: CGSize) -> CGRect {
		CGRect(x: node.box.x * size.width, y: node.box.y * size.height,
			   width: node.box.width * size.width, height: node.box.height * size.height)
	}

	/// The centre-to-centre line clipped to both shapes, with a small gap.
	private func segment(for edge: Diagram.Edge, in size: CGSize) -> (start: CGPoint, end: CGPoint)? {
		guard let from = diagram.node(edge.from), let to = diagram.node(edge.to) else { return nil }
		let a = rect(from, in: size)
		let b = rect(to, in: size)
		let start = CGPoint(x: a.midX, y: a.midY)
		let end = CGPoint(x: b.midX, y: b.midY)
		let dx = end.x - start.x
		let dy = end.y - start.y
		func exit(_ r: CGRect) -> CGFloat {
			let tx = dx == 0 ? .infinity : (r.width / 2) / abs(dx)
			let ty = dy == 0 ? .infinity : (r.height / 2) / abs(dy)
			return min(tx, ty)
		}
		let length = max(hypot(dx, dy), 1)
		let gap = 2 / length
		let t0 = exit(a) + gap
		let t1 = 1 - exit(b) - gap - 6 / length
		guard t1 > t0 else { return nil }
		return (CGPoint(x: start.x + dx * t0, y: start.y + dy * t0), CGPoint(x: start.x + dx * t1, y: start.y + dy * t1))
	}

	private func arrowhead(at tip: CGPoint, from tail: CGPoint) -> Path {
		let angle = atan2(tip.y - tail.y, tip.x - tail.x)
		let length: CGFloat = 8
		let spread: CGFloat = .pi / 7
		let point = CGPoint(x: tip.x + cos(angle) * length, y: tip.y + sin(angle) * length)
		var path = Path()
		path.move(to: point)
		path.addLine(to: CGPoint(x: point.x - cos(angle - spread) * length * 1.2, y: point.y - sin(angle - spread) * length * 1.2))
		path.addLine(to: CGPoint(x: point.x - cos(angle + spread) * length * 1.2, y: point.y - sin(angle + spread) * length * 1.2))
		path.closeSubpath()
		return path
	}
}

/// One diagram node.
private struct NodeShapeView: View {
	let node: Diagram.Node

	var body: some View {
		let stroke = Color(red: node.stroke.red, green: node.stroke.green, blue: node.stroke.blue)
		let fill = node.fill.map { Color(red: $0.red, green: $0.green, blue: $0.blue) } ?? stroke.opacity(0.12)
		ZStack {
			switch node.shape {
			case .rectangle:
				RoundedRectangle(cornerRadius: 8, style: .continuous).fill(fill)
				RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(stroke, lineWidth: 1.5)
			case .roundedRectangle, .ellipse:
				Capsule().fill(fill)
				Capsule().strokeBorder(stroke, lineWidth: 1.5)
			case .diamond:
				DiamondShape().fill(fill)
				DiamondShape().stroke(stroke, lineWidth: 1.5)
			}
			Text(node.label)
				.font(FolioFont.ui(13, weight: .medium))
				.foregroundStyle(.bark)
				.lineLimit(2)
				.minimumScaleFactor(0.7)
				.multilineTextAlignment(.center)
				.padding(.horizontal, 4)
		}
		.accessibilityElement(children: .combine)
	}
}

private struct DiamondShape: Shape {
	func path(in rect: CGRect) -> Path {
		var path = Path()
		path.move(to: CGPoint(x: rect.midX, y: rect.minY))
		path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
		path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
		path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
		path.closeSubpath()
		return path
	}
}
