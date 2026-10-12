//
//  PageLooks.swift
//  Rescriva (fork of Open Scanner)
//
//  The looks that redraw a page instead of toning it: true black and white
//  (Sauvola's local threshold, after Leptonica) and "Ink" for whiteboards and
//  handwriting (the whitepaper filter from OSS Document Scanner, with its blur
//  sized from the page's own stroke width so thick marker strokes stay solid).
//  `LookRenderer` applies them for the export and the preview alike.
//
//  Pure Core Image, so the whole file builds and runs on macOS.
//

import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins

enum PageLooks {
	/// Numbers the looks are tuned with. Levels are sRGB-encoded, as the published algorithms use
	/// them; sizes are pixels of the image being processed or fractions of its long side.
	enum Tuning {
		/// Sauvola's window side as a fraction of the page's long side (60–80 px on a stored page).
		static let sauvolaWindow: CGFloat = 0.025
		static let sauvolaMinimumWindow: CGFloat = 7
		/// Sauvola's k: how far below its surroundings a pixel must be to count as ink.
		static let sauvolaK: CGFloat = 0.3
		/// Sauvola's R: the dynamic range of the standard deviation for levels in 0–1.
		static let sauvolaRange: CGFloat = 0.5
		/// Darker than this is ink whatever surrounds it, so solid fills and dark panels wider
		/// than the window don't wash out to white.
		static let solidInk: CGFloat = 0.2

		/// The Ink look's blur window per stroke width (the review's "about 4×").
		static let inkWindowPerStroke: CGFloat = 4
		static let inkMinimumWindow: CGFloat = 9
		static let inkMaximumWindow: CGFloat = 0.08
		/// Stroke width assumed when the page has too little ink to measure, per long side.
		static let inkFallbackStroke: CGFloat = 0.002
		/// Contrast stretch: 2nd to 99.5th percentile per channel, then the colour balance clips
		/// 2% and 1%. A stretch never spans less than `minimumSpan`, so a page with almost no ink
		/// doesn't blow its paper grain up into grey.
		static let stretchLow = 0.02
		static let stretchHigh = 0.995
		static let balanceLow = 0.02
		static let balanceHigh = 0.99
		static let minimumSpan: CGFloat = 0.5
		/// Radius, in pixels, of the slight blur after the stretch.
		static let smoothing: Float = 0.6
		/// The whitepaper's gamma 1.1 (as `level^(1 / 1.1)`), lifting what the stretch left grey.
		static let gamma: Float = 1 / 1.1

		/// Stroke analysis runs with the long side at most this many pixels.
		static let analysisSize: CGFloat = 1200
		/// Ink is darker than this fraction of the local paper (its brightest nearby level).
		static let inkContrast: CGFloat = 0.65
		/// The paper is the brightest level within this fraction of the long side.
		static let paperWindow: CGFloat = 0.06
		/// Erosion half-widths (analysis pixels) the stroke widths are read from.
		static let erosions = [1, 2, 3, 4, 6, 8, 12, 16, 24, 32]
		/// The measured width is that of the thickest strokes holding this share of the ink.
		static let thickShare: CGFloat = 0.1
		/// Less ink than this fraction of the page isn't measured.
		static let minimumInk: CGFloat = 0.0005
		/// Histogram bins for the percentile reads.
		static let bins = 256
	}

	// MARK: Black and white

