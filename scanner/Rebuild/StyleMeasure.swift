//
//  StyleMeasure.swift
//  Rescriva (fork of Open Scanner)
//
//  The pixel side of StyleDetector. Each OCR line's crop is binarized with
//  Sauvola's threshold and cut into words at its widest gaps; each word's
//  stroke width, slant and slanted edges are measured on its grey crop scaled
//  to a 32 px x-height, and its underline and strikethrough strokes on the
//  line at full size, where rules and table borders can be told apart. Every
//  step returns nil (abstains) rather than guess.
//

import CoreGraphics
import Foundation

// MARK: - Lines

extension StyleDetector {
	/// Reads one OCR line: its crop, its words and each word's cues.
	enum LineReader {
		/// The line's reading, or nil when it abstains (low contrast, a cut that doesn't match its
		/// words, small or handwriting-like text).
		static func read(_ index: Int, lines: [RecognizedLine], page: Gray, role: LineRole) -> LineReading? {
			guard let line = lines[safe: index],
				  let frame = cropFrame(for: index, lines: lines, width: page.width, height: page.height) else { return nil }
			let tokens = StyleDetector.words(in: line.text)
			guard !tokens.isEmpty, tokens.count <= Tuning.maxWordsPerLine else { return nil }
			let crop = page.cropped(columns: frame.columns, rows: frame.rows)
			let levels = crop.levels(at: Tuning.lineInkShare, Tuning.linePaperShare)
			let paper = levels.high, ink = levels.low
			guard paper - ink >= Tuning.minLineContrast else { return nil }
			let radius = max(4, Int((frame.lineHeight / 2).rounded()))
			let mask = Ink(sauvola: crop, radius: radius, ceiling: paper - (paper - ink) / 4)
			let runs = mask.rowRuns()
			guard let layout = LineLayout(runs: runs, width: mask.width, tokens: tokens, lineHeight: frame.lineHeight) else { return nil }
			let context = LineContext(crop: crop, mask: mask, runs: runs, layout: layout, ink: ink, contrast: paper - ink)
			let words = tokens.indices.map { measureWord($0, token: tokens[$0], in: context) }
			return LineReading(index: index, role: role, tokens: tokens, words: words)
		}

		/// The part of the page read for line `index`: its box widened by margins, the top and bottom
		/// ones stopping at the boxes of the lines just above and below it.
		static func cropFrame(for index: Int, lines: [RecognizedLine], width: Int, height: Int) -> CropFrame? {
			guard let box = lines[safe: index]?.box, box.width > 0, box.height > 0, width > 0, height > 0 else { return nil }
			var top = box.minY - Tuning.topMargin * box.height
			var bottom = box.maxY + Tuning.bottomMargin * box.height
			for (other, neighbour) in lines.enumerated() where other != index {
				let near = neighbour.box
				guard near.minX < box.maxX, box.minX < near.maxX else { continue }
				if near.midY < box.minY {
					top = max(top, min(box.minY, near.maxY))
				} else if near.midY > box.maxY {
					bottom = min(bottom, max(box.maxY, near.minY))
				}
			}
			let side = Tuning.sideMargin * box.height * Double(height) / Double(width)
			let left = Int(((box.minX - side) * Double(width)).rounded(.down))
			let right = Int(((box.maxX + side) * Double(width)).rounded(.up))
			let columns = (left..<max(left, right)).clamped(to: 0..<width)
			let upper = Int((top * Double(height)).rounded(.down))
			let rows = (upper..<max(upper, Int((bottom * Double(height)).rounded(.up)))).clamped(to: 0..<height)
			guard columns.count >= Tuning.minCropSide, rows.count >= Tuning.minCropSide else { return nil }
			return CropFrame(columns: columns, rows: rows, lineHeight: box.height * Double(height))
		}

		/// One word's cues; nil for words under 3 letters and low-contrast words.
		static func measureWord(_ offset: Int, token: String, in line: LineContext) -> WordReading? {
			let letters = StyleDetector.letterCount(token)
			guard letters >= Tuning.minLetters, let span = line.layout.spans[safe: offset],
				  let band = line.layout.bands[safe: offset] else { return nil }
			let xHeight = line.layout.xHeight
			let baseline = band.bottom
			let top = max(0, baseline - Int((Tuning.ascenderReach * xHeight).rounded()))
			let columns = (span.lowerBound - Tuning.wordPad)..<(span.upperBound + Tuning.wordPad)
			let crop = line.crop.cropped(columns: columns, rows: top..<baseline)
			let scale = Tuning.normalizedXHeight / xHeight
			guard let shape = WordShape(crop, scale: scale, bandTop: band.top - top, spanWidth: span.count, line: line) else { return nil }
			let underline = Strokes.covers(span, rows: underlineRows(below: baseline, xHeight: xHeight), in: line)
			let strike = Strokes.covers(span, rows: strikeRows(above: baseline, xHeight: xHeight), in: line)
			return WordReading(strokeWidth: shape.strokeWidth, slant: shape.slant, edgeHits: shape.edgeHits / Double(letters),
							   uprightHits: shape.uprightHits / Double(letters), mirroredHits: shape.mirroredHits / Double(letters),
							   underline: underline, strikethrough: strike)
		}

