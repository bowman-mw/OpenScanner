//
//  FigureDetector.swift
//  Folio (fork of Open Scanner)
//
//  Finds the pictures on a cleaned page — photos, charts, shaded
//  illustrations — with no model, after Leptonica's halftone mask
//  (`pixGenerateHalftoneMask`, pageseg.c), simplified:
//
//  1. Pixels: the page at working size, about a quarter of the stored page.
//     The paper is the page's bright end (each channel's 90th percentile); a
//     pixel is ink when it is clearly off the paper, and mid-tone when it is
//     a little off it without being near black.
//  2. Cells: a grid about 100 cells on the long side. A cell looks like a
//     picture when most of it is ink (a photo, a solid chart bar) or most of
//     it is mid-tone with some texture (a light photo).
//  3. Text: cells under OCR lines printed on the paper (inflated a little),
//     and under the page's tables, diagrams and equations, are cleared. A line
//     printed over a picture (a sign in a photo, a label on a bar) has little
//     paper behind it and stays part of the picture.
//  4. Regions: the cells closed by one cell and split into connected regions;
//     neighbours that face each other across a few cells of nothing but paper
//     (a chart's bars) are joined, unless the box joining them would take in
//     text that neither had (a column of text beside the shorter picture).
//  5. Doubt: a region becomes a figure only when it is at least 2% of the
//     page, made of solid areas rather than lines, not mostly text, not one
//     flat colour or one smooth shading (a gradient panel, uneven light on a
//     grey box), and not a border or shadow hugging the page edge; a page
//     with more than eight is left alone. A junk picture in a document is
//     worse than a missing one, so every test leans toward a miss.
//
//  Line art with few dark pixels (line charts, pen sketches) is not found yet.
//  Foundation, CoreGraphics and ImageIO only; every step is a pure function of
//  its inputs, so it runs on a background task and in unit tests.
//

import CoreGraphics
import Foundation
import ImageIO

/// One picture the detector found on a page.
struct DetectedFigure: Hashable, Sendable {
	/// Where the picture sits (page-normalized, top-left origin).
	var box: NormalizedBox
	/// The share of the region's box made of picture-like cells, 0–1.
	var confidence: Double
}

/// Finds photos, charts and other pictures on a cleaned page (see the file
/// header). Stateless; safe to call from any thread.
enum FigureDetector {
	/// Detects on stored page data (the cleaned JPEG), decoded straight to working size. `excluding`
	/// holds the boxes of the page's tables, diagrams and equations, which are never figures.
	static func detect(_ data: Data, lines: [RecognizedLine], excluding: [NormalizedBox]) -> [DetectedFigure] {
		guard !data.isEmpty, let image = workingImage(data) else { return [] }
		return detect(in: image, lines: lines, excluding: excluding)
	}

	/// Detects on a page image whose pixels line up with the lines' boxes, in reading order. Empty
	/// when the page has no picture the detector is sure of, and on dark pages, whose paper can't be
	/// told from a picture.
	static func detect(in image: CGImage, lines: [RecognizedLine], excluding: [NormalizedBox]) -> [DetectedFigure] {
		guard image.width >= Tuning.minImageSide, image.height >= Tuning.minImageSide,
			  let raster = DiagramDetector.Raster(image: image, maxSide: Tuning.workingMaxSide) else { return [] }
		let paper = paperColor(of: raster)
		guard paper.luma >= Tuning.minPaperLuma else { return [] }
		let page = PageCells(raster: raster, paper: paper)
		let text = textMasks(lines, page: page)
		let excluded = text.onPaper.union(page.mask(covering: excluding.map(\.rect), inflatedBy: Tuning.blockInflation))
		let candidates = page.candidates.subtracting(excluded)
		let closed = candidates.closed(radius: Tuning.closeRadius).subtracting(excluded)
		guard let found = closed.regions(minCells: Tuning.minRegionCells, limit: Tuning.maxRegions) else { return [] }
		// A region on two page edges is a border or shadow, and joining would only grow it over
		// whatever it met.
		let inside = found.filter { page.edges(touchedBy: $0).count < 2 }
		let context = RegionContext(page: page, candidates: candidates, closed: closed,
									solid: closed.opened(radius: Tuning.openRadius),
									text: text.all, textHalo: text.all.dilated(radius: 1))
		let figures = joiningNeighbours(inside, excluded: excluded).compactMap { figure(for: $0, in: context) }
		guard figures.count <= Tuning.maxFigures else { return [] }
		return figures.sorted { ($0.box.y, $0.box.x) < ($1.box.y, $1.box.x) }
	}

