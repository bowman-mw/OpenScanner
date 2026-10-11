//
//  SpreadSplit.swift
//  Folio (fork of Open Scanner)
//
//  "Split into two pages" for a photo of a book or magazine spread. A crop
//  much wider than tall (as the page is shown, turns included) is offered
//  the split. The fold is found as OSS Document Scanner's
//  detectGutterAndSplit finds it: the horizontal gradient summed down each
//  column of the cropped page, smoothed, and its minimum taken in the middle
//  25–75% of the width, here centred on the whole quiet stretch around that
//  minimum. A minimum no quieter than the pages' text is no fold, and the
//  line starts in the middle instead; it can be dragged either way.
//
//  The split line is a straight line down the cropped page, so in the
//  original photo it runs between the matching points of the crop's top and
//  bottom edges under the crop's perspective (the homography taking the unit
//  square to the quad, GlareFusion's `Homography`), and each half's crop is
//  the matching part of the quad. The geometry and the fold search are
//  unit-tested; rendering the crop for the search uses Core Image.
//

import CoreGraphics
import CoreImage
import Foundation

/// Finding the fold of a two-page spread and splitting its crop (see the file header).
enum SpreadSplit {
	enum Tuning {
		/// A crop at least this much wider than tall, as shown, looks like a spread.
		static let minSpreadAspect: CGFloat = 1.25
		/// Where the fold is looked for, as shares of the cropped page's width.
		static let searchRange: ClosedRange<Double> = 0.25...0.75
		/// Where the line can be dragged to: each page keeps at least a tenth of the spread.
		static let lineRange: ClosedRange<CGFloat> = 0.1...0.9
		/// The cropped page is searched at this width (pixels) …
		static let workingWidth = 800
		/// … with column energies smoothed over this share of it either side (±15 px at 1000 px
		/// in OSS Document Scanner).
		static let smoothingShare = 0.015
		/// The fold is no busier than this share of the search range's median column.
		static let maxFoldShare = 0.5
		/// Columns within this share of the way from the minimum to the median count as the fold.
		static let foldPlateauShare = 0.1
		/// Long side the original is scaled to before the crop is rendered for the search.
		static let searchSourceSize: CGFloat = 1600
	}

	/// Thread-safe; shared by every search.
	private static let context = CIContext(options: [.cacheIntermediates: false])

	// MARK: Offering the split

	/// The cropped page's width over its height as shown: the crop's real aspect on a photo of
	/// `imageSize` pixels (as perspective correction makes it), inverted for an odd number of turns.
	static func displayedAspect(of quad: PageQuad, imageSize: CGSize, quarterTurns: Int) -> CGFloat {
		guard imageSize.width > 0, imageSize.height > 0 else { return 0 }
		let aspect = PageCleanup.estimatedAspectRatio(of: quad, imageSize: imageSize) ?? edgeAspect(of: quad, imageSize: imageSize)
		guard aspect > 0, aspect.isFinite else { return 0 }
		return QuarterTurns.normalized(quarterTurns) % 2 == 0 ? aspect : 1 / aspect
	}

	/// The quad's mean top and bottom edge over its mean left and right edge, in pixels.
	static func edgeAspect(of quad: PageQuad, imageSize: CGSize) -> CGFloat {
		func length(_ start: CGPoint, _ end: CGPoint) -> CGFloat {
			hypot((end.x - start.x) * imageSize.width, (end.y - start.y) * imageSize.height)
		}
		let across = (length(quad.topLeft, quad.topRight) + length(quad.bottomLeft, quad.bottomRight)) / 2
		let down = (length(quad.topLeft, quad.bottomLeft) + length(quad.topRight, quad.bottomRight)) / 2
		guard down > 0 else { return 0 }
		return across / down
	}

	/// True when the crop, as shown, is wide enough to be two facing pages.
	static func looksLikeSpread(_ quad: PageQuad, imageSize: CGSize, quarterTurns: Int) -> Bool {
		displayedAspect(of: quad, imageSize: imageSize, quarterTurns: quarterTurns) >= Tuning.minSpreadAspect
	}

	// MARK: Finding the fold

