//
//  FigureCrop.swift
//  Rescriva (fork of Open Scanner)
//
//  Cuts a figure's picture out of its page for Word and PowerPoint. When the
//  page has a recipe and its original photo is on this iPhone, the picture
//  comes from the original at full resolution: the figure's box on the page
//  is mapped back through the recipe's turn and perspective crop to a small
//  quad on the photo, which is perspective-corrected on its own and scaled
//  to the box's proportions on the page. Otherwise it is cut from the stored
//  page image, as it is when the stored page isn't the shape the recipe
//  makes (it was turned or edited outside the editor, or its recipe synced
//  before its pixels): the box was measured on that page. Either way it gets
//  a small margin, at most 2000 px on its long side, as a JPEG.
//
//  The mapping is pure and unit-tested; the rest is Core Image and ImageIO,
//  safe on any thread.
//

import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO

/// Crops figure pictures from pages and their originals (see the file header).
enum FigureCrop {
	enum Tuning {
		/// Margin around the figure's box, as a share of the page.
		static let margin = 0.01
		static let maxLongSide: CGFloat = 2000
		static let jpegQuality: CGFloat = 0.85
		/// The smallest crop worth making, in pixels per side.
		static let minSide: CGFloat = 8
		/// A stored page whose width / height is further than this ratio from the recipe's wasn't
		/// made by it (whole-pixel rounding and the width cap stay far inside it).
		static let maxAspectDrift = 1.03
	}