	/// The boxes a new figure must never cover: the page's tables, diagrams, equations and figures.
	static func exclusions(in blocks: [FolioBlock]) -> [NormalizedBox] {
		blocks.compactMap { block -> NormalizedBox? in
			switch block.content {
			case .table, .diagram, .equation, .figure: return block.box
			case .heading, .paragraph, .list: return nil
			}
		}
	}

	/// Decodes stored image data at working size without loading it full size. No EXIF rotation,
	/// so pixels line up with the boxes Vision read off the same unrotated image.
	static func workingImage(_ data: Data) -> CGImage? {
		guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
		let options: [CFString: Any] = [
			kCGImageSourceCreateThumbnailFromImageAlways: true,
			kCGImageSourceThumbnailMaxPixelSize: Tuning.workingMaxSide,
			kCGImageSourceCreateThumbnailWithTransform: false,
			kCGImageSourceShouldCacheImmediately: true,
		]
		return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
	}
}

// MARK: - Tuning

extension FigureDetector {
	/// Every named bound and threshold. Shares are of the page; pixel values are in the working
	/// raster (the page scaled so its longer side is at most `workingMaxSide`).
	enum Tuning {
		// Bounds: every loop and every kept collection is capped by one of these.
		static let workingMaxSide = 800
		static let minImageSide = 64
		static let cellsOnLongSide = 100.0
		static let minCellPixels = 4
		static let maxPaperSamples = 65_536
		static let maxLines = 2_000
		static let maxLineSamples = 1_024
		static let maxRegions = 64
		static let maxFigures = 8

		// Paper and pixels. Distances are the largest channel difference from the paper, 0–255.
		static let paperPercentile = 0.9
		static let minPaperLuma = 150.0
		static let inkDistance = 40
		static let midToneDistance = 16
		static let nearBlackLuma: UInt8 = 48

		// Cells.
		static let heavyInkShare = 0.5
		static let midToneShare = 0.5
		static let minTextureDeviation = 6.0

		// Text and blocks. Text boxes grow by these shares of their line height.
		static let onPaperShare = 0.45
		static let textInflationX = 0.3
		static let textInflationY = 0.2
		static let blockInflation = 0.01

		// Regions.
		static let closeRadius = 1
		static let openRadius = 1
		static let minRegionCells = 6
		static let maxJoinGap = 5
		static let minFacingShare = 0.3

		// Acceptance.
		static let minAreaShare = 0.02
		static let maxAreaShare = 0.85
		static let minWidthShare = 0.08
		static let minHeightShare = 0.05
		static let maxAspect = 6.0
		static let minFill = 0.3
		static let minSolidity = 0.5
		static let maxTextShare = 0.3
		static let minColourSpread = 12.0
		/// Luma spread left once a plane is fitted to it: a photo or chart keeps far more.
		static let minSurfaceSpread = 6.0
		static let minSpreadSamples = 32
		/// A region touching one page edge must reach at least this far in from it …
		static let minEdgeDepth = 0.15
		/// … and run along at most this much of it.
		static let maxEdgeLength = 0.8
	}
}

// MARK: - Paper

extension FigureDetector {
	/// The page's paper colour, 0–255 per channel.
	struct PaperColor: Equatable {
		var red: Int
		var green: Int
		var blue: Int

		var luma: Double { 0.2126 * Double(red) + 0.7152 * Double(green) + 0.0722 * Double(blue) }

		/// How far pixel `index` of `rgba` is from the paper: its largest channel difference, 0–255.
		func distance(_ rgba: [UInt8], at index: Int) -> Int {
			let base = index * 4
			guard base >= 0, base + 2 < rgba.count else { return 0 }
			return max(abs(Int(rgba[base]) - red), abs(Int(rgba[base + 1]) - green), abs(Int(rgba[base + 2]) - blue))
		}
	}

	/// Each channel's `paperPercentile` over an even sample of the page: the paper on any page that
	/// shows some, however much of it is covered.
	static func paperColor(of raster: DiagramDetector.Raster) -> PaperColor {
		let pixelCount = raster.width * raster.height
		var histograms = [[Int]](repeating: [Int](repeating: 0, count: 256), count: 3)
		let step = max(1, pixelCount / Tuning.maxPaperSamples)
		var samples = 0
		for index in stride(from: 0, to: pixelCount, by: step) {
			for channel in 0..<3 {
				histograms[channel][Int(raster.rgba[index * 4 + channel])] += 1
			}
			samples += 1
		}
		let levels = histograms.map { percentile($0, share: Tuning.paperPercentile, of: samples) }
		return PaperColor(red: levels[0], green: levels[1], blue: levels[2])
	}

