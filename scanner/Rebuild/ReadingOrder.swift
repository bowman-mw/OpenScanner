//
//  ReadingOrder.swift
//  Folio (fork of Open Scanner)
//
//  Column-aware reading order for a page, by a recursive XY-cut over the
//  boxes of its lines or blocks. A region is cut down a column gutter when a
//  clear one runs through all of it: whitespace at least about a line high
//  across, no wider than the columns beside it, with real content on both
//  sides, and, when the two sides line up row by row, prose on both, filling
//  about as much of the height they share (a form, a table, or labels beside
//  the paragraphs they head read across, not down). A heading, picture or
//  paragraph that spans the gutter is cut out above and below first, so each
//  stretch of columns reads between the full-width rows around it. Otherwise
//  the region is cut across its widest horizontal gap, and what can't be cut
//  reads top to bottom, left to right, as every page did before.
//
//  Vision's document reader (iOS 26) doesn't settle the order: on a
//  two-column page it reads side-by-side blocks in bands across both columns
//  (checked on a rendered page), no better than sorting by position.
//
//  The order only changes where columns were found. Anything unclear —
//  overlapping boxes, a full-width row that can't be cut out cleanly, a page
//  with too many boxes — and the caller keeps the order it has.
//
//  Foundation only, so it runs in unit tests off-device.
//

import CoreGraphics
import Foundation

/// Reading order for the boxes on one page (see the file header).
enum ReadingOrder {
	enum Tuning {
		/// A gutter is at least this many line heights wide …
		static let minGutterLines = 0.8
		/// … and each side of it holds boxes covering at least this share of the content's height,
		/// and at least this many line heights.
		static let minSideCoverage = 0.2
		static let minSideLines = 3.0
		/// Two boxes on either side of a gutter make a row when their tops agree within this many
		/// line heights, whatever their heights (a one-line label beside the paragraph it heads) …
		static let rowTolerance = 0.5
		/// … and sides where at least this share of the boxes (on the side with fewer) make rows are
		/// columns only when both read as prose, their typical box this many line heights wide, and
		/// where both run, each fills at least this share of the height the other fills (columns of
		/// prose do; a column of dates beside the entries they head fills a third or less).
		static let minRowShare = 0.5
		static let minProseLines = 8.0
		static let minBalance = 0.55
		/// A box at least this share of its region's width may span a gutter.
		static let wideShare = 0.55
		/// Boxes overlapping by more than this share of the smaller one make the layout unclear.
		static let maxOverlapShare = 0.2
		/// Pages with more boxes than this keep their order.
		static let maxBoxes = 600
		/// Regions nested deeper than this read top to bottom.
		static let maxDepth = 64
		/// Slack when comparing positions (page shares).
		static let epsilon = 1e-6
		/// A typical page's width per unit of height, for callers that don't know theirs.
		static let typicalAspect = 0.75
	}

	/// The reading order of `boxes` (normalized, top-left origin) as indices into it, for a page
	/// `aspect` wide per unit of height whose median line is `lineHeight` high (a share of the page's
	/// height). Nil when no columns were found (top to bottom, left to right stands) or the layout is
	/// unclear (see the file header): the caller keeps the order it has.
	static func order(_ boxes: [CGRect], lineHeight: Double, aspect: Double) -> [Int]? {
		let page = Page(boxes: boxes.map(Box.init), lineHeight: lineHeight, aspect: aspect)
		guard boxes.count >= 2, boxes.count <= Tuning.maxBoxes, lineHeight > 0, lineHeight.isFinite,
			  aspect > 0, aspect.isFinite, page.boxes.allSatisfy(\.isUsable), !page.hasOverlaps else { return nil }
		let start = page.boxes.indices.sorted { (page.boxes[$0].minY, page.boxes[$0].minX) < (page.boxes[$1].minY, page.boxes[$1].minX) }
		var pending = [Region(members: start, depth: 0)]
		var result: [Int] = []
		var foundColumns = false
		// Every cut makes two or more smaller regions, so there are fewer regions than twice the boxes.
		for _ in 0..<(2 * boxes.count) {
			guard let region = pending.popLast() else { break }
			switch page.cut(region.members, depth: region.depth) {
			case .leaf:
				result.append(contentsOf: region.members)
			case .parts(let parts, let columns):
				assert(parts.count >= 2 && parts.allSatisfy { !$0.isEmpty }, "a cut makes two or more parts")
				foundColumns = foundColumns || columns
				pending.append(contentsOf: parts.reversed().map { Region(members: $0, depth: region.depth + 1) })
			case .unsure:
				return nil
			}
		}
		guard pending.isEmpty, result.count == boxes.count, foundColumns else { return nil }
		return result
	}

