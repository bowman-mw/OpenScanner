//
//  Scene.swift
//  GlareFusion harness (macOS only)
//
//  A synthetic glossy page photographed from several camera positions: a letter page with text,
//  a chart and a photo, lit by a ceiling lamp whose mirror image (the glare) moves over the page
//  as the camera moves, rendered as 12 MP 8-bit photos with exposure changes, blur and noise.
//

import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreText
import Foundation
import simd

// MARK: - HarnessError

/// A harness failure, reported instead of trapping.
struct HarnessError: Error, CustomStringConvertible {
	let description: String
	init(_ description: String) { self.description = description }
}

// MARK: - FlatPage

/// One line of text on the flat page, for OCR scoring.
struct PageLine {
	let text: String
	/// Page pixels, top-left origin.
	let rect: CGRect
}

/// The page as printed: its pixels, physical size and text.
struct FlatPage {
	/// Page pixels, extent at the origin (sRGB content).
	let image: CIImage
	let size: CGSize
	/// Physical size in metres (US letter).
	let metres = CGSize(width: 0.2159, height: 0.2794)
	let lines: [PageLine]

	/// Page pixel (top-left origin) → world point on the table (metres, z = 0).
	func world(_ point: CGPoint) -> SIMD3<Double> {
		SIMD3(
			(Double(point.x / size.width) - 0.5) * Double(metres.width),
			(Double(point.y / size.height) - 0.5) * Double(metres.height),
			0
		)
	}

	/// World point on the table → page pixel (top-left origin).
	func pagePoint(_ world: SIMD3<Double>) -> CGPoint {
		CGPoint(
			x: (world.x / Double(metres.width) + 0.5) * Double(size.width),
			y: (world.y / Double(metres.height) + 0.5) * Double(size.height)
		)
	}
}

/// Draws the test page at 240 dpi (2040 × 2640 px).
enum PageArt {
	static let bodySentences = [
		"Moss grows slowly on the north side of every stone wall we measured.",
		"The creek ran higher this spring than in any year since the survey.",
		"Seedlings in plot four doubled while plot six stayed nearly bare.",
		"Volunteers logged two hundred hours of careful trail maintenance.",
		"Next season we plan to extend the transect past the old orchard.",
		"Bracken fronds unrolled three weeks earlier than the long average.",
		"Soil samples from the ridge held twice the moisture of the valley.",
		"A pair of herons nested in the alders beside the lower footbridge.",
		"We replaced nine rotten boardwalk planks near the marsh outflow.",
		"Lichen cover on the granite boulders grew by roughly eight percent.",
		"Maidenhair ferns returned to the shaded ravine after a long absence.",
		"Rainfall in April totalled 141 millimetres across the three gauges.",
		"The north meadow was mowed once in July to slow the invasive thistle.",
		"Students from the high school mapped every spring along the ridge.",
		"Deer browsing was heavy on young oaks outside the fenced enclosure.",
		"Trail counters recorded 3,280 visitors between May and September.",
	]
	static let smallPrint = [
		"Survey method: fixed quadrats of one square metre, read every fortnight.",
		"Plot coordinates are held by the trust and shared on written request.",
		"Figures are provisional until the autumn audit is complete and signed.",
		"Contact the field office about access to the restricted upper slopes.",
	]