	/// The level at which `share` of a histogram's `total` samples are at or below it.
	static func percentile(_ histogram: [Int], share: Double, of total: Int) -> Int {
		assert(!histogram.isEmpty, "a histogram has levels")
		let target = Double(total) * share
		var running = 0
		for (level, count) in histogram.enumerated() {
			running += count
			if Double(running) >= target { return level }
		}
		return histogram.count - 1
	}
}

// MARK: - Cells

extension FigureDetector {
	/// What one grid cell holds.
	struct CellStats {
		var pixels = 0
		var ink = 0
		var midTone = 0
		var lumaSum = 0.0
		var lumaSquares = 0.0

		mutating func add(luma: UInt8, distance: Int) {
			pixels += 1
			if distance >= Tuning.inkDistance { ink += 1 }
			if distance >= Tuning.midToneDistance, luma >= Tuning.nearBlackLuma { midTone += 1 }
			let value = Double(luma)
			lumaSum += value
			lumaSquares += value * value
		}

		/// Mostly ink (a photo, a solid bar), or mostly mid-tone with some texture (a light photo).
		var looksLikePicture: Bool {
			guard pixels > 0 else { return false }
			let count = Double(pixels)
			if Double(ink) / count >= Tuning.heavyInkShare { return true }
			let mean = lumaSum / count
			let deviation = max(0, lumaSquares / count - mean * mean).squareRoot()
			return Double(midTone) / count >= Tuning.midToneShare && deviation >= Tuning.minTextureDeviation
		}
	}

	/// The working raster cut into square cells, with the cells that look like a picture.
	struct PageCells {
		let raster: DiagramDetector.Raster
		let paper: PaperColor
		let cellSize: Int
		let columns: Int
		let rows: Int
		let candidates: CellMask

		init(raster: DiagramDetector.Raster, paper: PaperColor) {
			self.raster = raster
			self.paper = paper
			let size = max(Tuning.minCellPixels, Int((Double(max(raster.width, raster.height)) / Tuning.cellsOnLongSide).rounded()))
			cellSize = size
			columns = (raster.width + size - 1) / size
			rows = (raster.height + size - 1) / size
			var stats = [CellStats](repeating: CellStats(), count: columns * rows)
			for y in 0..<raster.height {
				let rowBase = (y / size) * columns
				for x in 0..<raster.width {
					let index = y * raster.width + x
					stats[rowBase + x / size].add(luma: raster.luma[index], distance: paper.distance(raster.rgba, at: index))
				}
			}
			candidates = CellMask(columns: columns, rows: rows, bits: stats.map(\.looksLikePicture))
		}

		var emptyMask: CellMask { CellMask(columns: columns, rows: rows) }

		/// A cell's pixels, clipped to the raster.
		func pixelRect(column: Int, row: Int) -> CGRect {
			let minX = column * cellSize, minY = row * cellSize
			return CGRect(x: minX, y: minY, width: min(cellSize, raster.width - minX), height: min(cellSize, raster.height - minY))
		}

		/// A cell rectangle's pixels, clipped to the raster.
		func pixelRect(_ rect: CellRect) -> CGRect {
			pixelRect(column: rect.minColumn, row: rect.minRow).union(pixelRect(column: rect.maxColumn, row: rect.maxRow))
		}

		/// A cell rectangle as a page box.
		func normalizedBox(_ rect: CellRect) -> NormalizedBox {
			let pixels = pixelRect(rect)
			let width = Double(raster.width), height = Double(raster.height)
			return NormalizedBox(x: pixels.minX / width, y: pixels.minY / height,
								 width: pixels.width / width, height: pixels.height / height)
		}

		/// The page edges a cell rectangle reaches.
		func edges(touchedBy rect: CellRect) -> Set<RegionMeasures.Edge> {
			var edges: Set<RegionMeasures.Edge> = []
			if rect.minColumn <= 0 { edges.insert(.left) }
			if rect.minRow <= 0 { edges.insert(.top) }
			if rect.maxColumn >= columns - 1 { edges.insert(.right) }
			if rect.maxRow >= rows - 1 { edges.insert(.bottom) }
			return edges
		}

		/// `box` (page-normalized) in raster pixels.
		func pixelRect(normalized box: CGRect) -> CGRect {
			CGRect(x: box.minX * Double(raster.width), y: box.minY * Double(raster.height),
				   width: box.width * Double(raster.width), height: box.height * Double(raster.height))
		}