	/// `blocks` in reading order (`order`), or nil when that's unsure or finds no columns, or a block
	/// has no box.
	static func ordered(_ blocks: [FolioBlock], lineHeight: Double, aspect: Double) -> [FolioBlock]? {
		let boxes = blocks.compactMap { $0.box?.rect }
		guard boxes.count == blocks.count, let order = order(boxes, lineHeight: lineHeight, aspect: aspect) else { return nil }
		return order.map { blocks[$0] }
	}

	// MARK: Model

	/// A box in page shares, as Doubles.
	struct Box: Equatable {
		var minX: Double
		var minY: Double
		var maxX: Double
		var maxY: Double

		init(_ rect: CGRect) {
			minX = Double(rect.minX)
			minY = Double(rect.minY)
			maxX = Double(rect.maxX)
			maxY = Double(rect.maxY)
		}

		var width: Double { maxX - minX }
		var height: Double { maxY - minY }
		var area: Double { width * height }

		/// Finite, with some width and height.
		var isUsable: Bool {
			[minX, minY, maxX, maxY].allSatisfy(\.isFinite) && width > 0 && height > 0
		}

		/// The area `self` shares with `other`.
		func overlap(_ other: Box) -> Double {
			let across = min(maxX, other.maxX) - max(minX, other.minX)
			let down = min(maxY, other.maxY) - max(minY, other.minY)
			return across > 0 && down > 0 ? across * down : 0
		}

		/// Where the box starts and ends along `axis`.
		func range(_ axis: Axis) -> (start: Double, end: Double) {
			axis == .x ? (minX, maxX) : (minY, maxY)
		}
	}

	enum Axis {
		case x, y
	}

	/// An empty stretch between boxes along one axis (page shares).
	struct Gap: Equatable {
		var start: Double
		var end: Double
		var width: Double { end - start }
	}

	/// A part of the page still to be ordered: indices into its boxes, top to bottom then left to right.
	fileprivate struct Region {
		let members: [Int]
		let depth: Int
	}

	/// What to do with a region.
	enum Cut: Equatable {
		/// Read it as it is: top to bottom, left to right.
		case leaf
		/// Read these parts in turn; `columns` when they are columns side by side.
		case parts([[Int]], columns: Bool)
		/// The layout is unclear: keep the page's order.
		case unsure
	}
}

// MARK: - Cutting

extension ReadingOrder {
	/// The page being ordered: its boxes and the measures every cut is judged by.
	struct Page {
		let boxes: [Box]
		/// Median line height, a share of the page's height.
		let lineHeight: Double
		/// Page width per unit of height: turns a share of the width into one of the height.
		let aspect: Double

		/// True when two boxes overlap by more than `maxOverlapShare` of the smaller one.
		var hasOverlaps: Bool {
			for (index, box) in boxes.enumerated() {
				for other in boxes[(index + 1)...] where box.overlap(other) > Tuning.maxOverlapShare * min(box.area, other.area) {
					return true
				}
			}
			return false
		}

		/// How to read `members` (top to bottom, left to right): down a gutter through all of them,
		/// in bands around boxes spanning a gutter, across the widest horizontal gap, or as they are.
		func cut(_ members: [Int], depth: Int = 0) -> Cut {
			guard members.count >= 2, depth < Tuning.maxDepth else { return .leaf }
			if let sides = columnCut(members) {
				return .parts(sides, columns: true)
			}
			if let spanned = spannedColumnCut(members) {
				return spanned
			}
			guard let rows = rowCut(members) else { return .leaf }
			return .parts(rows, columns: false)
		}

		/// The two sides of the widest gutter (`isGutter`) running through all of `members`, or nil.
		func columnCut(_ members: [Int]) -> [[Int]]? {
			let height = span(members, .y)
			for gap in gaps(members, .x).sorted(by: { $0.width > $1.width }) {
				let sides = split(members, at: gap, .x)
				if isGutter(gap, left: sides.before, right: sides.after, height: height) {
					return [sides.before, sides.after]
				}
			}
			return nil
		}

