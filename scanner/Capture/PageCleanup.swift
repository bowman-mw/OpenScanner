//
//  PageCleanup.swift
//  Rescriva (fork of Open Scanner)
//
//  Pure Core Image page processing: perspective correction and per-mode cleanup.
//  No AVFoundation, Vision or UIKit, so the whole file builds and runs on macOS.
//

import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins

// MARK: - CaptureMode

/// The kind of surface being captured; it selects the cleanup recipe in `PageCleanup.clean`.
///
/// `CaptureCamera.Mode` is a typealias of this type. The raw values are stored tokens:
/// never rename or localize them. Show a separate display string in the UI instead.
enum CaptureMode: String, CaseIterable {
	case document
	case whiteboard
}

// MARK: - PageQuad

/// A detected page outline as four corners.
///
/// Points are normalized (0–1) with a **top-left origin** in the space of the frame they were
/// detected in:
/// - From `CaptureCamera.quad`: the upright (portrait) video frame, i.e. the rotated buffer
///   Vision analysed, with Vision's lower-left origin already flipped to top-left.
///   `CameraPreviewView` converts these to AVFoundation's unrotated capture-device space
///   before calling `layerPointConverted(fromCaptureDevicePoint:)`.
/// - For `PageCleanup.correctPerspective`: the image's own space.
///
/// Corners are kept in clockwise order starting at the visual top-left (see `init(unordered:)`),
/// so the same physical corner keeps the same name from frame to frame.
struct PageQuad: Equatable {
	var topLeft: CGPoint
	var topRight: CGPoint
	var bottomRight: CGPoint
	var bottomLeft: CGPoint
}

extension PageQuad {
	/// The whole frame.
	static let fullFrame = PageQuad(
		topLeft: CGPoint(x: 0, y: 0),
		topRight: CGPoint(x: 1, y: 0),
		bottomRight: CGPoint(x: 1, y: 1),
		bottomLeft: CGPoint(x: 0, y: 1)
	)

	/// The corners in clockwise order: top-left, top-right, bottom-right, bottom-left.
	var corners: [CGPoint] {
		[topLeft, topRight, bottomRight, bottomLeft]
	}

	/// Builds a quad from four corners in any order (top-left origin).
	///
	/// The points are sorted clockwise around their centroid and the run is started at the
	/// point nearest the frame's top-left (smallest `x + y`). Returns nil unless exactly four
	/// points are given.
	init?(unordered points: [CGPoint]) {
		guard points.count == 4 else { return nil }
		let centerX = points.reduce(CGFloat(0)) { $0 + $1.x } / 4
		let centerY = points.reduce(CGFloat(0)) { $0 + $1.y } / 4
		// With y pointing down, increasing atan2 runs clockwise on screen.
		let clockwise = points.sorted {
			atan2($0.y - centerY, $0.x - centerX) < atan2($1.y - centerY, $1.x - centerX)
		}
		guard let start = clockwise.indices.min(by: {
			clockwise[$0].x + clockwise[$0].y < clockwise[$1].x + clockwise[$1].y
		}) else { return nil }
		let ordered = (0..<4).map { clockwise[(start + $0) % 4] }
		self.init(topLeft: ordered[0], topRight: ordered[1], bottomRight: ordered[2], bottomLeft: ordered[3])
	}

	/// The largest distance any corner moved between `self` and `other`, in normalized units.
	func maxCornerDistance(to other: PageQuad) -> CGFloat {
		zip(corners, other.corners).reduce(CGFloat(0)) { result, pair in
			max(result, hypot(pair.0.x - pair.1.x, pair.0.y - pair.1.y))
		}
	}

	/// The enclosed area as a fraction of the frame (shoelace formula).
	var area: CGFloat {
		let points = corners
		var twiceArea: CGFloat = 0
		for index in 0..<4 {
			let current = points[index]
			let next = points[(index + 1) % 4]
			twiceArea += current.x * next.y - next.x * current.y
		}
		return abs(twiceArea) / 2
	}