		/// The cells whose centres lie in any of `boxes` (page-normalized), each grown by `inset` of
		/// the page on every side.
		func mask(covering boxes: [CGRect], inflatedBy inset: Double = 0) -> CellMask {
			var mask = emptyMask
			for box in boxes {
				mask.include(pixelRect(normalized: box.insetBy(dx: -inset, dy: -inset)), cellSize: cellSize)
			}
			return mask
		}

		/// The share of the pixels in `box` (page-normalized) that are paper, from an even sample.
		func paperShare(in box: CGRect) -> Double {
			let pixels = pixelRect(normalized: box).intersection(CGRect(x: 0, y: 0, width: raster.width, height: raster.height))
			guard !pixels.isNull, pixels.width >= 1, pixels.height >= 1 else { return 0 }
			let step = max(1, Int((pixels.width * pixels.height / Double(Tuning.maxLineSamples)).squareRoot().rounded(.up)))
			var paperCount = 0, total = 0
			for y in stride(from: Int(pixels.minY), to: Int(pixels.maxY), by: step) {
				for x in stride(from: Int(pixels.minX), to: Int(pixels.maxX), by: step) {
					total += 1
					if paper.distance(raster.rgba, at: y * raster.width + x) < Tuning.inkDistance { paperCount += 1 }
				}
			}
			return total > 0 ? Double(paperCount) / Double(total) : 0
		}
	}
}

// MARK: - Text

extension FigureDetector {
	/// The cells under the page's OCR lines.
	struct TextMasks {
		/// Under lines printed on the paper, inflated a little: cleared before regions are found.
		var onPaper: CellMask
		/// Under every line, as read: how much of a region is text.
		var all: CellMask
	}

	static func textMasks(_ lines: [RecognizedLine], page: PageCells) -> TextMasks {
		var masks = TextMasks(onPaper: page.emptyMask, all: page.emptyMask)
		for line in lines.prefix(Tuning.maxLines) {
			let box = line.box.standardized
			guard box.width > 0, box.height > 0, box.width.isFinite, box.height.isFinite else { continue }
			masks.all.include(page.pixelRect(normalized: box), cellSize: page.cellSize)
			guard page.paperShare(in: box) >= Tuning.onPaperShare else { continue }
			// Grow by a share of the line's height in pixels.
			let lineHeight = box.height * Double(page.raster.height)
			let grown = page.pixelRect(normalized: box).insetBy(dx: -lineHeight * Tuning.textInflationX,
																dy: -lineHeight * Tuning.textInflationY)
			masks.onPaper.include(grown, cellSize: page.cellSize)
		}
		return masks
	}
}

// MARK: - Regions

extension FigureDetector {
	/// Joins regions that overlap, or face each other across at most `maxJoinGap` cells holding no
	/// text, table, diagram or equation (a chart's bars, a grid of photos). Text between two pictures
	/// keeps them apart.
	static func joiningNeighbours(_ regions: [CellRect], excluded: CellMask) -> [CellRect] {
		var result = regions
		for _ in 0..<regions.count {
			guard let pair = joinablePair(in: result, excluded: excluded) else { break }
			result[pair.first] = result[pair.first].union(result[pair.second])
			result.remove(at: pair.second)
		}
		return result
	}

	/// The first two regions that `joinable` says belong together.
	static func joinablePair(in regions: [CellRect], excluded: CellMask) -> (first: Int, second: Int)? {
		for first in regions.indices {
			for second in regions.indices where second > first && joinable(regions[first], regions[second], excluded: excluded) {
				return (first, second)
			}
		}
		return nil
	}

	/// True when `a` and `b` overlap, or sit side by side (or one above the other) at most
	/// `maxJoinGap` cells apart, facing each other along at least `minFacingShare` of the shorter
	/// one, and the box joining them takes in no excluded cell that neither box held
	/// (`addsNothingExcluded`): not the text between them, nor text beside the shorter one.
	static func joinable(_ a: CellRect, _ b: CellRect, excluded: CellMask) -> Bool {
		guard !a.intersects(b) else { return true }
		for axis in [CellRect.Axis.columns, .rows] {
			let across = axis.other
			let gapStart = min(a.upper(axis), b.upper(axis)) + 1
			let gapEnd = max(a.lower(axis), b.lower(axis)) - 1
			let gap = gapEnd - gapStart + 1
			let facingStart = max(a.lower(across), b.lower(across))
			let facingEnd = min(a.upper(across), b.upper(across))
			let shorter = min(a.length(across), b.length(across))
			guard gap >= 0, gap <= Tuning.maxJoinGap, facingEnd >= facingStart,
				  Double(facingEnd - facingStart + 1) >= Tuning.minFacingShare * Double(shorter) else { continue }
			return addsNothingExcluded(a, b, excluded: excluded)
		}
		return false
	}