		/// A gutter that wide boxes cross (a full-width heading, picture or paragraph): `members` cut
		/// into bands at the gaps above and below each of those boxes, so the columns between them read
		/// in turn. `.unsure` when such a box shares its band with anything else; nil when there is no
		/// such gutter.
		///
		/// Gutters are looked for between the narrower boxes. A wide box reaching across the whole of
		/// one spans it; wide boxes reaching into it only from one side narrow it.
		func spannedColumnCut(_ members: [Int]) -> Cut? {
			let width = span(members, .x)
			let wide = members.filter { boxes[$0].width >= Tuning.wideShare * width }
			let narrow = members.filter { boxes[$0].width < Tuning.wideShare * width }
			guard !wide.isEmpty, narrow.count >= 2 else { return nil }
			for candidate in gaps(narrow, .x).sorted(by: { $0.width > $1.width }) {
				let spanners = Set(wide.filter { index in
					boxes[index].minX <= candidate.start + Tuning.epsilon && boxes[index].maxX >= candidate.end - Tuning.epsilon
				})
				let rest = members.filter { !spanners.contains($0) }
				let inside = gaps(rest, .x).filter { $0.start >= candidate.start - Tuning.epsilon && $0.end <= candidate.end + Tuning.epsilon }
				guard !spanners.isEmpty, let gap = inside.max(by: { $0.width < $1.width }) else { continue }
				let sides = split(rest, at: gap, .x)
				guard isGutter(gap, left: sides.before, right: sides.after, height: span(rest, .y)) else { continue }
				return bands(members, spanners: spanners)
			}
			return nil
		}

		/// `members` cut into bands: each row holding `spanners` alone, the rows between them together.
		/// `.unsure` when a spanner shares its row with another box, or nothing could be cut. (The
		/// bands aren't columns yet: the rows between are cut down their gutter in turn.)
		func bands(_ members: [Int], spanners: Set<Int>) -> Cut {
			var parts: [[Int]] = []
			var between: [Int] = []
			for row in rows(members) {
				let spanning = row.filter { spanners.contains($0) }
				guard !spanning.isEmpty else {
					between.append(contentsOf: row)
					continue
				}
				guard spanning.count == row.count else { return .unsure }
				if !between.isEmpty {
					parts.append(between)
					between = []
				}
				parts.append(row)
			}
			if !between.isEmpty {
				parts.append(between)
			}
			guard parts.count >= 2 else { return .unsure }
			return .parts(parts, columns: false)
		}

		/// `members` cut across their widest horizontal gap, or nil when there is none.
		func rowCut(_ members: [Int]) -> [[Int]]? {
			guard let gap = gaps(members, .y).max(by: { $0.width < $1.width }) else { return nil }
			let sides = split(members, at: gap, .y)
			guard !sides.before.isEmpty, !sides.after.isEmpty else { return nil }
			return [sides.before, sides.after]
		}

		// MARK: Judging a gutter

		/// True when `gap`, with `left` and `right` beside it, is a column gutter: wide enough, no wider
		/// than either column, real content on both sides (against `height`, the content's height),
		/// and, when they line up in rows, prose on both sides that fills about as much height.
		func isGutter(_ gap: Gap, left: [Int], right: [Int], height: Double) -> Bool {
			guard !left.isEmpty, !right.isEmpty, height > 0 else { return false }
			guard gap.width * aspect >= Tuning.minGutterLines * lineHeight,
				  gap.width <= min(span(left, .x), span(right, .x)) else { return false }
			let needed = max(Tuning.minSideCoverage * height, Tuning.minSideLines * lineHeight)
			guard coverage(left) >= needed, coverage(right) >= needed else { return false }
			guard makesRows(left, right) else { return true }
			return readsAsProse(left) && readsAsProse(right) && isBalanced(left, right)
		}

