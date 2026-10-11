//
//  PageColorSampler.swift
//  Folio (fork of Open Scanner)
//
//  Samples each page's colours into the rebuilt document, after OSS Document
//  Scanner's k-means palette (rewritten in Swift, no OpenCV):
//
//  1. Clusters: the cleaned page is decoded at working size, point-sampled on
//     a grid about 128 px on the long side and clustered with k-means (K = 8)
//     in CIELAB. The starting centres are the most populated colour bins that
//     are mutually distinct, so the same page always gives the same colours.
//     Clusters under 0.1% of the page are dropped and near-duplicates (within
//     ΔE 12) merged.
//  2. Background: the cluster that owns most of a band around the page edge.
//     Near-white paper is written as plain white.
//  3. Palette: up to five other clusters with clear chroma (not white, grey or
//     black), most coverage first, plus clearly coloured text ink. The soft
//     edge pixels between a colour and the background don't count as colours.
//  4. Text colour, conservatively (a miss beats a wrong colour): two clusters
//     inside each text block's box, the one farther from the background being
//     the ink. A block's runs are coloured only when that ink is a uniform
//     minority on the page's own background with no second ink beside it,
//     clearly coloured, and legible both on white (Word) and on the page
//     background (PowerPoint). Runs on
//     whiteboard and handwritten pages are never coloured: that ink is the
//     marker or the pen, and marker colours belong to diagrams.
//
//  Foundation, CoreGraphics and ImageIO only; every step is a pure function of
//  its inputs, so it runs on a background task.
//

import CoreGraphics
import Foundation
import ImageIO

/// What the sampler found on one page.
struct PageColors: Hashable, Sendable {
	/// Paper or slide colour; nil when no colour clearly owns the page edge.
	var background: RGBColor?
	/// Up to five accent colours, most coverage first; empty on black-on-white pages.
	var palette: [RGBColor]
	/// Ink colour of each text block printed clearly in colour, by block ID.
	var inks: [UUID: RGBColor]
}

/// Samples a cleaned page's background, palette and coloured text (see the
/// file header). Stateless; safe to call from any thread.
enum PageColorSampler {
	/// Samples stored page data (the cleaned JPEG), decoded straight to working size.
	static func sample(_ data: Data, blocks: [FolioBlock], source: PageSource) -> PageColors? {
		guard !data.isEmpty, let image = workingImage(data) else { return nil }
		return sample(image, blocks: blocks, source: source)
	}

	/// Samples a page image whose pixels line up with the blocks' boxes.
	static func sample(_ image: CGImage, blocks: [FolioBlock], source: PageSource) -> PageColors? {
		guard let pixels = Pixels(image: image, maxSide: Tuning.workingMaxSide) else { return nil }
		let grid = pixels.grid(longSide: Tuning.gridLongSide, borderFraction: Tuning.borderFraction)
		guard !grid.colors.isEmpty else { return nil }
		let clusters = pageClusters(grid)
		guard let backgroundIndex = backgroundCluster(of: clusters, grid: grid),
			  let backgroundLab = clusters[safe: backgroundIndex]?.lab else {
			return PageColors(background: nil, palette: palette(from: clusters, background: nil, inks: []), inks: [:])
		}
		let background = rendered(background: backgroundLab)
		// Pen and marker colour isn't styling, so only typed pages are read for text ink.
		let readings = source == .typed ? textInks(blocks, pixels: pixels, background: backgroundLab) : []
		var others = clusters
		others.remove(at: backgroundIndex)
		let accents = palette(from: others, background: backgroundLab, inks: readings.map(\.ink))
		var inks: [UUID: RGBColor] = [:]
		for reading in readings where colorsRuns(reading.ink.lab, background: background) {
			inks[reading.block] = reading.ink.lab.rgb
		}
		return PageColors(background: background, palette: accents, inks: inks)
	}

	/// The page with its sampled colours: background, palette and the ink
	/// colour on every run of a coloured block (runs already coloured keep theirs).
	static func applying(_ colors: PageColors, to page: FolioPage) -> FolioPage {
		var result = page
		result.background = colors.background
		result.palette = colors.palette
		for index in result.blocks.indices {
			guard let ink = colors.inks[result.blocks[index].id] else { continue }
			result.blocks[index].content.mapRuns { runs in
				runs.map { run in
					var run = run
					run.color = run.color ?? ink
					return run
				}
			}
		}
		return result
	}