	/// True when the box covering `a` and `b` holds no excluded cell (text on the paper, a table,
	/// diagram or equation) outside both of them. A photo above a wider one, with text wrapped
	/// beside it, would otherwise become one figure over that text, and FigurePlacement would take
	/// the text out of the page.
	static func addsNothingExcluded(_ a: CellRect, _ b: CellRect, excluded: CellMask) -> Bool {
		let shared = a.intersection(b).map { excluded.count(in: $0) } ?? 0
		let inParts = excluded.count(in: a) + excluded.count(in: b) - shared
		return excluded.count(in: a.union(b)) == inParts
	}

	/// The masks a region is measured against.
	struct RegionContext {
		let page: PageCells
		/// Picture-like cells, text and blocks cleared.
		let candidates: CellMask
		/// `candidates` closed, text and blocks cleared again: the regions.
		let closed: CellMask
		/// `closed` opened: lines and rules thinner than three cells are gone.
		let solid: CellMask
		/// Under every OCR line, and one cell around it.
		let text: CellMask
		let textHalo: CellMask
	}

	/// The figure a region makes, when it passes every test (see `accepts`).
	static func figure(for rect: CellRect, in context: RegionContext) -> DetectedFigure? {
		let measures = measure(rect, in: context)
		guard accepts(measures) else { return nil }
		return DetectedFigure(box: context.page.normalizedBox(rect), confidence: min(1, measures.fill))
	}

	static func measure(_ rect: CellRect, in context: RegionContext) -> RegionMeasures {
		let page = context.page
		let cells = Double(max(1, rect.area))
		let pixels = page.pixelRect(rect)
		return RegionMeasures(
			widthShare: pixels.width / Double(page.raster.width),
			heightShare: pixels.height / Double(page.raster.height),
			aspect: pixels.height > 0 ? pixels.width / pixels.height : 0,
			fill: Double(context.candidates.count(in: rect)) / cells,
			solidity: Double(context.solid.count(in: rect)) / Double(max(1, context.closed.count(in: rect))),
			textShare: Double(context.text.count(in: rect)) / cells,
			colourSpread: colourSpread(in: rect, page: page, skipping: context.textHalo),
			edges: page.edges(touchedBy: rect),
			surfaceSpread: surfaceSpread(in: rect, page: page, skipping: context.textHalo))
	}

	/// The cells `colourSpread` and `surfaceSpread` sample: the region without its outer ring of
	/// cells (which mixes in the paper) when it is at least three cells each way.
	static func innerCells(_ rect: CellRect) -> CellRect {
		guard rect.length(.columns) >= 3, rect.length(.rows) >= 3 else { return rect }
		return CellRect(minColumn: rect.minColumn + 1, minRow: rect.minRow + 1, maxColumn: rect.maxColumn - 1, maxRow: rect.maxRow - 1)
	}

	/// The standard deviation of luma (0–255) left over the region's pixels away from text once the
	/// best-fitting plane is taken out: about 0 for a flat or evenly shaded panel, whose colours
	/// spread only because they run from light to dark; large for a photo or a chart. 0 when too few
	/// pixels are left to tell.
	static func surfaceSpread(in rect: CellRect, page: PageCells, skipping text: CellMask) -> Double {
		let inner = innerCells(rect)
		// Sums of x, y, luma and their products, for a least-squares plane.
		var sums = PlaneSums()
		for row in inner.minRow...inner.maxRow {
			for column in inner.minColumn...inner.maxColumn where !text[column, row] {
				let cell = page.pixelRect(column: column, row: row)
				for y in stride(from: Int(cell.minY), to: Int(cell.maxY), by: 2) {
					for x in stride(from: Int(cell.minX), to: Int(cell.maxX), by: 2) {
						sums.add(x: Double(x), y: Double(y), value: Double(page.raster.luma[y * page.raster.width + x]))
					}
				}
			}
		}
		guard sums.count >= Double(Tuning.minSpreadSamples) else { return 0 }
		return sums.residualDeviation
	}

	/// Running sums for fitting value ≈ a + b·x + c·y by least squares.
	struct PlaneSums {
		var count = 0.0
		var x = 0.0, y = 0.0, value = 0.0
		var xx = 0.0, yy = 0.0, xy = 0.0, xValue = 0.0, yValue = 0.0, valueValue = 0.0