		/// From just under the baseline to 0.4 x-height below it.
		static func underlineRows(below baseline: Int, xHeight: Double) -> Range<Int> {
			let first = baseline + max(1, Int((Tuning.underlineGap * xHeight).rounded()))
			let last = baseline + Int((Tuning.underlineDepth * xHeight).rounded())
			return first..<max(first, last + 1)
		}

		/// Around mid x-height.
		static func strikeRows(above baseline: Int, xHeight: Double) -> Range<Int> {
			let first = baseline - Int((Tuning.strikeHigh * xHeight).rounded())
			let last = baseline - Int((Tuning.strikeLow * xHeight).rounded())
			return first..<max(first, last + 1)
		}
	}

	/// The pixels read for one line, in page pixels, and its box's height.
	struct CropFrame: Hashable {
		var columns: Range<Int>
		var rows: Range<Int>
		var lineHeight: Double
	}

	/// One line's crop and what was found on it, for measuring its words.
	struct LineContext {
		var crop: Gray
		var mask: Ink
		var runs: [[Range<Int>]]
		var layout: LineLayout
		/// The line's ink grey level, and how far the paper is from it.
		var ink: Int
		var contrast: Int
	}

	/// Where a line's words sit in its crop: their columns and x-height bands, the line's x-height
	/// (the median of its words') and the columns its text spans.
	struct LineLayout {
		var spans: [Range<Int>]
		var bands: [Band]
		var xHeight: Double
		var text: Range<Int>

		/// Cuts the line into `tokens.count` words, or nil when the cut doesn't match, the text is
		/// too small, or its words' x-heights vary like handwriting.
		init?(runs: [[Range<Int>]], width: Int, tokens: [String], lineHeight: Double) {
			// Long strokes (underlines, strikethroughs, rules) would bridge word gaps and skew the bands.
			let longest = max(Tuning.minCropSide, Int(lineHeight.rounded()))
			guard width > 0, !tokens.isEmpty,
				  let lineBand = Band(profile: Self.rowProfile(runs, columns: 0..<width, below: longest)),
				  Double(lineBand.height) >= Tuning.minXHeight * 0.75 else { return nil }
			let capitals = max(0, lineBand.top - Int((Tuning.capitalReach * Double(lineBand.height)).rounded()))..<lineBand.top
			let inked = Self.bridging(Self.inkedColumns(runs, width: width, rows: lineBand.rows, below: longest), runs: runs,
									  rows: capitals, bar: Tuning.minBridgeBar * Double(lineBand.height), below: longest)
			guard let spans = StyleDetector.wordSpans(inked, count: tokens.count, xHeight: Double(lineBand.height)) else { return nil }
			var bands: [Band] = []
			for span in spans {
				let own = Int((Tuning.minStrokeShare * Double(span.count)).rounded(.up))
				guard let band = Band(profile: Self.rowProfile(runs, columns: span, below: max(2, own))) else { return nil }
				bands.append(band)
			}
			let measured = tokens.indices.filter { StyleDetector.letterCount(tokens[$0]) >= Tuning.minLetters }
			let heights = (measured.isEmpty ? Array(tokens.indices) : measured).map { Double(bands[$0].height) }
			guard let xHeight = StyleDetector.median(heights), xHeight >= Tuning.minXHeight,
				  StyleDetector.spread(heights) <= Tuning.maxXHeightSpread,
				  Self.widthsFit(spans, tokens: tokens, xHeight: xHeight),
				  let first = spans.first, let last = spans.last else { return nil }
			self.spans = spans
			self.bands = bands
			self.xHeight = xHeight
			text = first.lowerBound..<last.upperBound
		}

		/// Every word of 3 characters or more is about as wide as its characters: a cut that
		/// matched the word count by chance doesn't.
		static func widthsFit(_ spans: [Range<Int>], tokens: [String], xHeight: Double) -> Bool {
			guard spans.count == tokens.count, xHeight > 0 else { return false }
			for (span, token) in zip(spans, tokens) where token.count >= Tuning.minLetters {
				let perLetter = Double(span.count) / (Double(token.count) * xHeight)
				guard perLetter >= Tuning.minWidthPerLetter, perLetter <= Tuning.maxWidthPerLetter else { return false }
			}
			return true
		}