	/// Decodes stored image data at working size without loading it full size.
	/// No EXIF rotation, so pixels line up with the boxes Vision read off the
	/// same unrotated image.
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

	// MARK: Page clusters

	/// k-means over the grid from deterministic starting centres; small
	/// clusters dropped, near-duplicates merged. Weights are fractions of the page.
	static func pageClusters(_ grid: Grid) -> [WeightedColor] {
		guard !grid.colors.isEmpty else { return [] }
		let start = initialCentres(for: grid, count: Tuning.clusterCount)
		let result = kMeans(grid.colors, seeds: start, iterations: Tuning.pageIterations)
		let total = Double(grid.colors.count)
		let kept = zip(result.centres, result.counts).compactMap { centre, count -> WeightedColor? in
			let weight = Double(count) / total
			return weight >= Tuning.minClusterShare ? WeightedColor(lab: centre, weight: weight) : nil
		}
		return merged(kept, within: Tuning.mergeDistance)
	}

	/// The most populated colour bins (4 bits per channel) whose mean colours
	/// are at least `seedSeparation` apart: a deterministic stand-in for
	/// k-means++ seeding that gives a small accent its own cluster as readily
	/// as the paper.
	static func initialCentres(for grid: Grid, count: Int) -> [LabColor] {
		guard count > 0, grid.colors.count == grid.bins.count else { return [] }
		var population = [Int](repeating: 0, count: Grid.binCount)
		var sums = [LabColor](repeating: .zero, count: Grid.binCount)
		for (index, bin) in grid.bins.enumerated() {
			population[bin] += 1
			sums[bin] = sums[bin] + grid.colors[index]
		}
		let order = population.indices.filter { population[$0] > 0 }.sorted { first, second in
			population[first] != population[second] ? population[first] > population[second] : first < second
		}
		var centres: [LabColor] = []
		for bin in order where centres.count < count {
			let mean = sums[bin].scaled(by: 1 / Double(population[bin]))
			if centres.allSatisfy({ $0.distance(to: mean) >= Tuning.seedSeparation }) {
				centres.append(mean)
			}
		}
		return centres
	}

	/// Lloyd's k-means from fixed starting centres, so the same samples always
	/// give the same clusters. Stops early once no sample changes cluster.
	static func kMeans(_ samples: [LabColor], seeds: [LabColor], iterations: Int) -> Clustering {
		var clustering = Clustering(centres: seeds, counts: seeds.map { _ in 0 },
									labels: [Int](repeating: -1, count: samples.count))
		guard !samples.isEmpty, !seeds.isEmpty else { return clustering }
		for _ in 0..<max(1, iterations) {
			var sums = [LabColor](repeating: .zero, count: seeds.count)
			var counts = [Int](repeating: 0, count: seeds.count)
			var changed = false
			for (index, sample) in samples.enumerated() {
				let label = nearest(sample, in: clustering.centres)
				changed = changed || label != clustering.labels[index]
				clustering.labels[index] = label
				counts[label] += 1
				sums[label] = sums[label] + sample
			}
			clustering.counts = counts
			for cluster in counts.indices where counts[cluster] > 0 {
				clustering.centres[cluster] = sums[cluster].scaled(by: 1 / Double(counts[cluster]))
			}
			if !changed { break }
		}
		return clustering
	}

	/// Index of the centre nearest `colour` (the first on a tie).
	static func nearest(_ colour: LabColor, in centres: [LabColor]) -> Int {
		guard centres.count > 1 else { return 0 }
		var best = 0
		var bestDistance = Double.infinity
		for (index, centre) in centres.enumerated() {
			let distance = colour.squaredDistance(to: centre)
			if distance < bestDistance {
				best = index
				bestDistance = distance
			}
		}
		return best
	}

	/// Merges the closest pair of clusters while any pair is nearer than
	/// `distance` (ΔE), weighting the merged colour by coverage.
	static func merged(_ clusters: [WeightedColor], within distance: Double) -> [WeightedColor] {
		var result = clusters
		for _ in 0..<clusters.count {
			guard let pair = closestPair(result), pair.distance < distance else { break }
			let first = result[pair.first], second = result[pair.second]
			let weight = first.weight + second.weight
			guard weight > 0 else { break }
			let lab = first.lab.scaled(by: first.weight / weight) + second.lab.scaled(by: second.weight / weight)
			result[pair.first] = WeightedColor(lab: lab, weight: weight)
			result.remove(at: pair.second)
		}
		return result
	}