		mutating func add(x px: Double, y py: Double, value v: Double) {
			count += 1
			x += px
			y += py
			value += v
			xx += px * px
			yy += py * py
			xy += px * py
			xValue += px * v
			yValue += py * v
			valueValue += v * v
		}

		/// The standard deviation of the values about the fitted plane (about their mean when the
		/// points lie on a line, which fixes no plane).
		var residualDeviation: Double {
			guard count > 0 else { return 0 }
			let mx = x / count, my = y / count, mv = value / count
			let cxx = xx / count - mx * mx, cyy = yy / count - my * my, cxy = xy / count - mx * my
			let cxv = xValue / count - mx * mv, cyv = yValue / count - my * mv
			let variance = max(0, valueValue / count - mv * mv)
			let determinant = cxx * cyy - cxy * cxy
			guard determinant > 1e-9 else { return variance.squareRoot() }
			let b = (cxv * cyy - cyv * cxy) / determinant
			let c = (cyv * cxx - cxv * cxy) / determinant
			return max(0, variance - b * cxv - c * cyv).squareRoot()
		}
	}

	/// The standard deviation of colour (√ of the summed channel variances, 0–255) over the
	/// region's pixels away from text and its outer ring of cells (which mixes in the paper); 0 when
	/// too few are left to tell.
	static func colourSpread(in rect: CellRect, page: PageCells, skipping text: CellMask) -> Double {
		let inner = innerCells(rect)
		var sums = [Double](repeating: 0, count: 3), squares = [Double](repeating: 0, count: 3)
		var samples = 0
		for row in inner.minRow...inner.maxRow {
			for column in inner.minColumn...inner.maxColumn where !text[column, row] {
				let cell = page.pixelRect(column: column, row: row)
				for y in stride(from: Int(cell.minY), to: Int(cell.maxY), by: 2) {
					for x in stride(from: Int(cell.minX), to: Int(cell.maxX), by: 2) {
						let base = (y * page.raster.width + x) * 4
						for channel in 0..<3 {
							let value = Double(page.raster.rgba[base + channel])
							sums[channel] += value
							squares[channel] += value * value
						}
						samples += 1
					}
				}
			}
		}
		guard samples >= Tuning.minSpreadSamples else { return 0 }
		let count = Double(samples)
		let variance = (0..<3).reduce(0.0) { total, channel in
			let mean = sums[channel] / count
			return total + max(0, squares[channel] / count - mean * mean)
		}
		return variance.squareRoot()
	}
}

// MARK: - Acceptance

extension FigureDetector {
	/// What a region is judged on.
	struct RegionMeasures: Equatable {
		enum Edge: Hashable {
			case left, top, right, bottom
		}

		/// The region's box as shares of the page's width and height.
		var widthShare: Double
		var heightShare: Double
		/// The box's width / height in pixels.
		var aspect: Double
		/// Picture-like cells / cells in the box.
		var fill: Double
		/// Region cells left after an opening / region cells: low for rules, lines and frames.
		var solidity: Double
		/// Cells under OCR lines / cells in the box.
		var textShare: Double
		/// Colour spread away from text (see `colourSpread`): low for one flat colour.
		var colourSpread: Double
		/// Page edges the box touches.
		var edges: Set<Edge>
		/// Luma spread left once a plane is fitted (see `surfaceSpread`): low for smooth shading.
		var surfaceSpread: Double
	}

	/// True for a region that reads as a picture: big enough but not the whole page, not a thin
	/// strip, mostly picture-like solid areas, not mostly text, not one flat colour or one smooth
	/// shading, and not hugging the page edge.
	static func accepts(_ measures: RegionMeasures) -> Bool {
		let area = measures.widthShare * measures.heightShare
		guard area >= Tuning.minAreaShare, area <= Tuning.maxAreaShare,
			  measures.widthShare >= Tuning.minWidthShare, measures.heightShare >= Tuning.minHeightShare,
			  measures.aspect >= 1 / Tuning.maxAspect, measures.aspect <= Tuning.maxAspect else { return false }
		guard measures.fill >= Tuning.minFill, measures.solidity >= Tuning.minSolidity,
			  measures.textShare <= Tuning.maxTextShare, measures.colourSpread >= Tuning.minColourSpread,
			  measures.surfaceSpread >= Tuning.minSurfaceSpread else { return false }
		return !hugsEdge(measures)
	}