		/// Ink per row within `columns`, leaving out runs `below` long or longer.
		static func rowProfile(_ runs: [[Range<Int>]], columns: Range<Int>, below longest: Int) -> [Int] {
			assert(longest > 0, "some runs are short enough to count")
			return runs.map { row in
				var count = 0
				for run in row where run.count < longest && run.overlaps(columns) {
					count += run.clamped(to: columns).count
				}
				return count
			}
		}

		/// `inked` with each gap filled where one horizontal bar in `rows` (the cap and ascender zone)
		/// spans most of it: the bar of a T or an F over its next letter, not a word gap. A bar is a
		/// run at least `bar` pixels long (a leaning stroke's cross-section is shorter).
		static func bridging(_ inked: [Bool], runs: [[Range<Int>]], rows: Range<Int>, bar: Double, below longest: Int) -> [Bool] {
			guard let first = inked.firstIndex(of: true), let last = inked.lastIndex(of: true), first < last else { return inked }
			var result = inked
			var gapStart: Int?
			for column in first...last {
				if !inked[column], gapStart == nil {
					gapStart = column
				}
				guard inked[column], let start = gapStart else { continue }
				gapStart = nil
				let gap = start..<column
				guard isBridged(gap, runs: runs, rows: rows, bar: bar, below: longest) else { continue }
				for filled in gap {
					result[filled] = true
				}
			}
			return result
		}

		static func isBridged(_ gap: Range<Int>, runs: [[Range<Int>]], rows: Range<Int>, bar: Double, below longest: Int) -> Bool {
			guard !gap.isEmpty else { return false }
			let cover = Tuning.minBridgeCover * Double(gap.count)
			for row in rows {
				for run in runs[safe: row] ?? [] where run.count < longest && Double(run.count) >= bar {
					if Double(run.clamped(to: gap).count) >= cover { return true }
				}
			}
			return false
		}

		/// Whether each column has ink in `rows`, leaving out runs `below` long or longer.
		static func inkedColumns(_ runs: [[Range<Int>]], width: Int, rows: Range<Int>, below longest: Int) -> [Bool] {
			var inked = [Bool](repeating: false, count: max(0, width))
			guard width > 0 else { return inked }
			for row in rows {
				for run in runs[safe: row] ?? [] where run.count < longest {
					for column in run.clamped(to: 0..<width) {
						inked[column] = true
					}
				}
			}
			return inked
		}
	}

	/// The densest band of rows in a horizontal projection: a word's or a line's x-height zone.
	struct Band: Hashable {
		/// First row of the zone.
		var top: Int
		/// One past its last row: the baseline.
		var bottom: Int

		var height: Int { bottom - top }
		var rows: Range<Int> { top..<bottom }

		init(top: Int, bottom: Int) {
			assert(bottom >= top, "a band runs downwards")
			self.top = top
			self.bottom = bottom
		}

		/// The run of rows with the most ink above `bandShare` of the busiest row (the largest-sum
		/// subarray, so a thin row inside the zone doesn't split it); nil for an empty profile.
		init?(profile: [Int]) {
			guard let peak = profile.max(), peak > 0 else { return nil }
			let floor = Tuning.bandShare * Double(peak)
			var best = (sum: 0.0, top: 0, bottom: 0)
			var current = (sum: 0.0, top: 0)
			for (row, count) in profile.enumerated() {
				if current.sum <= 0 {
					current = (0, row)
				}
				current.sum += Double(count) - floor
				if current.sum > best.sum {
					best = (current.sum, current.top, row + 1)
				}
			}
			guard best.bottom > best.top else { return nil }
			self.init(top: best.top, bottom: best.bottom)
		}
	}

	/// Each of `count` words' columns: the line's ink cut at its `count − 1` widest gaps, kept only
	/// when those are word gaps, clearly wider than every gap left (between letters).
	static func wordSpans(_ inked: [Bool], count: Int, xHeight: Double) -> [Range<Int>]? {
		guard count > 0, xHeight > 0, let first = inked.firstIndex(of: true), let last = inked.lastIndex(of: true) else { return nil }
		var gaps: [Range<Int>] = []
		var gapStart: Int?
		for column in first...last {
			if inked[column], let start = gapStart {
				gaps.append(start..<column)
				gapStart = nil
			} else if !inked[column], gapStart == nil {
				gapStart = column
			}
		}
		let ranked = gaps.sorted { $0.count != $1.count ? $0.count > $1.count : $0.lowerBound < $1.lowerBound }
		guard ranked.count >= count - 1 else { return nil }
		let cuts = ranked.prefix(count - 1).sorted { $0.lowerBound < $1.lowerBound }
		let letterGap = Double(ranked.dropFirst(count - 1).first?.count ?? 0)
		if let wordGap = cuts.map(\.count).min().map(Double.init) {
			guard wordGap >= Tuning.minWordGap * xHeight, letterGap <= Tuning.maxLetterGapShare * wordGap else { return nil }
		} else {
			guard letterGap < Tuning.maxSingleWordGap * xHeight else { return nil }
		}
		var spans: [Range<Int>] = []
		var start = first
		for cut in cuts {
			spans.append(start..<cut.lowerBound)
			start = cut.upperBound
		}
		spans.append(start..<(last + 1))
		return spans
	}