	/// True when the outline is a strictly convex quadrilateral (no fold-over or collinear corners).
	var isConvex: Bool {
		let points = corners
		var sign: CGFloat = 0
		for index in 0..<4 {
			let a = points[index]
			let b = points[(index + 1) % 4]
			let c = points[(index + 2) % 4]
			let cross = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
			guard abs(cross) > 1e-9 else { return false }
			if sign == 0 {
				sign = cross
			} else if (cross > 0) != (sign > 0) {
				return false
			}
		}
		return true
	}

	/// The quad shrunk toward its centroid by `fraction` of each corner's distance from it.
	///
	/// Detected outlines often sit a hair outside the paper; a 1% inset trims that sliver of
	/// table without touching any content (it only eats into the page margin).
	func inset(by fraction: CGFloat) -> PageQuad {
		let points = corners
		let center = CGPoint(
			x: points.reduce(CGFloat(0)) { $0 + $1.x } / 4,
			y: points.reduce(CGFloat(0)) { $0 + $1.y } / 4
		)
		let keep = 1 - min(max(fraction, 0), 1)
		func pulled(_ point: CGPoint) -> CGPoint {
			CGPoint(x: center.x + (point.x - center.x) * keep, y: center.y + (point.y - center.y) * keep)
		}
		return PageQuad(topLeft: pulled(topLeft), topRight: pulled(topRight), bottomRight: pulled(bottomRight), bottomLeft: pulled(bottomLeft))
	}

	/// Re-expresses a quad measured in a centred aspect-fill crop of a frame in that frame's own
	/// normalized space.
	///
	/// Used to move the live-preview quad onto the full still when the video frame and the photo
	/// have different aspect ratios (aspect = width / height). Equal aspects return `self`.
	func mappedFromCenterCrop(cropAspect: CGFloat, intoFrameAspect frameAspect: CGFloat) -> PageQuad {
		guard cropAspect > 0, frameAspect > 0, abs(cropAspect - frameAspect) > 1e-4 else { return self }
		let map: (CGPoint) -> CGPoint
		if cropAspect < frameAspect {
			// The crop is narrower: it spans the full height and the centre of the width.
			let fraction = cropAspect / frameAspect
			map = { CGPoint(x: 0.5 + ($0.x - 0.5) * fraction, y: $0.y) }
		} else {
			// The crop is wider: it spans the full width and the centre of the height.
			let fraction = frameAspect / cropAspect
			map = { CGPoint(x: $0.x, y: 0.5 + ($0.y - 0.5) * fraction) }
		}
		return PageQuad(topLeft: map(topLeft), topRight: map(topRight), bottomRight: map(bottomRight), bottomLeft: map(bottomLeft))
	}
}

// MARK: - PageCleanup

/// Stateless Core Image recipes that turn a photo of a page into a clean scan.
///
/// Every function returns a lazy `CIImage`; nothing renders until the caller hands the result to a
/// `CIContext`. Outputs have their extent at the origin. Work happens in Core Image's linear
/// working space, where lighting is multiplicative, so dividing by an illumination estimate
/// flattens shadows without shifting colours.
enum PageCleanup {

	/// Assumed focal length, as a fraction of the image's long side, when it cannot be recovered
	/// from the quad itself. An iPhone main camera (≈ 26 mm equivalent) is about 0.75–0.8.
	static let assumedFocalLengthFactor: CGFloat = 0.8