	/// True for a dark border, shadow or table edge left along the page: a region touching two or
	/// more edges, or one edge that it barely reaches in from or runs along most of.
	static func hugsEdge(_ measures: RegionMeasures) -> Bool {
		guard !measures.edges.isEmpty else { return false }
		guard measures.edges.count == 1 else { return true }
		let onSide = measures.edges.contains(.left) || measures.edges.contains(.right)
		let depth = onSide ? measures.widthShare : measures.heightShare
		let length = onSide ? measures.heightShare : measures.widthShare
		return depth < Tuning.minEdgeDepth || length > Tuning.maxEdgeLength
	}
}

// MARK: - Cell masks

extension FigureDetector {
	/// An inclusive rectangle of grid cells.
	struct CellRect: Equatable {
		enum Axis {
			case columns, rows

			var other: Axis { self == .columns ? .rows : .columns }
		}

		var minColumn: Int
		var minRow: Int
		var maxColumn: Int
		var maxRow: Int

		init(minColumn: Int, minRow: Int, maxColumn: Int, maxRow: Int) {
			self.minColumn = min(minColumn, maxColumn)
			self.minRow = min(minRow, maxRow)
			self.maxColumn = max(minColumn, maxColumn)
			self.maxRow = max(minRow, maxRow)
		}

		/// `from…to` along `axis`, `across…to` along the other.
		init(axis: Axis, from start: Int, to end: Int, across acrossStart: Int, to acrossEnd: Int) {
			if axis == .columns {
				self.init(minColumn: start, minRow: acrossStart, maxColumn: end, maxRow: acrossEnd)
			} else {
				self.init(minColumn: acrossStart, minRow: start, maxColumn: acrossEnd, maxRow: end)
			}
		}

		var area: Int { length(.columns) * length(.rows) }

		func lower(_ axis: Axis) -> Int { axis == .columns ? minColumn : minRow }
		func upper(_ axis: Axis) -> Int { axis == .columns ? maxColumn : maxRow }
		func length(_ axis: Axis) -> Int { upper(axis) - lower(axis) + 1 }

		func intersects(_ other: CellRect) -> Bool {
			minColumn <= other.maxColumn && other.minColumn <= maxColumn && minRow <= other.maxRow && other.minRow <= maxRow
		}

		func union(_ other: CellRect) -> CellRect {
			CellRect(minColumn: min(minColumn, other.minColumn), minRow: min(minRow, other.minRow),
					 maxColumn: max(maxColumn, other.maxColumn), maxRow: max(maxRow, other.maxRow))
		}

		/// The cells both hold; nil when they don't meet.
		func intersection(_ other: CellRect) -> CellRect? {
			guard intersects(other) else { return nil }
			return CellRect(minColumn: max(minColumn, other.minColumn), minRow: max(minRow, other.minRow),
							maxColumn: min(maxColumn, other.maxColumn), maxRow: min(maxRow, other.maxRow))
		}
	}

	/// One yes/no per grid cell, row by row.
	struct CellMask: Equatable {
		let columns: Int
		let rows: Int
		var bits: [Bool]

		/// Neighbours of a cell, all eight.
		static let neighbours = [(-1, -1), (0, -1), (1, -1), (-1, 0), (1, 0), (-1, 1), (0, 1), (1, 1)]

		init(columns: Int, rows: Int, bits: [Bool] = []) {
			self.columns = max(0, columns)
			self.rows = max(0, rows)
			let count = self.columns * self.rows
			self.bits = bits.count == count ? bits : [Bool](repeating: false, count: count)
		}

		/// False off the grid.
		subscript(column: Int, row: Int) -> Bool {
			guard column >= 0, row >= 0, column < columns, row < rows else { return false }
			return bits[row * columns + column]
		}

		var count: Int { bits.reduce(0) { $0 + ($1 ? 1 : 0) } }

		/// Set cells inside `rect` (clipped to the grid).
		func count(in rect: CellRect) -> Int {
			let firstRow = max(0, rect.minRow), lastRow = min(rows - 1, rect.maxRow)
			let firstColumn = max(0, rect.minColumn), lastColumn = min(columns - 1, rect.maxColumn)
			guard firstRow <= lastRow, firstColumn <= lastColumn else { return 0 }
			var total = 0
			for row in firstRow...lastRow {
				for column in firstColumn...lastColumn where bits[row * columns + column] {
					total += 1
				}
			}
			return total
		}

		func union(_ other: CellMask) -> CellMask {
			assert(other.bits.count == bits.count, "masks of one grid")
			return CellMask(columns: columns, rows: rows, bits: zip(bits, other.bits).map { $0 || $1 })
		}

		mutating func formUnion(_ other: CellMask) {
			self = union(other)
		}