		/// True when most boxes on the side with fewer start level with a box on the other side. Only
		/// tops count: a one-line label and the three-line entry beside it start a row together.
		func makesRows(_ left: [Int], _ right: [Int]) -> Bool {
			let (fewer, more) = left.count <= right.count ? (left, right) : (right, left)
			guard !fewer.isEmpty else { return false }
			let tolerance = Tuning.rowTolerance * lineHeight
			let paired = fewer.filter { index in
				more.contains { other in abs(boxes[index].minY - boxes[other].minY) <= tolerance }
			}
			return Double(paired.count) >= Tuning.minRowShare * Double(fewer.count)
		}

		/// True when, over the height both sides run, each fills at least `minBalance` of what the
		/// other fills. Two columns of prose do, even when one ends early; labels beside the entries
		/// they head (dates in a CV, times in an agenda, terms in a glossary) don't.
		func isBalanced(_ left: [Int], _ right: [Int]) -> Bool {
			let leftRange = extent(left, .y), rightRange = extent(right, .y)
			let shared = (start: max(leftRange.start, rightRange.start), end: min(leftRange.end, rightRange.end))
			guard shared.end > shared.start else { return false }
			let filled = (coverage(left, within: shared), coverage(right, within: shared))
			let fuller = max(filled.0, filled.1)
			guard fuller > 0 else { return false }
			return min(filled.0, filled.1) >= Tuning.minBalance * fuller
		}

		/// True when the side's typical box is as wide as a line of prose.
		func readsAsProse(_ side: [Int]) -> Bool {
			let widths = side.map { boxes[$0].width }.sorted()
			guard let typical = widths[safe: widths.count / 2] else { return false }
			return typical * aspect >= Tuning.minProseLines * lineHeight
		}

		// MARK: Measuring

		/// The empty stretches between `members` along `axis`, first to last.
		func gaps(_ members: [Int], _ axis: Axis) -> [Gap] {
			let ranges = members.map { boxes[$0].range(axis) }.sorted { $0.start < $1.start }
			guard let first = ranges.first else { return [] }
			var result: [Gap] = []
			var reach = first.end
			for range in ranges.dropFirst() {
				if range.start > reach + Tuning.epsilon {
					result.append(Gap(start: reach, end: range.start))
				}
				reach = max(reach, range.end)
			}
			return result
		}

		/// `members` before `gap` along `axis` and those after it, each in their order.
		func split(_ members: [Int], at gap: Gap, _ axis: Axis) -> (before: [Int], after: [Int]) {
			let before = members.filter { boxes[$0].range(axis).end <= gap.start + Tuning.epsilon }
			let after = members.filter { boxes[$0].range(axis).end > gap.start + Tuning.epsilon }
			return (before, after)
		}

		/// `members` (top to bottom) grouped into rows: runs whose vertical extents touch or overlap.
		func rows(_ members: [Int]) -> [[Int]] {
			var result: [[Int]] = []
			var reach = -Double.infinity
			for index in members {
				if result.isEmpty || boxes[index].minY > reach + Tuning.epsilon {
					result.append([index])
				} else {
					result[result.count - 1].append(index)
				}
				reach = max(reach, boxes[index].maxY)
			}
			return result
		}

		/// From the first box's start to the last box's end along `axis`.
		func span(_ members: [Int], _ axis: Axis) -> Double {
			let range = extent(members, axis)
			return range.end - range.start
		}

		/// Where the first box starts and the last box ends along `axis`; zero for no boxes.
		func extent(_ members: [Int], _ axis: Axis) -> (start: Double, end: Double) {
			let ranges = members.map { boxes[$0].range(axis) }
			guard let start = ranges.map(\.start).min(), let end = ranges.map(\.end).max() else { return (0, 0) }
			return (start, end)
		}

		/// The height `members` cover, overlaps counted once; only what falls `within` it, when given.
		func coverage(_ members: [Int], within limits: (start: Double, end: Double)? = nil) -> Double {
			let lower = limits?.start ?? -Double.infinity, upper = limits?.end ?? Double.infinity
			let ranges = members.map { boxes[$0].range(.y) }
				.map { (start: max($0.start, lower), end: min($0.end, upper)) }
				.filter { $0.end > $0.start }
				.sorted { $0.start < $1.start }
			var covered = 0.0
			var reach = -Double.infinity
			for range in ranges where range.end > reach {
				covered += range.end - max(range.start, reach)
				reach = range.end
			}
			return covered
		}
	}
}