	/// The two nearest clusters (`first` < `second`) and their ΔE.
	static func closestPair(_ clusters: [WeightedColor]) -> (first: Int, second: Int, distance: Double)? {
		guard clusters.count >= 2 else { return nil }
		var best: (first: Int, second: Int, distance: Double)?
		for first in clusters.indices {
			for second in clusters.indices where second > first {
				let distance = clusters[first].lab.distance(to: clusters[second].lab)
				if distance < (best?.distance ?? .infinity) {
					best = (first, second, distance)
				}
			}
		}
		return best
	}

	// MARK: Background and palette

	/// The cluster that owns most of the band around the page edge, when it
	/// owns enough of it to be the paper or the slide.
	static func backgroundCluster(of clusters: [WeightedColor], grid: Grid) -> Int? {
		guard !clusters.isEmpty, grid.border.count == grid.colors.count else { return nil }
		let centres = clusters.map(\.lab)
		var votes = [Int](repeating: 0, count: clusters.count)
		var band = 0
		for index in grid.colors.indices where grid.border[index] {
			votes[nearest(grid.colors[index], in: centres)] += 1
			band += 1
		}
		guard band > 0, let best = votes.indices.max(by: { votes[$0] < votes[$1] }) else { return nil }
		return Double(votes[best]) >= Double(band) * Tuning.minBackgroundShare ? best : nil
	}

	/// What the background renders as: near-white paper is plain white.
	static func rendered(background lab: LabColor) -> RGBColor {
		guard lab.l < Tuning.paperLightness || lab.chroma > Tuning.paperChroma else {
			return RGBColor(red: 1, green: 1, blue: 1)
		}
		return lab.rgb
	}

	/// Up to five clusters and text inks with clear chroma, most coverage
	/// first, leaving out colours near the background and the soft blends
	/// between the background and a stronger colour.
	static func palette(from clusters: [WeightedColor], background: LabColor?, inks: [WeightedColor]) -> [RGBColor] {
		var candidates = clusters.filter { isAccent($0.lab) }
		for ink in inks where isAccent(ink.lab) {
			guard let match = candidates.firstIndex(where: { $0.lab.distance(to: ink.lab) < Tuning.mergeDistance }) else {
				candidates.append(ink)
				continue
			}
			// The solid core of the text is the truer reading of the same colour.
			if ink.lab.chroma > candidates[match].lab.chroma {
				candidates[match].lab = ink.lab
			}
			candidates[match].weight += ink.weight
		}
		if let background {
			let solids = clusters.map(\.lab) + inks.map(\.lab)
			candidates = candidates.filter { candidate in
				candidate.lab.distance(to: background) >= Tuning.mergeDistance
					&& !solids.contains { isBlend(candidate.lab, between: background, and: $0) }
			}
		}
		return candidates.sorted { $0.weight > $1.weight }.prefix(Tuning.maxPaletteCount).map(\.lab.rgb)
	}

	/// Clear chroma: not near-white, grey or near-black.
	static func isAccent(_ colour: LabColor) -> Bool {
		colour.chroma >= Tuning.minAccentChroma && colour.l >= Tuning.minAccentLightness
	}

	/// `colour` sits on the way from `background` to a stronger `solid` (in
	/// sRGB, where edges are blended): the anti-aliased rim of a stroke or a
	/// glyph rather than a colour of its own.
	static func isBlend(_ colour: LabColor, between background: LabColor, and solid: LabColor) -> Bool {
		guard solid.distance(to: background) > colour.distance(to: background) else { return false }
		let from = background.rgb, to = solid.rgb
		guard let along = blendPosition(of: colour, from: from, to: to), along > 0, along < 1 else { return false }
		return LabColor(mixed(from, to, at: along)).distance(to: colour) < Tuning.blendDistance
	}

	/// Where the mix of `from` and `to` (in sRGB) nearest `colour` lies: 0 at
	/// `from`, 1 at `to`, outside 0…1 past either end; nil when they're the same colour.
	static func blendPosition(of colour: LabColor, from: RGBColor, to: RGBColor) -> Double? {
		let point = colour.rgb
		let direction = (red: to.red - from.red, green: to.green - from.green, blue: to.blue - from.blue)
		let length = direction.red * direction.red + direction.green * direction.green + direction.blue * direction.blue
		guard length > 1e-6 else { return nil }
		return ((point.red - from.red) * direction.red + (point.green - from.green) * direction.green
			+ (point.blue - from.blue) * direction.blue) / length
	}