	/// Perspective-corrects `image` to the quad (normalized, top-left origin, in the image's own
	/// space).
	///
	/// The output aspect ratio is the page's real one, recovered from the projective geometry of the
	/// quad (Zhang & He, "Whiteboard scanning and image enhancement"), with the edge-length ratio as
	/// the fallback. The pixel count of Core Image's raw correction is kept. A degenerate or
	/// non-convex quad returns the image unchanged (moved to the origin).
	static func correctPerspective(_ image: CIImage, quad: PageQuad) -> CIImage {
		let extent = image.extent
		guard !extent.isInfinite, extent.width >= 2, extent.height >= 2 else { return image }
		let origin = atOrigin(image)
		guard quad.isConvex, quad.area >= 0.01 else { return origin }

		let filter = CIFilter.perspectiveCorrection()
		filter.inputImage = origin
		filter.topLeft = ciPoint(quad.topLeft, size: extent.size)
		filter.topRight = ciPoint(quad.topRight, size: extent.size)
		filter.bottomRight = ciPoint(quad.bottomRight, size: extent.size)
		filter.bottomLeft = ciPoint(quad.bottomLeft, size: extent.size)
		filter.crop = true
		guard let corrected = filter.outputImage else { return origin }
		let raw = corrected.extent
		guard !raw.isInfinite, raw.width >= 1, raw.height >= 1 else { return origin }

		let rawAspect = raw.width / raw.height
		var aspect = rawAspect
		if let estimate = estimatedAspectRatio(of: quad, imageSize: extent.size),
		   estimate / rawAspect < 1.6, rawAspect / estimate < 1.6 {
			aspect = estimate
		}
		let pixelCount = raw.width * raw.height
		let width = max(3, (pixelCount * aspect).squareRoot().rounded())
		let height = max(3, (pixelCount / aspect).squareRoot().rounded())
		let transform = CGAffineTransform(translationX: -raw.minX, y: -raw.minY)
			.concatenating(CGAffineTransform(scaleX: width / raw.width, y: height / raw.height))
		// Drop the one-pixel border, where sampling at the quad's edge mixes in the background.
		let interior = CGRect(x: 1, y: 1, width: width - 2, height: height - 2)
		return atOrigin(corrected.transformed(by: transform).cropped(to: interior))
	}

	/// The real width ÷ height of the rectangle whose perspective projection is `quad`.
	///
	/// Assumes a pinhole camera with square pixels and the principal point at the image centre
	/// (true for an uncropped photo). The focal length is recovered from the quad when that is
	/// well conditioned, otherwise `assumedFocalLengthFactor` is used. Returns nil for degenerate
	/// input.
	static func estimatedAspectRatio(of quad: PageQuad, imageSize: CGSize) -> CGFloat? {
		let width = Double(imageSize.width)
		let height = Double(imageSize.height)
		guard width > 0, height > 0, quad.isConvex else { return nil }
		let longSide = max(width, height)
		let u0 = width / 2
		let v0 = height / 2
		func homogeneous(_ point: CGPoint) -> Vector3 {
			Vector3(x: Double(point.x) * width, y: Double(point.y) * height, z: 1)
		}
		// Rectangle corners (0,0), (w,0), (0,h), (w,h) project to m1, m2, m3, m4.
		let m1 = homogeneous(quad.topLeft)
		let m2 = homogeneous(quad.topRight)
		let m3 = homogeneous(quad.bottomLeft)
		let m4 = homogeneous(quad.bottomRight)
		let k2Denominator = m2.cross(m4).dot(m3)
		let k3Denominator = m3.cross(m4).dot(m2)
		guard abs(k2Denominator) > 1e-9, abs(k3Denominator) > 1e-9 else { return nil }
		let k2 = m1.cross(m4).dot(m3) / k2Denominator
		let k3 = m1.cross(m4).dot(m2) / k3Denominator
		let n2 = m2.scaled(by: k2).minus(m1)
		let n3 = m3.scaled(by: k3).minus(m1)

		var focal = Double(assumedFocalLengthFactor) * longSide
		let zz = n2.z * n3.z
		if abs(zz) > 1e-12 {
			let xTerm = n2.x * n3.x - (n2.x * n3.z + n2.z * n3.x) * u0 + zz * u0 * u0
			let yTerm = n2.y * n3.y - (n2.y * n3.z + n2.z * n3.y) * v0 + zz * v0 * v0
			let focalSquared = -(xTerm + yTerm) / zz
			// Accept only a physically plausible lens (roughly 15°–100° across the long side).
			if focalSquared > 0, case let estimate = focalSquared.squareRoot(),
			   estimate > 0.4 * longSide, estimate < 4 * longSide {
				focal = estimate
			}
		}
		// |A⁻¹ n|² with A the intrinsic matrix [[f, 0, u0], [0, f, v0], [0, 0, 1]].
		func metric(_ n: Vector3) -> Double {
			let a = (n.x - n.z * u0) / focal
			let b = (n.y - n.z * v0) / focal
			return a * a + b * b + n.z * n.z
		}
		let denominator = metric(n3)
		guard denominator > 0 else { return nil }
		let ratioSquared = metric(n2) / denominator
		guard ratioSquared.isFinite, ratioSquared > 0 else { return nil }
		let ratio = ratioSquared.squareRoot()
		guard ratio > 0.1, ratio < 10 else { return nil }
		return CGFloat(ratio)
	}