	/// The page and its text lines.
	static func makePage() throws -> FlatPage {
		let width = 2040
		let height = 2640
		guard let space = CGColorSpace(name: CGColorSpace.sRGB),
			  let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
									  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
			throw HarnessError("Could not create the page bitmap.")
		}
		context.translateBy(x: 0, y: CGFloat(height))
		context.scaleBy(x: 1, y: -1)
		context.setFillColor(rgb(0.96, 0.95, 0.92))
		context.fill(CGRect(x: 0, y: 0, width: width, height: height))
		var lines: [PageLine] = []
		lines.append(drawText(context, "Field Survey Spring Report", x: 170, baseline: 250, size: 66, font: "Helvetica-Bold"))
		var baseline: CGFloat = 380
		for sentence in bodySentences {
			lines.append(drawText(context, sentence, x: 170, baseline: baseline, size: 37, font: "Helvetica"))
			baseline += 58
		}
		drawFigures(context, top: baseline + 20)
		baseline += 20 + 545 + 90
		for sentence in smallPrint {
			lines.append(drawText(context, sentence, x: 170, baseline: baseline, size: 27, font: "Helvetica"))
			baseline += 42
		}
		guard let image = context.makeImage() else { throw HarnessError("Could not finish the page bitmap.") }
		return FlatPage(image: CIImage(cgImage: image), size: CGSize(width: width, height: height), lines: lines)
	}

	/// A bar chart and a dark "photo" block side by side, `top` pixels down.
	private static func drawFigures(_ context: CGContext, top: CGFloat) {
		let colors = [rgb(0.20, 0.42, 0.78), rgb(0.93, 0.55, 0.15), rgb(0.25, 0.62, 0.35), rgb(0.80, 0.20, 0.25)]
		let heights: [CGFloat] = [330, 470, 230, 400]
		for (index, barHeight) in heights.enumerated() {
			context.setFillColor(colors[index])
			context.fill(CGRect(x: 230 + CGFloat(index) * 160, y: top + 540 - barHeight, width: 110, height: barHeight))
		}
		context.setStrokeColor(rgb(0.2, 0.2, 0.2))
		context.setLineWidth(5)
		context.stroke(CGRect(x: 190, y: top, width: 700, height: 545))
		context.setFillColor(rgb(0.14, 0.18, 0.22))
		context.fill(CGRect(x: 1000, y: top, width: 870, height: 545))
		context.setFillColor(rgb(0.85, 0.80, 0.55))
		context.fillEllipse(in: CGRect(x: 1560, y: top + 60, width: 140, height: 140))
		context.setFillColor(rgb(0.30, 0.42, 0.30))
		context.fill(CGRect(x: 1000, y: top + 380, width: 870, height: 165))
	}

	private static func drawText(_ context: CGContext, _ text: String, x: CGFloat, baseline: CGFloat, size: CGFloat, font: String) -> PageLine {
		let ctFont = CTFontCreateWithName(font as CFString, size, nil)
		let attributes: [NSAttributedString.Key: Any] = [
			NSAttributedString.Key(kCTFontAttributeName as String): ctFont,
			NSAttributedString.Key(kCTForegroundColorAttributeName as String): rgb(0.11, 0.11, 0.13),
		]
		let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
		context.saveGState()
		context.textMatrix = .identity
		context.translateBy(x: x, y: baseline)
		context.scaleBy(x: 1, y: -1)
		context.textPosition = .zero
		CTLineDraw(line, context)
		context.restoreGState()
		let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
		return PageLine(text: text, rect: CGRect(x: x, y: baseline - size, width: width, height: size * 1.25))
	}

	static func rgb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> CGColor {
		CGColor(srgbRed: red, green: green, blue: blue, alpha: 1)
	}
}

// MARK: - Camera

/// Where the phone is: position and aim in table coordinates (metres; x right, y toward the
/// page's bottom edge, z into the table, so the phone is at negative z).
struct CameraPose {
	var position: SIMD3<Double>
	var target: SIMD3<Double>
	/// Rotation about the optical axis, radians.
	var roll: Double = 0

	/// The angle between the optical axis and the page's normal, degrees.
	var tiltDegrees: Double {
		let forward = simd_normalize(target - position)
		return acos(min(1, abs(forward.z))) * 180 / .pi
	}
}

/// A pinhole camera producing upright portrait 12 MP photos.
struct Camera {
	let imageSize = CGSize(width: 3024, height: 4032)
	/// Focal length in pixels (an iPhone main camera is ≈ 0.8 × the long side).
	let focal: Double = 0.8 * 4032

	/// World point → image pixel (top-left origin), or nil behind the camera.
	func project(_ point: SIMD3<Double>, pose: CameraPose) -> CGPoint? {
		let forward = simd_normalize(pose.target - pose.position)
		let right0 = simd_normalize(simd_cross(SIMD3(0, 1, 0), forward))
		let down0 = simd_cross(forward, right0)
		let right = right0 * cos(pose.roll) + down0 * sin(pose.roll)
		let down = down0 * cos(pose.roll) - right0 * sin(pose.roll)
		let relative = point - pose.position
		let depth = simd_dot(relative, forward)
		guard depth > 1e-6 else { return nil }
		return CGPoint(
			x: focal * simd_dot(relative, right) / depth + Double(imageSize.width) / 2,
			y: focal * simd_dot(relative, down) / depth + Double(imageSize.height) / 2
		)
	}
}

// MARK: - Shot

/// Everything that differs between two photos of the page.
struct ShotSettings {
	var pose: CameraPose
	/// Auto-exposure gain and white balance, per channel.
	var exposure = SIMD3<Double>(1, 1, 1)
	/// Peak added light of the glare's core; 0 for a matte page.
	var glareStrength: Double = 1.6
	/// A soft shadow of the phone on the page: centre (page px, top-left) and darkening (0–1).
	var shadow: (center: CGPoint, depth: Double)?
	/// Shifts the noise pattern so each photo's noise is independent.
	var noiseSeed: CGFloat = 0
	/// Gaussian blur in photo pixels: lens and processing (0.7), or a shot taken while moving.
	var blur: Double = 0.7
}