	/// (Q3 − Q1) / median of `values` — the range over the median for two, 0 for one.
	static func spread(_ values: [Double]) -> Double {
		guard values.count >= 2, let middle = median(values), middle > 0 else { return 0 }
		let sorted = values.sorted()
		let low = values.count >= 4 ? sorted[sorted.count / 4] : sorted[0]
		let high = values.count >= 4 ? sorted[(3 * sorted.count) / 4] : sorted[sorted.count - 1]
		return (high - low) / middle
	}
}

// MARK: - Word shape

extension StyleDetector {
	/// A word's stroke width, slant and slanted edges, measured on its grey crop (x-height zone and
	/// ascenders) scaled to the normalized x-height and thresholded halfway between its paper and
	/// the line's ink, with strikethrough strokes taken out.
	struct WordShape {
		var strokeWidth: Double
		var slant: Double
		/// Long right-leaning edges at `slant`, long upright edges, and long edges leaning left as far
		/// (the mirror of `slant`), in all (each 0 for a word leaning less than `minHitSlant`).
		var edgeHits: Double
		var uprightHits: Double
		var mirroredHits: Double

		/// Nil for a low-contrast word (glare, a faint patch) or one with too little ink to measure.
		init?(_ crop: Gray, scale: Double, bandTop: Int, spanWidth: Int, line: LineContext) {
			guard crop.width > 2, crop.height > 2, scale > 0 else { return nil }
			let normal = crop.resampled(by: scale)
			let levels = normal.levels(at: Tuning.wordInkShare, Tuning.wordPaperShare)
			guard Double(levels.high - levels.low) >= Tuning.minWordContrastShare * Double(line.contrast),
				  levels.high > line.ink else { return nil }
			let mask = Ink(normal, darkerThan: (levels.high + line.ink) / 2)
			let longest = max(2, Int((Tuning.minStrokeShare * Double(spanWidth) * scale).rounded(.up)))
			let runs = mask.rowRuns()
			let letters = runs.map { row in row.filter { $0.count < longest } }
			let firstRow = min(mask.height - 1, max(0, Int((Double(bandTop) * scale).rounded())))
			guard let width = Self.strokeWidth(letters, width: mask.width, rows: firstRow..<mask.height),
				  let slant = Self.dominantSlant(letters, height: mask.height, width: mask.width) else { return nil }
			strokeWidth = width
			self.slant = Double(slant)
			guard Double(slant) >= Tuning.minHitSlant else {
				edgeHits = 0
				uprightHits = 0
				mirroredHits = 0
				return
			}
			let clean = mask.removing(runs, atLeast: longest)
			edgeHits = Double(Self.slantedEdgeHits(clean, degrees: Double(slant)))
			uprightHits = Double(Self.slantedEdgeHits(clean, degrees: 0))
			mirroredHits = Double(Self.slantedEdgeHits(clean, degrees: -Double(slant)))
		}

		/// 2 · ink area / outline length over `rows` of a mask given by its row runs. The outline is
		/// measured with Crofton's formula over four directions, so diagonal strokes aren't
		/// over-counted; the edges where a stroke is cut by the first or last row, or by the sides,
		/// don't count.
		static func strokeWidth(_ runs: [[Range<Int>]], width: Int, rows: Range<Int>) -> Double? {
			guard rows.count >= 2, width >= 2, rows.lowerBound >= 0, rows.upperBound <= runs.count else { return nil }
			var area = 0, straight = 0, diagonal = 0
			for y in rows {
				for run in runs[y] {
					area += run.count
					straight += (run.lowerBound > 0 ? 1 : 0) + (run.upperBound < width ? 1 : 0)
				}
				guard y + 1 < rows.upperBound else { continue }
				// Changes from each pixel to the one below it, below right and below left.
				straight += differing(runs[y], runs[y + 1], shift: 0, within: 0..<width)
				diagonal += differing(runs[y], runs[y + 1], shift: 1, within: 0..<(width - 1))
				diagonal += differing(runs[y], runs[y + 1], shift: -1, within: 1..<width)
			}
			let outline = Double.pi / 8 * (Double(straight) + Double(diagonal) / Self.rootTwo)
			guard area >= Tuning.minStrokeInk, outline > 0 else { return nil }
			return 2 * Double(area) / outline
		}