		func subtracting(_ other: CellMask) -> CellMask {
			assert(other.bits.count == bits.count, "masks of one grid")
			return CellMask(columns: columns, rows: rows, bits: zip(bits, other.bits).map { $0 && !$1 })
		}

		/// Sets the cells whose centres lie in `pixels` (cells `cellSize` pixels square).
		mutating func include(_ pixels: CGRect, cellSize: Int) {
			guard cellSize > 0, !pixels.isNull, pixels.width > 0, pixels.height > 0,
				  pixels.minX.isFinite, pixels.minY.isFinite, pixels.maxX.isFinite, pixels.maxY.isFinite else { return }
			let size = Double(cellSize)
			let firstColumn = max(0, Int((pixels.minX / size).rounded(.down)))
			let lastColumn = min(columns - 1, Int((pixels.maxX / size).rounded(.down)))
			let firstRow = max(0, Int((pixels.minY / size).rounded(.down)))
			let lastRow = min(rows - 1, Int((pixels.maxY / size).rounded(.down)))
			guard firstColumn <= lastColumn, firstRow <= lastRow else { return }
			for row in firstRow...lastRow {
				for column in firstColumn...lastColumn where pixels.contains(CGPoint(x: (Double(column) + 0.5) * size, y: (Double(row) + 0.5) * size)) {
					bits[row * columns + column] = true
				}
			}
		}

		/// Dilated, then eroded: gaps up to `2 × radius` cells close.
		func closed(radius: Int) -> CellMask { dilated(radius: radius).eroded(radius: radius) }

		/// Eroded, then dilated: anything thinner than `2 × radius + 1` cells goes.
		func opened(radius: Int) -> CellMask { eroded(radius: radius).dilated(radius: radius) }

		/// Each cell set when any cell within `radius` (a square) is; off the grid counts as unset.
		func dilated(radius: Int) -> CellMask { spread(radius: radius, any: true) }

		/// Each cell set only when every cell within `radius` is; off the grid counts as set, so a
		/// region running off the page keeps its edge.
		func eroded(radius: Int) -> CellMask { spread(radius: radius, any: false) }

		private func spread(radius: Int, any: Bool) -> CellMask {
			guard radius > 0 else { return self }
			return pass(radius: radius, any: any, alongRows: true).pass(radius: radius, any: any, alongRows: false)
		}

		/// One separable pass of `spread`.
		private func pass(radius: Int, any: Bool, alongRows: Bool) -> CellMask {
			var result = self
			for row in 0..<rows {
				for column in 0..<columns {
					var value = !any
					for offset in -radius...radius {
						let c = alongRows ? column + offset : column
						let r = alongRows ? row : row + offset
						let inside = c >= 0 && r >= 0 && c < columns && r < rows
						let bit = inside ? bits[r * columns + c] : !any
						if bit == any {
							value = any
							break
						}
					}
					result.bits[row * columns + column] = value
				}
			}
			return result
		}

		/// The boxes of the connected regions (8-neighbour) of at least `minCells` cells, or nil when
		/// there are more than `limit` (a noisy page, left alone).
		func regions(minCells: Int, limit: Int) -> [CellRect]? {
			var seen = [Bool](repeating: false, count: bits.count)
			var result: [CellRect] = []
			for start in bits.indices where bits[start] && !seen[start] {
				let region = flood(from: start, seen: &seen)
				guard region.cells >= minCells else { continue }
				result.append(region.rect)
				guard result.count <= limit else { return nil }
			}
			return result
		}

		/// The region holding `start`, marked in `seen`.
		private func flood(from start: Int, seen: inout [Bool]) -> (rect: CellRect, cells: Int) {
			assert(columns > 0 && bits.indices.contains(start), "a cell of this grid")
			var queue = [start]
			seen[start] = true
			var rect = CellRect(minColumn: start % columns, minRow: start / columns, maxColumn: start % columns, maxRow: start / columns)
			// Each cell joins the queue at most once, so the walk ends within `bits.count` steps.
			for head in 0..<bits.count {
				guard head < queue.count else { break }
				let column = queue[head] % columns, row = queue[head] / columns
				rect = rect.union(CellRect(minColumn: column, minRow: row, maxColumn: column, maxRow: row))
				for (dc, dr) in Self.neighbours where self[column + dc, row + dr] {
					let index = (row + dr) * columns + column + dc
					guard !seen[index] else { continue }
					seen[index] = true
					queue.append(index)
				}
			}
			return (rect, queue.count)
		}
	}
}

extension NormalizedBox {
	/// The box as a `CGRect` (top-left origin, normalized).
	var rect: CGRect {
		CGRect(x: x, y: y, width: width, height: height)
	}
}