/// One rendered photo and its ground truth.
struct Shot {
	/// The photo as an 8-bit sRGB image, as a still would decode.
	let image: CIImage
	/// The page's true outline in the photo (normalized, top-left origin).
	let quad: PageQuad
	/// Flat page pixels (Core Image coordinates) → photo pixels (Core Image coordinates).
	let pageToImage: Homography
	/// Where the glare's centre sits on the page (page pixels, top-left origin).
	let glareCenter: CGPoint
}

/// Renders photos of a page.
struct Studio {
	let page: FlatPage
	let camera = Camera()
	/// The ceiling lamp, metres (above the page: negative z).
	var lamp = SIMD3<Double>(-0.295, -0.331, -1.6)
	/// Radius of the glare's bright core on the page, metres.
	var glareRadius = 0.028
	let context: CIContext

	/// The specular point: where the lamp's mirror image lines up with the lens.
	func glarePoint(for pose: CameraPose) -> SIMD3<Double> {
		let mirrored = SIMD3(lamp.x, lamp.y, -lamp.z)
		let t = -pose.position.z / (mirrored.z - pose.position.z)
		return pose.position + (mirrored - pose.position) * t
	}

	/// Renders one photo.
	func shoot(_ settings: ShotSettings) throws -> Shot {
		let corners = [CGPoint(x: 0, y: 0), CGPoint(x: page.size.width, y: 0), CGPoint(x: page.size.width, y: page.size.height), CGPoint(x: 0, y: page.size.height)]
		let projected = try corners.map { corner -> CGPoint in
			guard let point = camera.project(page.world(corner), pose: settings.pose) else { throw HarnessError("Page corner behind the camera.") }
			return point
		}
		let imageHeight = camera.imageSize.height
		let pageCI = corners.map { CGPoint(x: $0.x, y: page.size.height - $0.y) }
		let imageCI = projected.map { CGPoint(x: $0.x, y: imageHeight - $0.y) }
		guard let pageToImage = Homography(from: pageCI, to: imageCI),
			  let quad = PageQuad(unordered: projected.map { CGPoint(x: $0.x / camera.imageSize.width, y: $0.y / imageHeight) }) else {
			throw HarnessError("Degenerate projection.")
		}
		let glareCenter = page.pagePoint(glarePoint(for: settings.pose))
		let litPage = try lightPage(settings, glareCenter: glareCenter)
		let photo = try develop(litPage, corners: imageCI, settings: settings)
		return Shot(image: photo, quad: quad, pageToImage: pageToImage, glareCenter: glareCenter)
	}

	/// The page in page space: albedo × light (+ shadow) + glare, in linear light.
	private func lightPage(_ settings: ShotSettings, glareCenter: CGPoint) throws -> CIImage {
		let rect = CGRect(origin: .zero, size: page.size)
		let light = CIFilter.linearGradient()
		light.point0 = CGPoint(x: 0, y: 0)
		light.point1 = CGPoint(x: page.size.width * 0.6, y: page.size.height)
		light.color0 = linearColor(0.62, 0.62, 0.60)
		light.color1 = linearColor(0.80, 0.79, 0.76)
		guard var lit = light.outputImage.map({ multiply(page.image, $0) }) else { throw HarnessError("Light gradient failed.") }
		if let shadow = settings.shadow {
			lit = multiply(lit, radial(center: CGPoint(x: shadow.center.x, y: page.size.height - shadow.center.y),
										inner: 1 - shadow.depth, outer: 1, r0: 120, r1: 520))
		}
		guard settings.glareStrength > 0 else { return lit.cropped(to: rect) }
		let center = CGPoint(x: glareCenter.x, y: page.size.height - glareCenter.y)
		let pixels = glareRadius / Double(page.metres.width) * Double(page.size.width)
		let core = scaled(radial(center: center, inner: 1, outer: 0, r0: CGFloat(pixels * 0.35), r1: CGFloat(pixels)), by: settings.glareStrength)
		let sheen = scaled(radial(center: center, inner: 1, outer: 0, r0: 0, r1: CGFloat(pixels * 3.2)), by: 0.10)
		return add(add(lit, core), sheen).cropped(to: rect)
	}