	/// Thread-safe; shared by every crop.
	private static let context = CIContext(options: [.cacheIntermediates: false])
	private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)

	// MARK: Mapping (pure)

	/// `box` grown by `margin` on every side, kept on the page.
	static func padded(_ box: NormalizedBox, margin: Double = Tuning.margin) -> NormalizedBox {
		let minX = max(0, box.x - margin), minY = max(0, box.y - margin)
		let maxX = min(1, box.x + box.width + margin), maxY = min(1, box.y + box.height + margin)
		return NormalizedBox(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
	}

	/// The quad a page was perspective-corrected with: the recipe's own, or the whole photo when the
	/// page wasn't corrected (a full-frame recipe, or a quad `PageCleanup.correctPerspective`
	/// leaves alone).
	static func correctionQuad(_ quad: PageQuad) -> PageQuad {
		guard quad != .fullFrame, quad.isConvex, quad.area >= 0.01 else { return .fullFrame }
		return quad
	}

	/// `box` on a page made from its original with `quad` and then turned `quarterTurns` clockwise,
	/// as a quad on the upright original (normalized, top-left origin). Its corners are named as
	/// they appear on the page — `topLeft` is the spot shown at the box's top-left — so correcting
	/// the quad gives the box the right way up. Nil for a degenerate quad.
	static func originalQuad(of box: NormalizedBox, quad: PageQuad, quarterTurns: Int) -> PageQuad? {
		guard let map = Homography(unitSquareTo: correctionQuad(quad)) else { return nil }
		let corners = [CGPoint(x: box.x, y: box.y), CGPoint(x: box.x + box.width, y: box.y),
					   CGPoint(x: box.x + box.width, y: box.y + box.height), CGPoint(x: box.x, y: box.y + box.height)]
		var mapped: [CGPoint] = []
		for corner in corners {
			// The stored page is the corrected page turned; undo the turn, then the perspective crop.
			guard let point = map.apply(QuadViewMapping.unrotated(corner, quarterTurns: quarterTurns)) else { return nil }
			mapped.append(point)
		}
		return PageQuad(topLeft: mapped[0], topRight: mapped[1], bottomRight: mapped[2], bottomLeft: mapped[3])
	}

	/// The size a crop of `pixels` pixels takes at `aspect` (width / height), keeping its pixel count.
	static func aspectSize(pixels: Double, aspect: Double) -> CGSize {
		guard pixels > 0, aspect > 0, aspect.isFinite, pixels.isFinite else { return .zero }
		let width = (pixels * aspect).squareRoot()
		let height = (pixels / aspect).squareRoot()
		return CGSize(width: max(1, width.rounded()), height: max(1, height.rounded()))
	}

	// MARK: Cropping

	/// The figure in `box` on a page as JPEG data: from `original` through `recipe` when both are
	/// given, else from the stored page `pageData`. Nil when neither can be read.
	static func jpeg(pageData: Data, box: NormalizedBox, recipe: PageRecipe?, original: CGImage?) -> Data? {
		let area = padded(box)
		guard area.width > 0, area.height > 0, !pageData.isEmpty else { return nil }
		if let recipe, let original, let size = pixelSize(of: pageData), isMade(size, by: recipe, from: original),
		   let image = crop(original, box: area, recipe: recipe, pageSize: size), let data = encoded(image) {
			return data
		}
		guard let page = CIImage(data: pageData), let image = crop(page: page, box: area) else { return nil }
		return encoded(image)
	}

	/// True when a stored page of `pageSize` pixels has the shape `recipe` makes from `original`
	/// (within `maxAspectDrift`), so a box measured on it maps back through the recipe.
	static func isMade(_ pageSize: CGSize, by recipe: PageRecipe, from original: CGImage) -> Bool {
		guard pageSize.width > 0, pageSize.height > 0, let expected = recipeAspect(recipe, original: original) else { return false }
		let ratio = (pageSize.width / pageSize.height) / expected
		return ratio <= Tuning.maxAspectDrift && ratio >= 1 / Tuning.maxAspectDrift
	}

	/// The width / height of the page `recipe` makes from `original`, as `PageReprocessor.render`
	/// makes it, from Core Image's extents alone (nothing is rendered). Nil for an empty original.
	static func recipeAspect(_ recipe: PageRecipe, original: CGImage) -> Double? {
		guard original.width >= 1, original.height >= 1 else { return nil }
		var page = CIImage(cgImage: original)
		if recipe.quad != .fullFrame {
			page = PageCleanup.correctPerspective(page, quad: recipe.quad)
		}
		let extent = page.extent
		guard !extent.isInfinite, extent.width > 0, extent.height > 0 else { return nil }
		let aspect = extent.width / extent.height
		return QuarterTurns.normalized(recipe.rotation) % 2 == 0 ? aspect : 1 / aspect
	}

	/// `box` (on the page) from the original: its quad perspective-corrected on its own, then given
	/// the box's proportions on the page (`pageSize` in pixels) and capped.
	static func crop(_ original: CGImage, box: NormalizedBox, recipe: PageRecipe, pageSize: CGSize) -> CIImage? {
		guard original.width >= 1, original.height >= 1, pageSize.width > 0, pageSize.height > 0, box.height > 0,
			  let quad = originalQuad(of: box, quad: recipe.quad, quarterTurns: recipe.rotation), quad.isConvex else { return nil }
		let size = CGSize(width: original.width, height: original.height)
		func ciPoint(_ point: CGPoint) -> CGPoint {
			CGPoint(x: point.x * size.width, y: (1 - point.y) * size.height)
		}
		let filter = CIFilter.perspectiveCorrection()
		filter.inputImage = CIImage(cgImage: original)
		filter.topLeft = ciPoint(quad.topLeft)
		filter.topRight = ciPoint(quad.topRight)
		filter.bottomRight = ciPoint(quad.bottomRight)
		filter.bottomLeft = ciPoint(quad.bottomLeft)
		filter.crop = true
		guard let corrected = filter.outputImage else { return nil }
		let raw = corrected.extent
		guard !raw.isInfinite, raw.width >= Tuning.minSide, raw.height >= Tuning.minSide else { return nil }
		let aspect = (box.width * pageSize.width) / (box.height * pageSize.height)
		let target = aspectSize(pixels: raw.width * raw.height, aspect: aspect)
		guard target.width >= 1, target.height >= 1 else { return nil }
		let transform = CGAffineTransform(translationX: -raw.minX, y: -raw.minY)
			.concatenating(CGAffineTransform(scaleX: target.width / raw.width, y: target.height / raw.height))
		let proportioned = corrected.transformed(by: transform).cropped(to: CGRect(origin: .zero, size: target))
		return PageCleanup.limitLongSide(proportioned, to: Tuning.maxLongSide)
	}

	/// `box` cut straight from the stored page, capped.
	static func crop(page: CIImage, box: NormalizedBox) -> CIImage? {
		let extent = page.extent
		guard !extent.isInfinite, extent.width >= 1, extent.height >= 1 else { return nil }
		// Core Image's origin is at the bottom left.
		let rect = CGRect(x: extent.minX + box.x * extent.width, y: extent.minY + (1 - box.y - box.height) * extent.height,
						  width: box.width * extent.width, height: box.height * extent.height).integral.intersection(extent)
		guard !rect.isNull, rect.width >= Tuning.minSide, rect.height >= Tuning.minSide else { return nil }
		let cropped = page.cropped(to: rect).transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
		return PageCleanup.limitLongSide(cropped, to: Tuning.maxLongSide)
	}

	/// The pixel size of encoded image data, read from its header.
	static func pixelSize(of data: Data) -> CGSize? {
		guard let source = CGImageSourceCreateWithData(data as CFData, nil),
			  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
			  let width = properties[kCGImagePropertyPixelWidth] as? Int,
			  let height = properties[kCGImagePropertyPixelHeight] as? Int,
			  width > 0, height > 0 else { return nil }
		return CGSize(width: width, height: height)
	}

	/// `image` rendered whole as a JPEG.
	static func encoded(_ image: CIImage) -> Data? {
		let extent = image.extent
		guard !extent.isInfinite, extent.width >= 1, extent.height >= 1, let colorSpace else { return nil }
		let atOrigin = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
		let quality = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
		return context.jpegRepresentation(of: atOrigin, colorSpace: colorSpace, options: [quality: Tuning.jpegQuality])
	}
}

// MARK: - Homography

extension Homography {
	/// The projective map taking the unit square's corners (0, 0), (1, 0), (1, 1) and (0, 1) onto
	/// `quad`'s top-left, top-right, bottom-right and bottom-left. It is the map perspective
	/// correction inverts, so it takes a point on a corrected page back to the photo (both
	/// normalized, top-left origin). Nil when the quad is degenerate (three corners in a line).
	init?(unitSquareTo quad: PageQuad) {
		let square = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)]
		guard quad.corners.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
		self.init(from: square, to: quad.corners)
	}
}