	/// `from` mixed with `to` in sRGB: all `from` at 0, all `to` at 1.
	static func mixed(_ from: RGBColor, _ to: RGBColor, at along: Double) -> RGBColor {
		RGBColor(red: from.red + along * (to.red - from.red), green: from.green + along * (to.green - from.green),
				 blue: from.blue + along * (to.blue - from.blue))
	}

	// MARK: Text colour

	/// The ink of each text block that reads as one colour on the page background.
	static func textInks(_ blocks: [FolioBlock], pixels: Pixels, background: LabColor) -> [BlockInk] {
		var result: [BlockInk] = []
		for block in blocks {
			guard isText(block.content), let box = block.box,
				  let reading = ink(in: box, pixels: pixels, background: background),
				  isUniformInk(reading, background: background) else { continue }
			let weight = reading.share * box.width * box.height
			result.append(BlockInk(block: block.id, ink: WeightedColor(lab: reading.lab, weight: weight)))
		}
		return result
	}

	/// Headings, paragraphs and lists. Tables (rules, shaded headers) and
	/// diagrams (marker colours of their own) are left alone.
	static func isText(_ content: BlockContent) -> Bool {
		switch content {
		case .heading, .paragraph, .list: return true
		default: return false
		}
	}

	/// Two clusters inside a text block's box. The one farther from the
	/// background is the ink; its core (the half of its samples farthest from
	/// the box's other cluster) gives the colour without anti-aliased rims.
	static func ink(in box: NormalizedBox, pixels: Pixels, background: LabColor) -> InkReading? {
		let samples = pixels.samples(in: box, limit: Tuning.maxBoxSamples)
		guard samples.count >= Tuning.minBoxSamples,
			  let farthest = samples.max(by: { background.squaredDistance(to: $0) < background.squaredDistance(to: $1) }),
			  farthest.distance(to: background) >= Tuning.minInkContrast else { return nil }
		let split = kMeans(samples, seeds: [background, farthest], iterations: Tuning.boxIterations)
		guard split.centres.count == 2, split.labels.count == samples.count else { return nil }
		let inkIndex = split.centres[1].distance(to: background) >= split.centres[0].distance(to: background) ? 1 : 0
		let surround = split.centres[1 - inkIndex]
		let members = zip(samples, split.labels).filter { $0.1 == inkIndex }.map(\.0)
		guard let core = coreColour(of: members, awayFrom: surround) else { return nil }
		let others = zip(samples, split.labels).filter { $0.1 != inkIndex }.map(\.0)
		let strays = strayInkCount(others, background: background, ink: core.lab)
		return InkReading(lab: core.lab, share: Double(members.count) / Double(samples.count),
						  spread: core.spread, surround: surround, strayShare: Double(strays) / Double(samples.count))
	}

	/// How many of `samples` (the box's other cluster) are a second ink: well
	/// off the background and far from every blend of the background with
	/// `ink`, so neither paper nor the ink's own anti-aliased or JPEG-smeared
	/// rims. Black text beside a red or blue word sits nearer the paper than
	/// the saturated word does, so the split puts it with the paper, where
	/// only this finds it.
	static func strayInkCount(_ samples: [LabColor], background: LabColor, ink: LabColor) -> Int {
		let from = background.rgb, to = ink.rgb
		var count = 0
		for sample in samples where sample.distance(to: background) >= Tuning.minInkContrast {
			// The nearest point on the segment from the background to the ink, ends included.
			let along = min(1, max(0, blendPosition(of: sample, from: from, to: to) ?? 0))
			if LabColor(mixed(from, to, at: along)).distance(to: sample) > Tuning.strayInkDistance {
				count += 1
			}
		}
		return count
	}

	/// Mean colour and mean spread (ΔE) of the half of `members` farthest from `surround`.
	static func coreColour(of members: [LabColor], awayFrom surround: LabColor) -> (lab: LabColor, spread: Double)? {
		guard !members.isEmpty else { return nil }
		let distances = members.map { $0.distance(to: surround) }
		let cut = distances.sorted()[distances.count / 2]
		let core = members.indices.filter { distances[$0] >= cut }.map { members[$0] }
		guard !core.isEmpty else { return nil }
		let mean = core.reduce(LabColor.zero, +).scaled(by: 1 / Double(core.count))
		let spread = core.reduce(0) { $0 + $1.distance(to: mean) } / Double(core.count)
		return (mean, spread)
	}