	/// True black and white: Sauvola's local threshold over the page's luma. A pixel is ink when it
	/// is darker than `m · (1 + k · (s / R − 1))`, with m and s the mean and standard deviation of a
	/// window around it (sized from the page), so shading across bare paper, where s is small, stays
	/// white while text keeps its strokes. Opaque black and white, same extent.
	static func blackAndWhite(_ image: CIImage) -> CIImage {
		let extent = image.extent
		guard !extent.isInfinite, extent.width >= 1, extent.height >= 1 else { return image }
		let gray = luma(encoded(opaque(image)))
		let side = max(Tuning.sauvolaMinimumWindow, max(extent.width, extent.height) * Tuning.sauvolaWindow)
		let mean = boxBlurred(gray, side: side)
		let meanOfSquares = boxBlurred(multiply(gray, gray), side: side)
		let variance = clampedToUnit(subtract(multiply(mean, mean), from: meanOfSquares))
		let deviation = power(variance, 0.5)
		// T = m · ((1 − k) + (k / R) · s), nudged off zero for the division below.
		let k = Tuning.sauvolaK
		let factor = scaleLevels(deviation, gain: k / Tuning.sauvolaRange, bias: 1 - k)
		let threshold = scaleLevels(multiply(mean, factor), gain: 1, bias: 1e-4)
		// gray ÷ T reaches 1 (the blend stops there) exactly where the pixel is paper.
		let paper = thresholded(divide(gray, by: threshold), at: 0.999)
		let notSolid = thresholded(gray, at: Tuning.solidInk)
		return decoded(opaque(minimum(paper, notSolid))).cropped(to: extent)
	}

	// MARK: Ink

	/// "Ink", the whitepaper filter: the local background minus the page (a high-pass that keeps
	/// ink and drops the board's shading), negated so the board is white and each marker keeps its
	/// colour, stretched per channel, softened, lifted by a gamma and colour-balanced. The blur is
	/// about four times the page's stroke width (`strokeWidth(of:context:)`), so thick marker strokes
	/// stay solid instead of going hollow. Anything much wider than that window still goes hollow
	/// (filled shapes, sticky notes, photos, and a little where thick strokes cross), as with the
	/// original filter: it is a look for ink. Opaque, same extent.
	static func ink(_ image: CIImage, context: CIContext) -> CIImage {
		let extent = image.extent
		guard !extent.isInfinite, extent.width >= 1, extent.height >= 1 else { return image }
		let page = encoded(opaque(image))
		let longSide = max(extent.width, extent.height)
		let stroke = strokeWidth(of: page, context: context) ?? longSide * Tuning.inkFallbackStroke
		let widest = max(Tuning.inkMinimumWindow, longSide * Tuning.inkMaximumWindow)
		let side = min(max(stroke * Tuning.inkWindowPerStroke, Tuning.inkMinimumWindow), widest)
		assert(side >= Tuning.inkMinimumWindow, "the blur always spans a few pixels")
		// 1–2. Local background minus the page (floored at 0), negated: paper is 1, ink keeps its hue.
		let negated = scaleLevels(subtract(page, from: boxBlurred(page, side: side)), gain: -1, bias: 1)
		// 3–6. Stretch, soften, lift and balance.
		let stretched = stretch(negated, low: Tuning.stretchLow, high: Tuning.stretchHigh, context: context)
		let softened = gaussianBlurred(stretched, radius: Tuning.smoothing)
		let lifted = power(clampedToUnit(softened), Tuning.gamma)
		let balanced = stretch(lifted, low: Tuning.balanceLow, high: Tuning.balanceHigh, context: context)
		return decoded(opaque(clampedToUnit(balanced))).cropped(to: extent)
	}

	/// The width, in pixels of `page` (sRGB-encoded), of its thicker strokes: ink is eroded by
	/// growing squares and the width read from how fast it disappears (a stroke `w` wide survives
	/// an erosion of half-width `h` as `w − 2h`), at the size where only `thickShare` of the ink is
	/// left. Biased to the thick strokes on purpose: a wider blur costs thin strokes nothing, a
	/// narrower one hollows thick ones. Nil when the page has too little ink to measure.
	static func strokeWidth(of page: CIImage, context: CIContext) -> CGFloat? {
		let extent = page.extent
		let longSide = max(extent.width, extent.height)
		guard !extent.isInfinite, longSide >= 1 else { return nil }
		let scale = min(1, Tuning.analysisSize / longSide)
		let ink = inkMask(scaled(page, by: scale))
		let masks = [ink] + Tuning.erosions.map { eroded(ink, halfWidth: $0) }
		guard let fractions = areaAverages(masks, context: context), let total = fractions.first,
			  total >= Tuning.minimumInk else { return nil }
		let survival = fractions.map { $0 / total }
		let halfWidths = [0] + Tuning.erosions
		assert(survival.count == halfWidths.count, "one share per erosion")
		let target = Tuning.thickShare
		assert(target > 0 && target < 1, "a share strictly between none and all of the ink")
		for index in 1..<survival.count where survival[index] <= target {
			// Interpolate the half-width at which the surviving share falls to `target`.
			let (h0, h1) = (CGFloat(halfWidths[index - 1]), CGFloat(halfWidths[index]))
			let (s0, s1) = (survival[index - 1], survival[index])
			let half = s0 > s1 ? h0 + (h1 - h0) * (s0 - target) / (s0 - s1) : h1
			return 2 * half / (1 - target) / scale
		}
		// Strokes thicker than the largest erosion: the widest the analysis can say.
		return 2 * CGFloat(halfWidths[halfWidths.count - 1]) / (1 - target) / scale
	}