	/// Projects the lit page into a photo over a desk, then exposure, blur, noise and 8-bit sRGB.
	private func develop(_ litPage: CIImage, corners: [CGPoint], settings: ShotSettings) throws -> CIImage {
		let frame = CGRect(origin: .zero, size: camera.imageSize)
		let warp = CIFilter.perspectiveTransform()
		warp.inputImage = litPage
		warp.topLeft = corners[0]
		warp.topRight = corners[1]
		warp.bottomRight = corners[2]
		warp.bottomLeft = corners[3]
		guard let projected = warp.outputImage else { throw HarnessError("Projection failed.") }
		let scene = projected.composited(over: desk(frame))
		let exposed = channelGains(scene, settings.exposure).applyingGaussianBlur(sigma: settings.blur).cropped(to: frame)
		guard let random = CIFilter.randomGenerator().outputImage else { throw HarnessError("Noise failed.") }
		let noise = random.transformed(by: CGAffineTransform(translationX: settings.noiseSeed * 97, y: settings.noiseSeed * 61))
		let grain = levels(noise.applyingGaussianBlur(sigma: 0.6), gain: 0.05, bias: 0.975)
		let noisy = multiply(exposed, grain).cropped(to: frame)
		guard let space = CGColorSpace(name: CGColorSpace.sRGB),
			  let rendered = context.createCGImage(noisy, from: frame, format: .RGBA8, colorSpace: space) else {
			throw HarnessError("Photo render failed.")
		}
		return CIImage(cgImage: rendered)
	}

	private func desk(_ frame: CGRect) -> CIImage {
		let stripes = CIFilter.stripesGenerator()
		stripes.width = 41
		stripes.sharpness = 0.1
		stripes.color0 = CIColor(red: 0.20, green: 0.14, blue: 0.09)
		stripes.color1 = CIColor(red: 0.15, green: 0.10, blue: 0.07)
		let base = CIImage(color: CIColor(red: 0.17, green: 0.12, blue: 0.08))
		let grain = stripes.outputImage?.transformed(by: CGAffineTransform(rotationAngle: 0.08)).applyingGaussianBlur(sigma: 5)
		return (grain ?? base).cropped(to: frame)
	}
}

// MARK: - Filter helpers

func multiply(_ a: CIImage, _ b: CIImage) -> CIImage {
	let filter = CIFilter.multiplyCompositing()
	filter.inputImage = b
	filter.backgroundImage = a
	return filter.outputImage?.cropped(to: a.extent) ?? a
}

func add(_ a: CIImage, _ b: CIImage) -> CIImage {
	let filter = CIFilter.linearDodgeBlendMode()
	filter.inputImage = b
	filter.backgroundImage = a
	return filter.outputImage?.cropped(to: a.extent) ?? a
}

func levels(_ image: CIImage, gain: CGFloat, bias: CGFloat) -> CIImage {
	let filter = CIFilter.colorMatrix()
	filter.inputImage = image
	filter.rVector = CIVector(x: gain, y: 0, z: 0, w: 0)
	filter.gVector = CIVector(x: gain, y: 0, z: 0, w: 0)
	filter.bVector = CIVector(x: gain, y: 0, z: 0, w: 0)
	filter.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
	filter.biasVector = CIVector(x: bias, y: bias, z: bias, w: 1)
	return filter.outputImage ?? image
}

func scaled(_ image: CIImage, by factor: Double) -> CIImage {
	channelGains(image, SIMD3(repeating: factor))
}

func channelGains(_ image: CIImage, _ gain: SIMD3<Double>) -> CIImage {
	let filter = CIFilter.colorMatrix()
	filter.inputImage = image
	filter.rVector = CIVector(x: gain.x, y: 0, z: 0, w: 0)
	filter.gVector = CIVector(x: 0, y: gain.y, z: 0, w: 0)
	filter.bVector = CIVector(x: 0, y: 0, z: gain.z, w: 0)
	filter.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
	return filter.outputImage ?? image
}

/// A radial ramp from `inner` (inside `r0`) to `outer` (beyond `r1`), grey, opaque.
func radial(center: CGPoint, inner: Double, outer: Double, r0: CGFloat, r1: CGFloat) -> CIImage {
	let filter = CIFilter.radialGradient()
	filter.center = center
	filter.radius0 = Float(r0)
	filter.radius1 = Float(r1)
	filter.color0 = linearColor(inner, inner, inner)
	filter.color1 = linearColor(outer, outer, outer)
	return filter.outputImage ?? CIImage(color: linearColor(outer, outer, outer))
}

/// A colour given in linear light (so gradients ramp linearly in Core Image's working space).
func linearColor(_ red: Double, _ green: Double, _ blue: Double) -> CIColor {
	guard let space = CGColorSpace(name: CGColorSpace.linearSRGB),
		  let color = CIColor(red: red, green: green, blue: blue, colorSpace: space) else {
		return CIColor(red: red, green: green, blue: blue)
	}
	return color
}