	/// The ink is one colour of text on the page's own background: a minority
	/// of the box, the rest of the box close to the background with no second
	/// ink in it, and a uniform core (black text with a red word, or text on a
	/// coloured panel, is not).
	static func isUniformInk(_ reading: InkReading, background: LabColor) -> Bool {
		guard reading.share >= Tuning.minInkShare, reading.share <= Tuning.maxInkShare,
			  reading.strayShare <= Tuning.maxStrayInkShare else { return false }
		return reading.surround.distance(to: background) < Tuning.maxSurroundDistance
			&& reading.spread <= Tuning.maxInkSpread
	}

	/// A run takes the ink colour only when it is clearly coloured (chroma
	/// alone keeps it well away from black and from the renderer's own white
	/// on dark slides) and legible both on Word's white page and on the slide's
	/// background.
	static func colorsRuns(_ ink: LabColor, background: RGBColor) -> Bool {
		guard ink.chroma >= Tuning.minRunChroma else { return false }
		let colour = ink.rgb
		return colour.contrastRatio(with: RGBColor(red: 1, green: 1, blue: 1)) >= Tuning.minRunContrast
			&& colour.contrastRatio(with: background) >= Tuning.minRunContrast
	}
}

// MARK: - Working types

extension PageColorSampler {
	/// A colour and the fraction of the page it covers.
	struct WeightedColor: Hashable, Sendable {
		var lab: LabColor
		var weight: Double
	}

	/// k-means output: centres, how many samples each holds, and each sample's centre.
	struct Clustering {
		var centres: [LabColor]
		var counts: [Int]
		var labels: [Int]
	}

	/// What a text block's box holds: its ink and the colour around it.
	struct InkReading {
		/// The ink's core colour.
		var lab: LabColor
		/// Fraction of the box's samples that are ink.
		var share: Double
		/// Mean ΔE of the core samples from `lab`: small for one colour of text.
		var spread: Double
		/// The box's other cluster (the paper behind the text).
		var surround: LabColor
		/// Fraction of the box's samples that are a second ink hiding in `surround`.
		var strayShare: Double = 0
	}

	/// A text block whose ink reads as one colour.
	struct BlockInk {
		var block: UUID
		/// Weight is the ink's share of the whole page.
		var ink: WeightedColor
	}

	/// Point samples on a coarse grid: colour, colour bin and whether the
	/// sample lies in the band around the page edge.
	struct Grid {
		/// Colour bins at 4 bits per channel.
		static let binCount = 4096
		var colors: [LabColor] = []
		var bins: [Int] = []
		var border: [Bool] = []

		static func bin(_ red: UInt8, _ green: UInt8, _ blue: UInt8) -> Int {
			Int(red >> 4) << 8 | Int(green >> 4) << 4 | Int(blue >> 4)
		}
	}

	/// The page drawn over white into sRGB bytes at working size, top row first.
	struct Pixels {
		let width: Int
		let height: Int
		private let bytes: Data
		private let rowBytes: Int

		init?(image: CGImage, maxSide: Int) {
			guard image.width > 0, image.height > 0, maxSide > 0 else { return nil }
			let scale = min(1, Double(maxSide) / Double(max(image.width, image.height)))
			let w = max(1, Int((Double(image.width) * scale).rounded()))
			let h = max(1, Int((Double(image.height) * scale).rounded()))
			guard let space = CGColorSpace(name: CGColorSpace.sRGB),
				  let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
										  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
			let rect = CGRect(x: 0, y: 0, width: w, height: h)
			context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
			context.fill(rect)
			context.interpolationQuality = .medium
			context.draw(image, in: rect)
			guard let drawn = context.makeImage(), let data = drawn.dataProvider?.data as Data?,
				  drawn.bytesPerRow >= w * 4, data.count >= drawn.bytesPerRow * h else { return nil }
			width = w
			height = h
			bytes = data
			rowBytes = drawn.bytesPerRow
		}

		/// The 8-bit sRGB colour of one pixel (top-left origin).
		func rgb(x: Int, y: Int) -> (red: UInt8, green: UInt8, blue: UInt8) {
			let offset = bytes.startIndex + y * rowBytes + x * 4
			return (bytes[offset], bytes[offset + 1], bytes[offset + 2])
		}