	/// Cleans a perspective-corrected page.
	///
	/// - Document: optional shadow removal (divides by a smooth illumination estimate, so uneven
	///   lighting flattens and the paper turns white), then a mild contrast lift and luminance
	///   sharpen. Colour is kept. Photos, charts and other large non-paper areas are bridged by the
	///   estimate rather than flattened.
	/// - Whiteboard: removes additive glare (light above the board's mean level), flattens the
	///   board to white by dividing by a heavily
	///   blurred copy (the paper-only illumination estimate below), then darkens faint ink with a
	///   gamma that keeps each marker's hue. With `keepMarkerColors` false the result is grayscale
	///   luminance with a stronger gamma and boosted contrast, so every marker colour reads dark
	///   while sticky notes stay light enough to read.
	static func clean(_ image: CIImage, mode: CaptureMode, removeShadows: Bool, keepMarkerColors: Bool) -> CIImage {
		let extent = image.extent
		guard !extent.isInfinite, extent.width >= 16, extent.height >= 16 else { return image }
		let source = atOrigin(image)
		let cleaned: CIImage
		switch mode {
		case .document:
			cleaned = cleanDocument(source, removeShadows: removeShadows)
		case .whiteboard:
			cleaned = cleanWhiteboard(source, keepMarkerColors: keepMarkerColors)
		}
		return clampedToUnit(cleaned).cropped(to: CGRect(origin: .zero, size: extent.size))
	}

	/// Scales `image` down (never up) so it is at most `maxWidth` pixels wide.
	static func limitWidth(_ image: CIImage, to maxWidth: CGFloat) -> CIImage {
		let width = image.extent.width
		guard !image.extent.isInfinite, maxWidth > 0, width > maxWidth else { return image }
		return scaled(image, by: maxWidth / width)
	}

	/// Scales `image` down (never up) so its longer side is at most `maxLength` pixels.
	static func limitLongSide(_ image: CIImage, to maxLength: CGFloat) -> CIImage {
		let longSide = max(image.extent.width, image.extent.height)
		guard !image.extent.isInfinite, maxLength > 0, longSide > maxLength else { return image }
		return scaled(image, by: maxLength / longSide)
	}
}

// MARK: - Recipes

extension PageCleanup {

	/// Numbers the recipes are tuned with. Sizes are fractions of the image's long side, so the
	/// recipes behave the same at any resolution; levels are in linear light.
	private enum Tuning {
		/// Long side, in pixels, the illumination estimate is computed at.
		static let illuminationWorkingSize: CGFloat = 512
		/// Square dilation that finds the local paper envelope.
		static let envelopeKernel: CGFloat = 0.03
		static let envelopeBlur: CGFloat = 0.015
		/// A pixel is paper when min-channel(pixel ÷ envelope) ramps across this range…
		static let paperRelativeLow: CGFloat = 0.6
		static let paperRelativeHigh: CGFloat = 0.8
		/// …and min-channel(envelope ÷ page mean) ramps across this one.
		static let paperAbsoluteLow: CGFloat = 0.15
		static let paperAbsoluteHigh: CGFloat = 0.35
		/// …and min-channel ÷ max-channel of (pixel ÷ page mean) ramps across this one.
		static let paperNeutralLow: CGFloat = 0.7
		static let paperNeutralHigh: CGFloat = 0.85
		/// Gaussian radius of the normalized convolution.
		static let illuminationBlur: CGFloat = 0.03
		static let illuminationEpsilon: CGFloat = 0.01
		/// Divided paper at or above this level becomes pure white.
		static let documentWhitePoint: CGFloat = 0.9
		static let documentContrast: Float = 1.06
		static let documentSaturation: Float = 1.0
		/// Pre-division noise reduction (division amplifies noise in shadowed areas).
		static let noiseLevel: Float = 0.01
		/// Illumination brighter than this multiple of the board's mean is treated as glare.
		static let glareThreshold: CGFloat = 1.0
		/// Divided board at or above this level becomes pure white.
		static let inkWhitePoint: CGFloat = 0.88
		/// Gamma (in linear light) that darkens faint or glare-washed strokes while keeping hue.
		static let inkGammaColor: Float = 1.5
		static let inkGammaGray: Float = 2.2
		static let markerSaturation: Float = 1.1
		static let grayContrast: Float = 1.1
	}