	/// 1 where `page` (sRGB-encoded) has ink: its darkest channel well below the local paper
	/// level, which is the brightest darkest-channel nearby. Coloured markers count as ink.
	private static func inkMask(_ page: CIImage) -> CIImage {
		let extent = page.extent
		let darkest = minimumComponent(page)
		let paper = gaussianBlurred(dilated(darkest, side: max(extent.width, extent.height) * Tuning.paperWindow), radius: 2)
		let relative = divide(darkest, by: scaleLevels(paper, gain: 1, bias: 1e-3))
		return scaleLevels(thresholded(relative, at: Tuning.inkContrast), gain: -1, bias: 1).cropped(to: extent)
	}

	// MARK: Percentiles

	/// Each channel stretched so its `low` quantile maps to 0 and its `high` quantile to 1, with
	/// the span kept at least `minimumSpan` (see `Tuning`). Unchanged when the histogram can't be read.
	private static func stretch(_ image: CIImage, low: Double, high: Double, context: CIContext) -> CIImage {
		guard let histograms = channelHistograms(image, context: context) else { return image }
		var gains: [CGFloat] = []
		var biases: [CGFloat] = []
		for histogram in histograms {
			let white = quantile(histogram, high)
			let black = min(quantile(histogram, low), white - Tuning.minimumSpan)
			assert(white > black, "the span is never empty")
			gains.append(1 / (white - black))
			biases.append(-black / (white - black))
		}
		guard gains.count == 3 else { return image }
		let filter = CIFilter.colorMatrix()
		filter.inputImage = image
		filter.rVector = CIVector(x: gains[0], y: 0, z: 0, w: 0)
		filter.gVector = CIVector(x: 0, y: gains[1], z: 0, w: 0)
		filter.bVector = CIVector(x: 0, y: 0, z: gains[2], w: 0)
		filter.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
		filter.biasVector = CIVector(x: biases[0], y: biases[1], z: biases[2], w: 0)
		return filter.outputImage ?? image
	}

	/// The level (0–1) below which `fraction` of the histogram's pixels lie.
	static func quantile(_ histogram: [CGFloat], _ fraction: Double) -> CGFloat {
		let total = histogram.reduce(0, +)
		guard total > 0, !histogram.isEmpty else { return CGFloat(fraction) }
		var running: CGFloat = 0
		for (bin, count) in histogram.enumerated() {
			running += count
			if running / total >= CGFloat(fraction) {
				return (CGFloat(bin) + 0.5) / CGFloat(histogram.count)
			}
		}
		return 1
	}

	/// Red, green and blue histograms of `image` (levels 0–1) over its extent, `Tuning.bins` bins each.
	private static func channelHistograms(_ image: CIImage, context: CIContext) -> [[CGFloat]]? {
		let filter = CIFilter.areaHistogram()
		filter.inputImage = clampedToUnit(image)
		filter.extent = image.extent
		filter.count = Tuning.bins
		filter.scale = 1
		guard let output = filter.outputImage,
			  let pixels = readFloats(output, width: Tuning.bins, context: context) else { return nil }
		return (0..<3).map { channel in
			(0..<Tuning.bins).map { CGFloat(pixels[$0 * 4 + channel]) }
		}
	}