		/// One sample per cell of a grid `longSide` cells on the page's long
		/// side, taken at the cell centre (no averaging, so colours stay pure).
		func grid(longSide: Int, borderFraction: Double) -> Grid {
			var grid = Grid()
			guard longSide > 0, width > 0, height > 0 else { return grid }
			let scale = Double(longSide) / Double(max(width, height))
			let columns = max(1, min(width, Int((Double(width) * scale).rounded())))
			let rows = max(1, min(height, Int((Double(height) * scale).rounded())))
			let band = max(1, Int((Double(min(columns, rows)) * borderFraction).rounded()))
			grid.colors.reserveCapacity(columns * rows)
			grid.bins.reserveCapacity(columns * rows)
			grid.border.reserveCapacity(columns * rows)
			for row in 0..<rows {
				let y = min(height - 1, Int((Double(row) + 0.5) * Double(height) / Double(rows)))
				for column in 0..<columns {
					let x = min(width - 1, Int((Double(column) + 0.5) * Double(width) / Double(columns)))
					let pixel = rgb(x: x, y: y)
					grid.colors.append(LabColor(red: pixel.red, green: pixel.green, blue: pixel.blue))
					grid.bins.append(Grid.bin(pixel.red, pixel.green, pixel.blue))
					grid.border.append(row < band || column < band || row >= rows - band || column >= columns - band)
				}
			}
			return grid
		}

		/// At most about `limit` evenly spaced samples inside a normalized,
		/// top-left-origin box; empty when the box is only a few pixels.
		func samples(in box: NormalizedBox, limit: Int) -> [LabColor] {
			let x0 = max(0, min(width, Int((box.x * Double(width)).rounded(.down))))
			let x1 = max(0, min(width, Int(((box.x + box.width) * Double(width)).rounded(.up))))
			let y0 = max(0, min(height, Int((box.y * Double(height)).rounded(.down))))
			let y1 = max(0, min(height, Int(((box.y + box.height) * Double(height)).rounded(.up))))
			guard limit > 0, x1 - x0 >= Tuning.minBoxPixels, y1 - y0 >= Tuning.minBoxPixels else { return [] }
			let area = Double((x1 - x0) * (y1 - y0))
			let step = max(1, Int((area / Double(limit)).squareRoot().rounded(.up)))
			var result: [LabColor] = []
			result.reserveCapacity(limit)
			for y in stride(from: y0, to: y1, by: step) {
				for x in stride(from: x0, to: x1, by: step) {
					let pixel = rgb(x: x, y: y)
					result.append(LabColor(red: pixel.red, green: pixel.green, blue: pixel.blue))
				}
			}
			return result
		}
	}

	/// Every threshold in one place. Distances are CIE76 ΔE in CIELAB.
	enum Tuning {
		// Sampling.
		static let workingMaxSide = 1024
		static let gridLongSide = 128
		static let borderFraction = 0.06

		// Clusters.
		static let clusterCount = 8
		static let pageIterations = 12
		static let seedSeparation = 10.0
		static let minClusterShare = 0.001
		static let mergeDistance = 12.0

		// Background: the edge-band share the paper must own, and what counts as white paper.
		static let minBackgroundShare = 0.4
		static let paperLightness = 90.0
		static let paperChroma = 6.0

		// Palette.
		static let minAccentChroma = 20.0
		static let minAccentLightness = 15.0
		static let blendDistance = 8.0
		static let maxPaletteCount = 5

		// Text ink inside a block's box.
		static let maxBoxSamples = 4096
		static let minBoxSamples = 64
		static let minBoxPixels = 4
		static let boxIterations = 8
		static let minInkContrast = 20.0
		static let minInkShare = 0.01
		static let maxInkShare = 0.45
		static let maxSurroundDistance = 12.0
		static let maxInkSpread = 10.0
		// A second ink: this far (ΔE) from every background-to-ink blend, on more than this share of the box.
		static let strayInkDistance = 40.0
		static let maxStrayInkShare = 0.001

		// Colouring runs: clearly coloured and legible (WCAG 3:1, large-text level).
		static let minRunChroma = 25.0
		static let minRunContrast = 3.0
	}
}

// MARK: - Colour spaces

/// A colour in CIELAB (D65), where distance (ΔE 1976) tracks what people see.
struct LabColor: Hashable, Sendable {
	var l: Double
	var a: Double
	var b: Double

	static let zero = LabColor(l: 0, a: 0, b: 0)