	private static func cleanDocument(_ image: CIImage, removeShadows: Bool) -> CIImage {
		var page = image
		if removeShadows {
			let quiet = denoised(image)
			let light = illumination(of: quiet)
			page = scaleLevels(divide(quiet, by: light), gain: 1 / Tuning.documentWhitePoint, bias: 0)
		}
		page = colorControls(page, contrast: Tuning.documentContrast, saturation: Tuning.documentSaturation)
		return sharpened(page)
	}

	private static func cleanWhiteboard(_ image: CIImage, keepMarkerColors: Bool) -> CIImage {
		let quiet = denoised(image)
		let light = illumination(of: quiet)
		// Glare is additive: whatever the illumination exceeds the board's level by is reflection.
		let boardLevel = constant(meanOf: light, scaledBy: Tuning.glareThreshold)
		let diffuseLight = minimum(light, boardLevel)
		let glare = subtract(diffuseLight, from: light)
		let deglared = subtract(glare, from: quiet)
		// ratio / whitePoint: the board clips to white and each marker keeps its colour relative to it.
		let flattened = clampedToUnit(scaleLevels(divide(deglared, by: diffuseLight), gain: 1 / Tuning.inkWhitePoint, bias: 0))
		guard keepMarkerColors else {
			let luminance = colorControls(flattened, contrast: 1, saturation: 0)
			return colorControls(gamma(luminance, power: Tuning.inkGammaGray), contrast: Tuning.grayContrast, saturation: 0)
		}
		let ink = gamma(flattened, power: Tuning.inkGammaColor)
		return colorControls(ink, contrast: 1, saturation: Tuning.markerSaturation)
	}

	/// A smooth estimate of the light falling on the page (the colour blank paper would have at each
	/// point), by normalized convolution over paper pixels only.
	///
	/// 1. The local bright envelope (dilate, then blur) approximates nearby paper.
	/// 2. A pixel counts as paper when every channel is close to that envelope (not ink, not a
	///    coloured figure) and the envelope is not far darker than the page's mean (not inside a
	///    large dark photo).
	/// 3. Light = blur(image · paper) ÷ blur(paper), so figures, photos and sticky notes are
	///    bridged from the paper around them instead of being mistaken for shadow.
	///
	/// Computed at `illuminationWorkingSize` and scaled back up, so it costs the same at any
	/// resolution.
	private static func illumination(of image: CIImage) -> CIImage {
		let extent = image.extent
		let longSide = max(extent.width, extent.height)
		let small = scaled(image, by: min(1, Tuning.illuminationWorkingSize / longSide))
		let frame = small.extent
		guard frame.width >= 1, frame.height >= 1 else { return image }
		let smallLongSide = max(frame.width, frame.height)

		let envelope = blurred(dilated(small, size: smallLongSide * Tuning.envelopeKernel), radius: smallLongSide * Tuning.envelopeBlur, in: frame)
		let pageLevel = constant(meanOf: envelope, scaledBy: 1)
		let nearEnvelope = ramp(minimumComponent(divide(small, by: envelope)), from: Tuning.paperRelativeLow, to: Tuning.paperRelativeHigh)
		let brightEnough = ramp(minimumComponent(divide(envelope, by: pageLevel)), from: Tuning.paperAbsoluteLow, to: Tuning.paperAbsoluteHigh)
		// Paper has the page's own tint: a bright yellow sun in a photo or a sticky note does not.
		let tint = divide(small, by: pageLevel)
		let neutral = ramp(divide(minimumComponent(tint), by: maximumComponent(tint)), from: Tuning.paperNeutralLow, to: Tuning.paperNeutralHigh)
		let paper = multiply(multiply(nearEnvelope, brightEnough), neutral)

		let radius = smallLongSide * Tuning.illuminationBlur
		let epsilon = Tuning.illuminationEpsilon
		// Mix in a little of the page level so regions with no paper nearby stay defined.
		let numerator = linearDodge(
			scaleLevels(blurred(multiply(small, paper), radius: radius, in: frame), gain: 1 - epsilon, bias: 0),
			scaleLevels(pageLevel, gain: epsilon, bias: 0)
		)
		let denominator = scaleLevels(blurred(paper, radius: radius, in: frame), gain: 1 - epsilon, bias: epsilon)
		let light = divide(numerator, by: denominator).cropped(to: frame)

		let upscale = CGAffineTransform(scaleX: extent.width / frame.width, y: extent.height / frame.height)
		return light.clampedToExtent().transformed(by: upscale).cropped(to: extent)
	}
}