		/// How many columns x in `within` have ink at x in `upper` but not at x + `shift` in
		/// `lower`, or the other way round.
		static func differing(_ upper: [Range<Int>], _ lower: [Range<Int>], shift: Int, within: Range<Int>) -> Int {
			let first = upper.map { $0.clamped(to: within) }.filter { !$0.isEmpty }
			let second = lower.map { ($0.lowerBound - shift)..<($0.upperBound - shift) }.map { $0.clamped(to: within) }.filter { !$0.isEmpty }
			let both = overlap(first, second)
			return first.reduce(0) { $0 + $1.count } + second.reduce(0) { $0 + $1.count } - 2 * both
		}

		/// Columns two sorted, non-overlapping run lists share.
		static func overlap(_ first: [Range<Int>], _ second: [Range<Int>]) -> Int {
			var shared = 0, i = 0, j = 0
			for _ in 0..<(first.count + second.count) {
				guard i < first.count, j < second.count else { break }
				shared += first[i].clamped(to: second[j]).count
				if first[i].upperBound <= second[j].upperBound {
					i += 1
				} else {
					j += 1
				}
			}
			return shared
		}

		static let rootTwo = 2.0.squareRoot()

		/// The shear, in whole degrees from −5 to 25, that makes the word's vertical projection
		/// sharpest (the largest sum of squared column counts): every 3° first, then each degree
		/// around the best. Ties go to the more upright angle. Each horizontal run of ink (from
		/// `rowRuns`, strikethroughs left out) counts once, at its middle, so the stems decide
		/// rather than the bulk of the ink.
		static func dominantSlant(_ runs: [[Range<Int>]], height: Int, width: Int) -> Int? {
			var columns: [Int] = []
			var rises: [Int] = []
			for (y, row) in runs.enumerated() where y < height {
				for run in row {
					// Doubled, so the middle of an even run keeps its half pixel.
					columns.append(run.lowerBound + run.upperBound - 1)
					rises.append(2 * (height - y))
				}
			}
			guard columns.count >= Tuning.minSlantRuns, width > 0 else { return nil }
			let reach = 2 * Int((Double(height) * tan(Double(Tuning.maxSlant) * .pi / 180)).rounded(.up)) + 4
			var bins = [Int](repeating: 0, count: 2 * width + 2 * reach + 1)
			var best = (degrees: 0, score: -1)
			let coarse = Array(stride(from: Tuning.minSlant, through: Tuning.maxSlant, by: Tuning.coarseSlantStep))
			let around = { (centre: Int) in ((centre - 2)...(centre + 2)).filter { $0 != centre && $0 >= Tuning.minSlant && $0 <= Tuning.maxSlant } }
			for pass in 0..<2 {
				for degrees in pass == 0 ? coarse : around(best.degrees) {
					let score = sharpness(columns, rises, degrees: degrees, reach: reach, bins: &bins)
					if score > best.score || (score == best.score && abs(degrees) < abs(best.degrees)) {
						best = (degrees, score)
					}
				}
			}
			return best.degrees
		}

		/// Sum of squared column counts once each point is shifted left by its height above the
		/// bottom row (`rises`) times tan(`degrees`): large when the shear stands the strokes upright.
		/// Fixed-point (16 fractional bits); `bins` is scratch space, `reach` columns of margin each side.
		static func sharpness(_ columns: [Int], _ rises: [Int], degrees: Int, reach: Int, bins: inout [Int]) -> Int {
			assert(columns.count == rises.count, "one rise per ink pixel")
			for index in bins.indices {
				bins[index] = 0
			}
			let shear = Int((tan(Double(degrees) * .pi / 180) * 65536).rounded())
			let lastBin = bins.count - 1
			for index in columns.indices {
				let bin = columns[index] + reach - ((rises[index] * shear + 32768) >> 16)
				bins[min(lastBin, max(0, bin))] += 1
			}
			var score = 0
			for count in bins {
				score += count * count
			}
			return score
		}

		/// Ink pixels on a long straight edge leaning right at `degrees`: ink there and at three
		/// points further up the slant, each with paper two pixels beside it (left or right), as in
		/// Leptonica's pixItalicWords sel. Round strokes, and strokes at other angles, rarely line up
		/// that far; at 0° it counts upright edges.
		static func slantedEdgeHits(_ mask: Ink, degrees: Double) -> Int {
			let shear = tan(degrees * .pi / 180)
			let shifts = (0...Tuning.edgeSamples).map { Int((Double($0 * Tuning.edgeStep) * shear).rounded()) }
			let reach = Tuning.edgeSamples * Tuning.edgeStep
			guard mask.height > reach else { return 0 }
			var hits = 0
			for y in reach..<mask.height {
				for x in 0..<mask.width where mask[x, y] {
					hits += isSlantedEdge(mask, x: x, y: y, shifts: shifts, side: -Tuning.edgeGap) ? 1 : 0
					hits += isSlantedEdge(mask, x: x, y: y, shifts: shifts, side: Tuning.edgeGap) ? 1 : 0
				}
			}
			return hits
		}