	init(l: Double, a: Double, b: Double) {
		self.l = l
		self.a = a
		self.b = b
	}

	/// From 8-bit sRGB, through a lookup table for the transfer curve.
	init(red: UInt8, green: UInt8, blue: UInt8) {
		self.init(linearRed: LabColor.linearTable[Int(red)], green: LabColor.linearTable[Int(green)],
				  blue: LabColor.linearTable[Int(blue)])
	}

	init(_ colour: RGBColor) {
		self.init(linearRed: LabColor.linear(colour.red), green: LabColor.linear(colour.green),
				  blue: LabColor.linear(colour.blue))
	}

	private init(linearRed red: Double, green: Double, blue: Double) {
		let x = (0.4124564 * red + 0.3575761 * green + 0.1804375 * blue) / LabColor.whiteX
		let y = 0.2126729 * red + 0.7151522 * green + 0.0721750 * blue
		let z = (0.0193339 * red + 0.1191920 * green + 0.9503041 * blue) / LabColor.whiteZ
		let fx = LabColor.f(x), fy = LabColor.f(y), fz = LabColor.f(z)
		self.init(l: 116 * fy - 16, a: 500 * (fx - fy), b: 200 * (fy - fz))
	}

	/// Back to sRGB, clamped to the gamut.
	var rgb: RGBColor {
		let fy = (l + 16) / 116
		let x = LabColor.whiteX * LabColor.fInverse(fy + a / 500)
		let y = LabColor.fInverse(fy)
		let z = LabColor.whiteZ * LabColor.fInverse(fy - b / 200)
		let red = 3.2404542 * x - 1.5371385 * y - 0.4985314 * z
		let green = -0.9692660 * x + 1.8760108 * y + 0.0415560 * z
		let blue = 0.0556434 * x - 0.2040259 * y + 1.0572252 * z
		return RGBColor(red: LabColor.gamma(red), green: LabColor.gamma(green), blue: LabColor.gamma(blue))
	}

	/// Distance from the grey axis: 0 for white, greys and black.
	var chroma: Double { (a * a + b * b).squareRoot() }

	func squaredDistance(to other: LabColor) -> Double {
		let dl = l - other.l, da = a - other.a, db = b - other.b
		return dl * dl + da * da + db * db
	}

	/// ΔE 1976.
	func distance(to other: LabColor) -> Double { squaredDistance(to: other).squareRoot() }

	static func + (lhs: LabColor, rhs: LabColor) -> LabColor {
		LabColor(l: lhs.l + rhs.l, a: lhs.a + rhs.a, b: lhs.b + rhs.b)
	}

	func scaled(by factor: Double) -> LabColor {
		LabColor(l: l * factor, a: a * factor, b: b * factor)
	}

	// D65 white point and the CIE constants (ε = 216/24389, κ = 24389/27).
	private static let whiteX = 0.95047
	private static let whiteZ = 1.08883
	private static let epsilon = 216.0 / 24389.0
	private static let kappa = 24389.0 / 27.0

	/// sRGB byte → linear light.
	private static let linearTable: [Double] = (0...255).map { LabColor.linear(Double($0) / 255) }

	/// sRGB component (0–1) → linear light.
	static func linear(_ value: Double) -> Double {
		value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
	}

	/// Linear light → sRGB component, clamped to 0–1.
	static func gamma(_ value: Double) -> Double {
		let clamped = max(0, min(1, value))
		return clamped <= 0.0031308 ? 12.92 * clamped : 1.055 * pow(clamped, 1 / 2.4) - 0.055
	}

	private static func f(_ t: Double) -> Double {
		t > epsilon ? cbrt(t) : (kappa * t + 16) / 116
	}

	private static func fInverse(_ t: Double) -> Double {
		let cube = t * t * t
		return cube > epsilon ? cube : (116 * t - 16) / kappa
	}
}

extension RGBColor {
	/// WCAG relative luminance (linear-light Y).
	var relativeLuminance: Double {
		0.2126 * LabColor.linear(red) + 0.7152 * LabColor.linear(green) + 0.0722 * LabColor.linear(blue)
	}

	/// WCAG contrast ratio: 1 for the same colour, 21 for black on white.
	func contrastRatio(with other: RGBColor) -> Double {
		let first = relativeLuminance, second = other.relativeLuminance
		return (max(first, second) + 0.05) / (min(first, second) + 0.05)
	}
}