	/// The mean of each (grey) mask over its extent, read in one pass.
	private static func areaAverages(_ masks: [CIImage], context: CIContext) -> [CGFloat]? {
		var strip: CIImage?
		for (index, mask) in masks.enumerated() {
			let average = CIFilter.areaAverage()
			average.inputImage = mask
			average.extent = mask.extent
			guard let pixel = average.outputImage?.cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1)) else { return nil }
			let placed = pixel.transformed(by: CGAffineTransform(translationX: CGFloat(index), y: 0))
			strip = strip.map { placed.composited(over: $0) } ?? placed
		}
		guard let strip, let pixels = readFloats(strip, width: masks.count, context: context) else { return nil }
		return (0..<masks.count).map { CGFloat(pixels[$0 * 4]) }
	}

	/// The first row of `image` from x = 0, `width` pixels of RGBA floats, as stored (no colour
	/// matching), decoded from the rendered bytes.
	private static func readFloats(_ image: CIImage, width: Int, context: CIContext) -> [Float]? {
		let bounds = CGRect(x: 0, y: 0, width: width, height: 1)
		guard width > 0, let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB),
			  let rendered = context.createCGImage(image, from: bounds, format: .RGBAf, colorSpace: space),
			  rendered.bitsPerPixel == 128, let data = rendered.dataProvider?.data as Data? else { return nil }
		let bytes = [UInt8](data)
		guard bytes.count >= width * 16 else { return nil }
		return (0..<(width * 4)).map { index in
			let at = index * 4
			let bits = UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
			return Float(bitPattern: bits)
		}
	}
}

// MARK: - Filter helpers

extension PageLooks {
	/// Working-space (linear) values re-encoded with the sRGB curve, so levels compare as the
	/// published algorithms expect.
	private static func encoded(_ image: CIImage) -> CIImage {
		image.applyingFilter("CILinearToSRGBToneCurve")
	}

	private static func decoded(_ image: CIImage) -> CIImage {
		image.applyingFilter("CISRGBToneCurveToLinear")
	}

	/// Alpha forced to 1.
	private static func opaque(_ image: CIImage) -> CIImage {
		let filter = CIFilter.colorMatrix()
		filter.inputImage = image
		filter.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
		filter.biasVector = CIVector(x: 0, y: 0, z: 0, w: 1)
		return filter.outputImage?.cropped(to: image.extent) ?? image
	}

	/// Rec. 601 luma in every channel.
	private static func luma(_ image: CIImage) -> CIImage {
		let weights = CIVector(x: 0.299, y: 0.587, z: 0.114, w: 0)
		let filter = CIFilter.colorMatrix()
		filter.inputImage = image
		filter.rVector = weights
		filter.gVector = weights
		filter.bVector = weights
		filter.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
		filter.biasVector = CIVector(x: 0, y: 0, z: 0, w: 1)
		return filter.outputImage ?? image
	}

	/// Lanczos resample by `scale`, at the origin.
	private static func scaled(_ image: CIImage, by scale: CGFloat) -> CIImage {
		guard scale > 0, abs(scale - 1) > 1e-6 else { return image }
		let filter = CIFilter.lanczosScaleTransform()
		filter.inputImage = image.clampedToExtent()
		filter.scale = Float(scale)
		filter.aspectRatio = 1
		let target = CGRect(x: 0, y: 0, width: max(1, (image.extent.width * scale).rounded(.down)),
							height: max(1, (image.extent.height * scale).rounded(.down)))
		return filter.outputImage?.cropped(to: target) ?? image
	}

	/// Mean over a square window `side` pixels across, edges extended.
	private static func boxBlurred(_ image: CIImage, side: CGFloat) -> CIImage {
		let filter = CIFilter.boxBlur()
		filter.inputImage = image.clampedToExtent()
		filter.radius = Float(max(1, side / 2))
		return filter.outputImage?.cropped(to: image.extent) ?? image
	}

	private static func gaussianBlurred(_ image: CIImage, radius: Float) -> CIImage {
		let filter = CIFilter.gaussianBlur()
		filter.inputImage = image.clampedToExtent()
		filter.radius = radius
		return filter.outputImage?.cropped(to: image.extent) ?? image
	}