	/// Where the fold falls on `original` cropped to `quad` and turned `quarterTurns`, as a share of
	/// the cropped page's width as shown; nil when there is no clear fold. Any thread.
	static func findFold(on original: CGImage, quad: PageQuad, quarterTurns: Int) -> Double? {
		guard original.width >= 2, original.height >= 2 else { return nil }
		let small = PageCleanup.limitLongSide(CIImage(cgImage: original), to: Tuning.searchSourceSize)
		let cropped = quad == .fullFrame ? small : PageCleanup.correctPerspective(small, quad: quad)
		let page = PageReprocessor.rotated(cropped, quarterTurns: quarterTurns)
		let bounds = page.extent.integral
		guard !bounds.isInfinite, bounds.width >= 2, bounds.height >= 2,
			  let rendered = context.createCGImage(page, from: bounds),
			  let gray = StyleDetector.Gray(image: rendered, maxSide: Tuning.workingWidth) else { return nil }
		return foldPosition(in: gray)
	}

	/// Where the fold falls in `gray` (a share of its width), or nil when there's no clear fold.
	static func foldPosition(in gray: StyleDetector.Gray) -> Double? {
		guard gray.width >= 8, gray.height >= 1 else { return nil }
		let radius = max(2, Int((Double(gray.width) * Tuning.smoothingShare).rounded()))
		return foldPosition(inEnergy: smoothed(columnEnergy(of: gray), radius: radius))
	}

	/// For each pair of neighbouring columns, the summed difference between them down the page:
	/// high across lines of text, low across blank margins and the fold.
	static func columnEnergy(of gray: StyleDetector.Gray) -> [Double] {
		guard gray.width >= 2, gray.pixels.count == gray.width * gray.height else { return [] }
		var energy = [Double](repeating: 0, count: gray.width - 1)
		for row in 0..<gray.height {
			let start = row * gray.width
			for column in 0..<(gray.width - 1) {
				energy[column] += Double(abs(Int(gray.pixels[start + column + 1]) - Int(gray.pixels[start + column])))
			}
		}
		return energy
	}

	/// `values` averaged over `radius` either side (fewer at the ends).
	static func smoothed(_ values: [Double], radius: Int) -> [Double] {
		guard radius > 0, !values.isEmpty else { return values }
		var prefix = [0.0]
		prefix.reserveCapacity(values.count + 1)
		for value in values {
			prefix.append((prefix.last ?? 0) + value)
		}
		return values.indices.map { index in
			let low = max(0, index - radius)
			let high = min(values.count - 1, index + radius)
			return (prefix[high + 1] - prefix[low]) / Double(high - low + 1)
		}
	}

	/// The middle of the quietest stretch of `energy` within the search range, as a share of the
	/// page's width; nil when that stretch is no quieter than the pages around it.
	static func foldPosition(inEnergy energy: [Double]) -> Double? {
		let count = energy.count
		let low = Int((Double(count) * Tuning.searchRange.lowerBound).rounded(.up))
		let high = Int((Double(count) * Tuning.searchRange.upperBound).rounded(.down))
		guard count >= 4, low < high, let quietest = (low...high).min(by: { energy[$0] < energy[$1] }) else { return nil }
		let window = energy[low...high].sorted()
		let typical = window[window.count / 2]
		let minimum = energy[quietest]
		guard typical > 0, minimum <= Tuning.maxFoldShare * typical else { return nil }
		// The fold's whole quiet stretch, not just its first column: a blank gutter is a plateau.
		let ceiling = minimum + Tuning.foldPlateauShare * (typical - minimum)
		var first = quietest
		var last = quietest
		for column in stride(from: quietest - 1, through: low, by: -1) {
			guard energy[column] <= ceiling else { break }
			first = column
		}
		for column in stride(from: quietest + 1, through: high, by: 1) {
			guard energy[column] <= ceiling else { break }
			last = column
		}
		// Energy `i` sits between pixel columns `i` and `i + 1`.
		return (Double(first + last) / 2 + 1) / Double(count + 1)
	}

	// MARK: Splitting the crop