// MARK: - Filter helpers

extension PageCleanup {

	/// A small 3-vector for the projective geometry in `estimatedAspectRatio`.
	private struct Vector3 {
		var x: Double
		var y: Double
		var z: Double

		func cross(_ other: Vector3) -> Vector3 {
			Vector3(x: y * other.z - z * other.y, y: z * other.x - x * other.z, z: x * other.y - y * other.x)
		}

		func dot(_ other: Vector3) -> Double {
			x * other.x + y * other.y + z * other.z
		}

		func scaled(by factor: Double) -> Vector3 {
			Vector3(x: x * factor, y: y * factor, z: z * factor)
		}

		func minus(_ other: Vector3) -> Vector3 {
			Vector3(x: x - other.x, y: y - other.y, z: z - other.z)
		}
	}

	/// Converts a normalized top-left-origin point to Core Image pixels (bottom-left origin).
	private static func ciPoint(_ point: CGPoint, size: CGSize) -> CGPoint {
		CGPoint(x: point.x * size.width, y: (1 - point.y) * size.height)
	}

	private static func atOrigin(_ image: CIImage) -> CIImage {
		let origin = image.extent.origin
		guard origin != .zero else { return image }
		return image.transformed(by: CGAffineTransform(translationX: -origin.x, y: -origin.y))
	}

	/// The smallest odd integer ≥ 3 at or above `length`.
	private static func oddPixels(_ length: CGFloat) -> Int {
		let rounded = max(3, Int(length.rounded(.up)))
		return rounded.isMultiple(of: 2) ? rounded + 1 : rounded
	}

	/// Lanczos resample of `image` by `scale`, cropped to whole pixels at the origin.
	private static func scaled(_ image: CIImage, by scale: CGFloat) -> CIImage {
		let source = atOrigin(image)
		guard scale > 0, abs(scale - 1) > 1e-6 else { return source }
		let size = source.extent.size
		let target = CGRect(
			x: 0,
			y: 0,
			width: max(1, (size.width * scale).rounded(.down)),
			height: max(1, (size.height * scale).rounded(.down))
		)
		let lanczos = CIFilter.lanczosScaleTransform()
		lanczos.inputImage = source.clampedToExtent()
		lanczos.scale = Float(target.height / size.height)
		lanczos.aspectRatio = Float((target.width / size.width) / (target.height / size.height))
		guard let output = lanczos.outputImage else {
			return source.transformed(by: CGAffineTransform(scaleX: scale, y: scale)).cropped(to: target)
		}
		return output.cropped(to: target)
	}

	/// `numerator / denominator` per channel (Core Image clamps the result to 1).
	private static func divide(_ numerator: CIImage, by denominator: CIImage) -> CIImage {
		let filter = CIFilter.divideBlendMode()
		filter.inputImage = denominator
		filter.backgroundImage = numerator
		return filter.outputImage ?? numerator
	}

	/// `minuend − subtrahend` per channel (Core Image clamps the result to 0).
	private static func subtract(_ subtrahend: CIImage, from minuend: CIImage) -> CIImage {
		let filter = CIFilter.subtractBlendMode()
		filter.inputImage = subtrahend
		filter.backgroundImage = minuend
		return filter.outputImage ?? minuend
	}

	/// `a · b` per channel.
	private static func multiply(_ a: CIImage, _ b: CIImage) -> CIImage {
		let filter = CIFilter.multiplyCompositing()
		filter.inputImage = b
		filter.backgroundImage = a
		return filter.outputImage?.cropped(to: a.extent) ?? a
	}