	/// Local maximum over a square about `side` pixels across (odd, at least 3).
	private static func dilated(_ image: CIImage, side: CGFloat) -> CIImage {
		let filter = CIFilter.morphologyRectangleMaximum()
		let pixels = max(3, Int(side.rounded()) | 1)
		filter.inputImage = image.clampedToExtent()
		filter.width = Float(pixels)
		filter.height = Float(pixels)
		return filter.outputImage?.cropped(to: image.extent) ?? image
	}

	/// Local minimum over the square `2 · halfWidth + 1` pixels across, edges extended, so strokes
	/// running off the page keep their width.
	private static func eroded(_ image: CIImage, halfWidth: Int) -> CIImage {
		let filter = CIFilter.morphologyRectangleMinimum()
		filter.inputImage = image.clampedToExtent()
		filter.width = Float(2 * halfWidth + 1)
		filter.height = Float(2 * halfWidth + 1)
		return filter.outputImage?.cropped(to: image.extent) ?? image
	}

	/// 1 per channel where the level is above `level`, else 0.
	private static func thresholded(_ image: CIImage, at level: CGFloat) -> CIImage {
		let filter = CIFilter.colorThreshold()
		filter.inputImage = image
		filter.threshold = Float(level)
		return filter.outputImage?.cropped(to: image.extent) ?? image
	}

	/// `level^exponent` per channel.
	private static func power(_ image: CIImage, _ exponent: Float) -> CIImage {
		let filter = CIFilter.gammaAdjust()
		filter.inputImage = image
		filter.power = exponent
		return filter.outputImage ?? image
	}

	/// `in · gain + bias` on RGB; alpha untouched.
	private static func scaleLevels(_ image: CIImage, gain: CGFloat, bias: CGFloat) -> CIImage {
		let filter = CIFilter.colorMatrix()
		filter.inputImage = image
		filter.rVector = CIVector(x: gain, y: 0, z: 0, w: 0)
		filter.gVector = CIVector(x: 0, y: gain, z: 0, w: 0)
		filter.bVector = CIVector(x: 0, y: 0, z: gain, w: 0)
		filter.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
		filter.biasVector = CIVector(x: bias, y: bias, z: bias, w: 0)
		return filter.outputImage ?? image
	}

	private static func clampedToUnit(_ image: CIImage) -> CIImage {
		let filter = CIFilter.colorClamp()
		filter.inputImage = image
		filter.minComponents = CIVector(x: 0, y: 0, z: 0, w: 0)
		filter.maxComponents = CIVector(x: 1, y: 1, z: 1, w: 1)
		return filter.outputImage ?? image
	}

	private static func multiply(_ a: CIImage, _ b: CIImage) -> CIImage {
		let filter = CIFilter.multiplyCompositing()
		filter.inputImage = b
		filter.backgroundImage = a
		return filter.outputImage?.cropped(to: a.extent) ?? a
	}

	/// `minuend − subtrahend` per channel, floored at 0.
	private static func subtract(_ subtrahend: CIImage, from minuend: CIImage) -> CIImage {
		let filter = CIFilter.subtractBlendMode()
		filter.inputImage = subtrahend
		filter.backgroundImage = minuend
		return filter.outputImage?.cropped(to: minuend.extent) ?? minuend
	}

	private static func divide(_ numerator: CIImage, by denominator: CIImage) -> CIImage {
		let filter = CIFilter.divideBlendMode()
		filter.inputImage = denominator
		filter.backgroundImage = numerator
		return filter.outputImage?.cropped(to: numerator.extent) ?? numerator
	}

	private static func minimum(_ a: CIImage, _ b: CIImage) -> CIImage {
		let filter = CIFilter.minimumCompositing()
		filter.inputImage = a
		filter.backgroundImage = b
		return filter.outputImage?.cropped(to: a.extent) ?? a
	}

	/// Gray image of `min(r, g, b)`.
	private static func minimumComponent(_ image: CIImage) -> CIImage {
		let filter = CIFilter.minimumComponent()
		filter.inputImage = image
		return filter.outputImage ?? image
	}
}