		static func isSlantedEdge(_ mask: Ink, x: Int, y: Int, shifts: [Int], side: Int) -> Bool {
			guard side != 0 else { return false }
			for (sample, shift) in shifts.enumerated() {
				let row = y - sample * Tuning.edgeStep, column = x + shift
				guard mask[column, row], !mask[column + side, row] else { return false }
			}
			return true
		}
	}
}

// MARK: - Underline and strikethrough

extension StyleDetector {
	/// Thin horizontal strokes under or through a word, on the line's full-size mask.
	enum Strokes {
		/// Whether a stroke in `rows` underlines (or strikes through) the word at `span`: runs at
		/// least 0.6× the word's width (an opening with that element) covering ≥ 85% of it, thinner
		/// than 0.2 x-height, and neither a rule nor a table border (`isTextStroke`).
		static func covers(_ span: Range<Int>, rows: Range<Int>, in line: LineContext) -> Bool {
			let rows = rows.clamped(to: 0..<line.mask.height)
			guard !rows.isEmpty, !span.isEmpty else { return false }
			let longest = Int((Tuning.minStrokeShare * Double(span.count)).rounded(.up))
			var depth = [Int](repeating: 0, count: span.count)
			var reach: Range<Int>?
			for y in rows {
				for run in line.runs[safe: y] ?? [] where run.count >= longest && run.overlaps(span) {
					for column in run.clamped(to: span) {
						depth[column - span.lowerBound] += 1
					}
					reach = reach.map { min($0.lowerBound, run.lowerBound)..<max($0.upperBound, run.upperBound) } ?? run
				}
			}
			let covered = depth.filter { $0 > 0 }.sorted()
			guard let reach, Double(covered.count) >= Tuning.minStrokeCoverage * Double(span.count),
				  let thickness = covered[safe: covered.count / 2],
				  Double(thickness) < Tuning.maxStrokeThickness * line.layout.xHeight + 1 else { return false }
			return isTextStroke(reach, rows: rows, in: line)
		}

		/// A stroke spanning `reach` belongs to the text: it stops short of the crop's sides (a rule
		/// runs across the whole column), doesn't run on past the line's text, and doesn't meet a
		/// vertical line at either end (a table border).
		static func isTextStroke(_ reach: Range<Int>, rows: Range<Int>, in line: LineContext) -> Bool {
			let xHeight = line.layout.xHeight
			guard reach.lowerBound > 0, reach.upperBound < line.mask.width else { return false }
			let overhang = Tuning.maxStrokeOverhang * xHeight
			guard Double(line.layout.text.lowerBound - reach.lowerBound) <= overhang,
				  Double(reach.upperBound - line.layout.text.upperBound) <= overhang else { return false }
			let tallest = Int((Tuning.verticalLineLength * xHeight).rounded())
			for end in [reach.lowerBound, reach.upperBound - 1] {
				for column in (end - Tuning.verticalLineReach)...(end + Tuning.verticalLineReach)
				where line.mask.verticalRun(column: column, through: rows) >= tallest {
					return false
				}
			}
			return true
		}
	}
}

// MARK: - Rasters

extension StyleDetector {
	/// An 8-bit grey raster, top row first: 0 is black, 255 white.
	struct Gray {
		let width: Int
		let height: Int
		let pixels: [UInt8]

		init(width: Int, height: Int, pixels: [UInt8]) {
			assert(pixels.count == width * height, "one byte per pixel")
			self.width = width
			self.height = height
			self.pixels = pixels
		}

		/// `image` drawn over white into device grey, scaled down to fit `maxSide`.
		init?(image: CGImage, maxSide: Int) {
			guard image.width > 0, image.height > 0, maxSide > 0 else { return nil }
			let scale = min(1, Double(maxSide) / Double(max(image.width, image.height)))
			let w = max(1, Int((Double(image.width) * scale).rounded()))
			let h = max(1, Int((Double(image.height) * scale).rounded()))
			guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
										  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
			else { return nil }
			let rect = CGRect(x: 0, y: 0, width: w, height: h)
			context.setFillColor(gray: 1, alpha: 1)
			context.fill(rect)
			context.interpolationQuality = .high
			context.draw(image, in: rect)
			guard let drawn = context.makeImage(), let data = drawn.dataProvider?.data as Data?,
				  drawn.bytesPerRow >= w, data.count >= drawn.bytesPerRow * h else { return nil }
			let source = [UInt8](data)
			var packed: [UInt8] = []
			packed.reserveCapacity(w * h)
			for y in 0..<h {
				packed.append(contentsOf: source[(y * drawn.bytesPerRow)..<(y * drawn.bytesPerRow + w)])
			}
			self.init(width: w, height: h, pixels: packed)
		}