	/// `a + b` per channel with alpha composited normally (unlike `CIAdditionCompositing`,
	/// which adds alpha too and corrupts opaque images).
	private static func linearDodge(_ a: CIImage, _ b: CIImage) -> CIImage {
		let filter = CIFilter.linearDodgeBlendMode()
		filter.inputImage = b
		filter.backgroundImage = a
		return filter.outputImage?.cropped(to: a.extent) ?? a
	}

	/// Square grayscale dilation (local maximum) of side `size` pixels, rounded to odd.
	private static func dilated(_ image: CIImage, size: CGFloat) -> CIImage {
		let filter = CIFilter.morphologyRectangleMaximum()
		filter.inputImage = image.clampedToExtent()
		filter.width = Float(oddPixels(size))
		filter.height = Float(oddPixels(size))
		return filter.outputImage?.cropped(to: image.extent) ?? image
	}

	/// Gaussian blur with edge pixels extended, so borders do not fade toward transparent black.
	private static func blurred(_ image: CIImage, radius: CGFloat, in frame: CGRect) -> CIImage {
		let filter = CIFilter.gaussianBlur()
		filter.inputImage = image.clampedToExtent()
		filter.radius = Float(max(0.5, radius))
		return filter.outputImage?.cropped(to: frame) ?? image
	}

	/// Linear 0→1 ramp of the (gray) input between `low` and `high`, clamped.
	private static func ramp(_ image: CIImage, from low: CGFloat, to high: CGFloat) -> CIImage {
		let gain = 1 / max(1e-3, high - low)
		return clampedToUnit(scaleLevels(image, gain: gain, bias: -low * gain))
	}

	private static func minimum(_ a: CIImage, _ b: CIImage) -> CIImage {
		let filter = CIFilter.minimumCompositing()
		filter.inputImage = a
		filter.backgroundImage = b
		return filter.outputImage?.cropped(to: a.extent) ?? a
	}

	/// An infinite constant image: the mean colour of `image` times `factor` (alpha 1).
	private static func constant(meanOf image: CIImage, scaledBy factor: CGFloat) -> CIImage {
		let average = CIFilter.areaAverage()
		average.inputImage = image
		average.extent = image.extent
		guard let mean = average.outputImage else { return image }
		return scaleLevels(mean.clampedToExtent(), gain: factor, bias: 0)
	}

	/// `out = in · gain + bias` on RGB; alpha untouched.
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

	private static func colorControls(_ image: CIImage, contrast: Float, saturation: Float) -> CIImage {
		let filter = CIFilter.colorControls()
		filter.inputImage = image
		filter.contrast = contrast
		filter.saturation = saturation
		filter.brightness = 0
		return filter.outputImage ?? image
	}

	/// Gray image of `max(r, g, b)`.
	private static func maximumComponent(_ image: CIImage) -> CIImage {
		let filter = CIFilter.maximumComponent()
		filter.inputImage = image
		return filter.outputImage ?? image
	}

	/// Gray image of `min(r, g, b)`.
	private static func minimumComponent(_ image: CIImage) -> CIImage {
		let filter = CIFilter.minimumComponent()
		filter.inputImage = image
		return filter.outputImage ?? image
	}

	/// `in^power` per channel (in linear light, so `power > 1` darkens mid-tones).
	private static func gamma(_ image: CIImage, power: Float) -> CIImage {
		let filter = CIFilter.gammaAdjust()
		filter.inputImage = image
		filter.power = power
		return filter.outputImage ?? image
	}

	private static func denoised(_ image: CIImage) -> CIImage {
		let filter = CIFilter.noiseReduction()
		filter.inputImage = image
		filter.noiseLevel = Tuning.noiseLevel
		filter.sharpness = 0
		return filter.outputImage?.cropped(to: image.extent) ?? image
	}

	private static func sharpened(_ image: CIImage) -> CIImage {
		let filter = CIFilter.sharpenLuminance()
		filter.inputImage = image
		filter.sharpness = 0.4
		filter.radius = 1.5
		return filter.outputImage ?? image
	}
}