	/// The cropped page's corners (0...1, top-left origin, before turning), in the quad's order.
	static let unitSquare = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)]

	/// The point of `quad` at (`u`, `v`) of the cropped page (0...1 each, top-left origin, before
	/// turning), under the crop's perspective; nil for a degenerate quad.
	static func point(in quad: PageQuad, u: CGFloat, v: CGFloat) -> CGPoint? {
		Homography(from: unitSquare, to: quad.corners)?.apply(CGPoint(x: u, y: v))
	}

	/// Where `point` (normalized on the original) sits on the cropped page, (u, v) before turning;
	/// nil for a degenerate quad.
	static func unitPosition(of point: CGPoint, in quad: PageQuad) -> CGPoint? {
		Homography(from: quad.corners, to: unitSquare)?.apply(point)
	}

	/// The line at `fraction` across the cropped page as shown (turns included), as its two ends on
	/// the original: from the top of the page as shown to its bottom. Nil for a degenerate quad.
	static func line(in quad: PageQuad, at fraction: CGFloat, quarterTurns: Int) -> (start: CGPoint, end: CGPoint)? {
		let top = QuadViewMapping.unrotated(CGPoint(x: fraction, y: 0), quarterTurns: quarterTurns)
		let bottom = QuadViewMapping.unrotated(CGPoint(x: fraction, y: 1), quarterTurns: quarterTurns)
		guard let start = point(in: quad, u: top.x, v: top.y), let end = point(in: quad, u: bottom.x, v: bottom.y) else { return nil }
		return (start, end)
	}

	/// How far across the cropped page as shown `point` (normalized on the original) sits, kept
	/// within `Tuning.lineRange`; nil for a degenerate quad.
	static func fraction(of point: CGPoint, in quad: PageQuad, quarterTurns: Int) -> CGFloat? {
		guard let unit = unitPosition(of: point, in: quad) else { return nil }
		let shown = QuadViewMapping.rotated(unit, quarterTurns: quarterTurns)
		guard shown.x.isFinite else { return nil }
		return min(max(shown.x, Tuning.lineRange.lowerBound), Tuning.lineRange.upperBound)
	}

	/// The crops of the two pages either side of the line at `fraction` across the cropped page as
	/// shown: `first` is the page on the left as shown. Each is a quad on the original in the same
	/// corner order as `quad`, so it turns the same way. Nil when either would be unusable.
	static func halves(of quad: PageQuad, at fraction: CGFloat, quarterTurns: Int) -> (first: PageQuad, second: PageQuad)? {
		guard fraction.isFinite, Tuning.lineRange.contains(fraction),
			  let first = part(of: quad, shownFrom: 0, to: fraction, quarterTurns: quarterTurns),
			  let second = part(of: quad, shownFrom: fraction, to: 1, quarterTurns: quarterTurns),
			  QuadEditing.isAcceptable(first), QuadEditing.isAcceptable(second) else { return nil }
		return (first, second)
	}

	/// The part of `quad` between `start` and `end` across the cropped page as shown; nil for a
	/// degenerate quad.
	static func part(of quad: PageQuad, shownFrom start: CGFloat, to end: CGFloat, quarterTurns: Int) -> PageQuad? {
		// The shown strip is a rectangle on the unturned page too; find its sides there.
		let corners = [CGPoint(x: start, y: 0), CGPoint(x: end, y: 0), CGPoint(x: end, y: 1), CGPoint(x: start, y: 1)]
			.map { QuadViewMapping.unrotated($0, quarterTurns: quarterTurns) }
		guard let minU = corners.map(\.x).min(), let maxU = corners.map(\.x).max(),
			  let minV = corners.map(\.y).min(), let maxV = corners.map(\.y).max(),
			  let topLeft = point(in: quad, u: minU, v: minV), let topRight = point(in: quad, u: maxU, v: minV),
			  let bottomRight = point(in: quad, u: maxU, v: maxV), let bottomLeft = point(in: quad, u: minU, v: maxV)
		else { return nil }
		return PageQuad(topLeft: topLeft, topRight: topRight, bottomRight: bottomRight, bottomLeft: bottomLeft)
	}
}