		/// The pixels in `columns` × `rows`, clamped to the raster.
		func cropped(columns: Range<Int>, rows: Range<Int>) -> Gray {
			let columns = columns.clamped(to: 0..<width), rows = rows.clamped(to: 0..<height)
			guard !columns.isEmpty, !rows.isEmpty else { return Gray(width: 0, height: 0, pixels: []) }
			var out: [UInt8] = []
			out.reserveCapacity(columns.count * rows.count)
			for row in rows {
				let start = row * width
				out.append(contentsOf: pixels[(start + columns.lowerBound)..<(start + columns.upperBound)])
			}
			return Gray(width: columns.count, height: rows.count, pixels: out)
		}

		/// The grey levels that `low` and `high` shares of the pixels are at or below (`low` ≤ `high`).
		func levels(at low: Double, _ high: Double) -> (low: Int, high: Int) {
			assert(low <= high, "shares in order")
			guard !pixels.isEmpty else { return (255, 255) }
			var histogram = [Int](repeating: 0, count: 256)
			for value in pixels {
				histogram[Int(value)] += 1
			}
			let targets = [low, high].map { Int(Double(pixels.count - 1) * min(1, max(0, $0))) }
			var found: [Int] = []
			var seen = 0
			for level in 0..<256 {
				seen += histogram[level]
				for target in targets.dropFirst(found.count) where seen > target {
					found.append(level)
				}
				if found.count == targets.count { break }
			}
			return (found.first ?? 255, found.dropFirst().first ?? 255)
		}

		/// Scaled by `scale`: averaged over each output pixel's footprint when shrinking, bilinear
		/// when enlarging.
		func resampled(by scale: Double) -> Gray {
			guard scale > 0, width > 0, height > 0 else { return self }
			let w = max(1, Int((Double(width) * scale).rounded()))
			let h = max(1, Int((Double(height) * scale).rounded()))
			return scale < 1 ? shrunk(width: w, height: h) : enlarged(width: w, height: h)
		}

		private func enlarged(width w: Int, height h: Int) -> Gray {
			assert(w > 0 && h > 0, "an output pixel to fill")
			// Source columns and weights (8 fractional bits) are the same on every row.
			let samples = (0..<w).map { Self.sample($0, step: Double(width) / Double(w), limit: width) }
			let lefts = samples.map(\.0), rights = samples.map(\.1), weights = samples.map(\.2)
			var out = [UInt8](repeating: 255, count: w * h)
			for y in 0..<h {
				let (y0, y1, wy) = Self.sample(y, step: Double(height) / Double(h), limit: height)
				let upperRow = y0 * width, lowerRow = y1 * width, outRow = y * w
				for x in 0..<w {
					let left = lefts[x], right = rights[x], weight = weights[x]
					let upper = Int(pixels[upperRow + left]) * (256 - weight) + Int(pixels[upperRow + right]) * weight
					let lower = Int(pixels[lowerRow + left]) * (256 - weight) + Int(pixels[lowerRow + right]) * weight
					out[outRow + x] = UInt8(min(255, (upper * (256 - wy) + lower * wy + 32768) >> 16))
				}
			}
			return Gray(width: w, height: h, pixels: out)
		}

		/// The two source pixels around output pixel `index` and the far one's weight out of 256.
		private static func sample(_ index: Int, step: Double, limit: Int) -> (Int, Int, Int) {
			assert(limit > 0, "a source pixel to sample")
			let position = min(Double(limit - 1), max(0, (Double(index) + 0.5) * step - 0.5))
			let first = Int(position)
			return (first, min(limit - 1, first + 1), Int(((position - Double(first)) * 256).rounded()))
		}

		private func shrunk(width w: Int, height h: Int) -> Gray {
			assert(w <= width && h <= height, "shrinking")
			var out = [UInt8](repeating: 255, count: w * h)
			for y in 0..<h {
				let rows = (y * height / h)..<max(y * height / h + 1, (y + 1) * height / h)
				for x in 0..<w {
					let columns = (x * width / w)..<max(x * width / w + 1, (x + 1) * width / w)
					var total = 0
					for row in rows {
						for column in columns {
							total += Int(pixels[row * width + column])
						}
					}
					out[y * w + x] = UInt8(total / (rows.count * columns.count))
				}
			}
			return Gray(width: w, height: h, pixels: out)
		}
	}

	/// Ink (true) or paper, top row first.
	struct Ink {
		let width: Int
		let height: Int
		var cells: [Bool]

		init(width: Int, height: Int, cells: [Bool]) {
			assert(cells.count == width * height, "one cell per pixel")
			self.width = width
			self.height = height
			self.cells = cells
		}

		/// Ink where `gray` is darker than `threshold`.
		init(_ gray: Gray, darkerThan threshold: Int) {
			self.init(width: gray.width, height: gray.height, cells: gray.pixels.map { Int($0) < threshold })
		}

		/// Sauvola's threshold over a square window of `radius`, read off integral images: ink where
		/// a pixel is at or below `mean · (1 + k · (deviation / 128 − 1))`, and at or below `ceiling`
		/// (clearly darker than the paper, so speckle on blank paper stays paper).
		init(sauvola gray: Gray, radius: Int, ceiling: Int) {
			let w = gray.width, h = gray.height, stride = gray.width + 1
			var sums = [Int](repeating: 0, count: stride * (h + 1))
			var squares = [Int](repeating: 0, count: stride * (h + 1))
			for y in 0..<h {
				var rowSum = 0, rowSquares = 0
				for x in 0..<w {
					let value = Int(gray.pixels[y * w + x])
					rowSum += value
					rowSquares += value * value
					sums[(y + 1) * stride + x + 1] = sums[y * stride + x + 1] + rowSum
					squares[(y + 1) * stride + x + 1] = squares[y * stride + x + 1] + rowSquares
				}
			}
			var cells = [Bool](repeating: false, count: w * h)
			for y in 0..<h {
				let y0 = max(0, y - radius), y1 = min(h, y + radius + 1)
				for x in 0..<w where Int(gray.pixels[y * w + x]) <= ceiling {
					let x0 = max(0, x - radius), x1 = min(w, x + radius + 1)
					let count = Double((y1 - y0) * (x1 - x0))
					let sum = Double(sums[y1 * stride + x1] - sums[y0 * stride + x1] - sums[y1 * stride + x0] + sums[y0 * stride + x0])
					let square = Double(squares[y1 * stride + x1] - squares[y0 * stride + x1] - squares[y1 * stride + x0] + squares[y0 * stride + x0])
					let mean = sum / count
					let deviation = max(0, square / count - mean * mean).squareRoot()
					let threshold = mean * (1 + Tuning.sauvolaK * (deviation / Tuning.sauvolaRange - 1))
					cells[y * w + x] = Double(gray.pixels[y * w + x]) <= threshold
				}
			}
			self.init(width: w, height: h, cells: cells)
		}

		/// Ink at (x, y); paper outside the mask.
		subscript(x: Int, y: Int) -> Bool {
			guard x >= 0, y >= 0, x < width, y < height else { return false }
			return cells[y * width + x]
		}

		/// Each row's horizontal runs of ink, left to right.
		func rowRuns() -> [[Range<Int>]] {
			let cells = self.cells
			var result: [[Range<Int>]] = []
			result.reserveCapacity(height)
			for y in 0..<height {
				let offset = y * width
				var row: [Range<Int>] = []
				var start = -1
				for x in 0..<width {
					if cells[offset + x] {
						start = start < 0 ? x : start
					} else if start >= 0 {
						row.append(start..<x)
						start = -1
					}
				}
				if start >= 0 {
					row.append(start..<width)
				}
				result.append(row)
			}
			return result
		}

		/// This mask without those of its horizontal `runs` (from `rowRuns`) that are `length` or
		/// longer: a horizontal opening's result taken away.
		func removing(_ runs: [[Range<Int>]], atLeast length: Int) -> Ink {
			guard length > 0, runs.contains(where: { row in row.contains { $0.count >= length } }) else { return self }
			var cells = self.cells
			for (y, row) in runs.enumerated() where y < height {
				for run in row where run.count >= length {
					for x in run {
						cells[y * width + x] = false
					}
				}
			}
			return Ink(width: width, height: height, cells: cells)
		}

		/// The longest vertical run of ink in `column` that passes through `rows`.
		func verticalRun(column: Int, through rows: Range<Int>) -> Int {
			guard column >= 0, column < width else { return 0 }
			var longest = 0
			var start: Int?
			for y in 0...height {
				let inked = y < height && cells[y * width + column]
				if inked, start == nil {
					start = y
				} else if !inked, let first = start {
					if first < rows.upperBound, y > rows.lowerBound {
						longest = max(longest, y - first)
					}
					start = nil
				}
			}
			return longest
		}
	}
}
