//
//  Metrics.swift
//  GlareFusion harness (macOS only)
//
//  OCR accuracy, pixel error against a glare-free photo, registration error against the true
//  geometry, and PNG output.
//

import CoreGraphics
import CoreImage
import CoreText
import Foundation
import ImageIO
import Vision

// MARK: - OCR

/// Reads a cleaned page with Vision, as the app's OCR does, and scores it per printed line.
enum OCR {
	/// Recognized text lines, top candidate each.
	static func recognize(_ image: CGImage) throws -> [String] {
		let request = VNRecognizeTextRequest()
		request.recognitionLevel = .accurate
		request.usesLanguageCorrection = true
		request.recognitionLanguages = ["en-US"]
		try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
		return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
	}

	/// Character accuracy (1 − edit distance ÷ length) of `truth` against its best-matching line.
	static func accuracy(of truth: String, among recognized: [String]) -> Double {
		let target = Array(normalized(truth))
		guard !target.isEmpty else { return 1 }
		let best = recognized.reduce(Int.max) { min($0, editDistance(target, Array(normalized($1)))) }
		return max(0, 1 - Double(best) / Double(target.count))
	}

	private static func normalized(_ text: String) -> String {
		text.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
	}

	/// Levenshtein distance with two rows.
	static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
		guard !a.isEmpty else { return b.count }
		guard !b.isEmpty else { return a.count }
		var previous = Array(0...b.count)
		var current = [Int](repeating: 0, count: b.count + 1)
		for i in 1...a.count {
			current[0] = i
			for j in 1...b.count {
				let substitution = previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
				current[j] = min(previous[j] + 1, current[j - 1] + 1, substitution)
			}
			swap(&previous, &current)
		}
		return previous[b.count]
	}
}

/// OCR results for one output.
struct OCRScore {
	/// Mean character accuracy over every printed line.
	var all: Double
	/// Mean character accuracy over the lines under the reference's glare.
	var glareLines: Double
	/// Lines under the glare read with at least 98% accuracy, and how many there are.
	var glareLinesRead: Int
	var glareLineCount: Int
}

// MARK: - Pixels

/// Rendering, error measures and image output.
struct Lab {
	let context: CIContext

	/// Renders `image` (extent at the origin) as an 8-bit sRGB `CGImage`.
	func cgImage(_ image: CIImage) throws -> CGImage {
		let rect = image.extent.integral
		guard let space = CGColorSpace(name: CGColorSpace.sRGB),
			  let rendered = context.createCGImage(image, from: rect, format: .RGBA8, colorSpace: space) else {
			throw HarnessError("Render failed.")
		}
		return rendered
	}

	/// Renders once and wraps the pixels again, as the app would before cleanup.
	func materialized(_ image: CIImage) throws -> CIImage {
		CIImage(cgImage: try cgImage(image))
	}

	/// Linear luminance of `image`.
	func luminance(_ image: CIImage) throws -> Plane {
		guard let channels = GlareFusion.renderPlanes(image, bounds: image.extent.integral, context: context) else {
			throw HarnessError("Plane render failed.")
		}
		return Plane.luminance(channels, gain: SIMD3(repeating: 1))
	}

	/// 1 where `glary` is brighter than `clean` by more than `threshold` (linear), else 0.
	func glareZone(glary: CIImage, clean: CIImage, threshold: Float = 0.03) throws -> Plane {
		let a = try luminance(glary)
		let b = try luminance(clean)
		return a.subtracting(b).indicator(atLeast: threshold)
	}

	/// Root-mean-square difference of sRGB-encoded luminance (0–255 levels), over the whole page
	/// and over `zone`.
	func rmse(_ image: CIImage, _ reference: CIImage, zone: Plane) throws -> (page: Double, zone: Double) {
		let a = try luminance(image)
		let b = try luminance(reference)
		guard a.width == b.width, a.height == b.height, zone.values.count == a.values.count else {
			throw HarnessError("Size mismatch: \(a.width)×\(a.height) vs \(b.width)×\(b.height), zone \(zone.width)×\(zone.height).")
		}
		var pageSum = 0.0
		var zoneSum = 0.0
		var zoneCount = 0.0
		for index in a.values.indices {
			let difference = 255 * Double(encode(a.values[index]) - encode(b.values[index]))
			pageSum += difference * difference
			if zone.values[index] > 0.5 {
				zoneSum += difference * difference
				zoneCount += 1
			}
		}
		return ((pageSum / Double(a.values.count)).squareRoot(), zoneCount > 0 ? (zoneSum / zoneCount).squareRoot() : 0)
	}

	private func encode(_ linear: Float) -> Float {
		let value = min(max(linear, 0), 1)
		return value <= 0.0031308 ? value * 12.92 : 1.055 * pow(value, 1 / 2.4) - 0.055
	}

	/// Writes `image` as a PNG, scaled down to at most `maxSide` pixels on its long side.
	func write(_ image: CIImage, to url: URL, maxSide: CGFloat = 1400) throws {
		let small = PageCleanup.limitLongSide(GlareFusion.atOrigin(image), to: maxSide)
		try writePNG(try cgImage(small), to: url)
	}

	func writePNG(_ image: CGImage, to url: URL) throws {
		guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
			throw HarnessError("Cannot write \(url.path).")
		}
		CGImageDestinationAddImage(destination, image, nil)
		guard CGImageDestinationFinalize(destination) else { throw HarnessError("Cannot finish \(url.path).") }
	}

	/// Crops of the same page region (`crop` is normalized, top-left origin) from several outputs
	/// side by side, each labelled; every panel is `panelWidth` pixels wide. `pageAspect` is the
	/// page's height ÷ width.
	func strip(_ panels: [(label: String, image: CIImage)], crop: CGRect, pageAspect: CGFloat, panelWidth: Int) throws -> CGImage {
		let panelHeight = Int((CGFloat(panelWidth) * crop.height / crop.width * pageAspect).rounded())
		let labelHeight = 44
		let gap = 12
		let width = panels.count * panelWidth + (panels.count - 1) * gap
		guard let space = CGColorSpace(name: CGColorSpace.sRGB),
			  let canvas = CGContext(data: nil, width: width, height: panelHeight + labelHeight, bitsPerComponent: 8, bytesPerRow: 0,
									 space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
			throw HarnessError("Strip canvas failed.")
		}
		canvas.setFillColor(CGColor(srgbRed: 0.12, green: 0.13, blue: 0.17, alpha: 1))
		canvas.fill(CGRect(x: 0, y: 0, width: width, height: panelHeight + labelHeight))
		for (index, panel) in panels.enumerated() {
			let image = GlareFusion.atOrigin(panel.image)
			let size = image.extent.size
			let region = CGRect(x: crop.minX * size.width, y: (1 - crop.maxY) * size.height, width: crop.width * size.width, height: crop.height * size.height)
			let scale = CGFloat(panelWidth) / region.width
			let resized = image.cropped(to: region)
				.transformed(by: CGAffineTransform(translationX: -region.minX, y: -region.minY))
				.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
			let height = min(panelHeight, Int((region.height * scale).rounded(.down)))
			let x = index * (panelWidth + gap)
			canvas.draw(try cgImage(resized.cropped(to: CGRect(x: 0, y: 0, width: panelWidth, height: height))),
						in: CGRect(x: x, y: panelHeight - height, width: panelWidth, height: height))
			label(canvas, panel.label, x: CGFloat(x + 10), y: CGFloat(panelHeight + 12))
		}
		guard let image = canvas.makeImage() else { throw HarnessError("Strip finish failed.") }
		return image
	}

	private func label(_ canvas: CGContext, _ text: String, x: CGFloat, y: CGFloat) {
		let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 24, nil)
		let attributes: [NSAttributedString.Key: Any] = [
			NSAttributedString.Key(kCTFontAttributeName as String): font,
			NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(srgbRed: 0.96, green: 0.94, blue: 0.88, alpha: 1),
		]
		let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
		canvas.textPosition = CGPoint(x: x, y: y)
		CTLineDraw(line, canvas)
	}
}

// MARK: - Registration error

/// How far each fused frame's page lands from where it truly belongs, in output pixels.
enum RegistrationError {
	/// Mean and maximum error over a 7 × 7 grid of the page, for every non-reference layer.
	static func measure(_ stack: GlareFusion.AlignedStack, shots: [Shot]) -> [(index: Int, mean: Double, max: Double)] {
		guard let reference = stack.layers.first, let toReference = reference.homography.inverse,
			  let referenceShot = shots.first, let imageToPage = referenceShot.pageToImage.inverse else { return [] }
		var results: [(index: Int, mean: Double, max: Double)] = []
		for layer in stack.layers.dropFirst() where layer.report.index < shots.count {
			let shot = shots[layer.report.index]
			var sum = 0.0
			var worst = 0.0
			var count = 0.0
			for row in 1...7 {
				for column in 1...7 {
					let point = CGPoint(x: stack.pageSize.width * CGFloat(column) / 8, y: stack.pageSize.height * CGFloat(row) / 8)
					guard let inReference = toReference.apply(point), let onPage = imageToPage.apply(inReference),
						  let inFrame = shot.pageToImage.apply(onPage), let landed = layer.homography.apply(inFrame) else { continue }
					let error = Double(hypot(landed.x - point.x, landed.y - point.y))
					sum += error
					worst = max(worst, error)
					count += 1
				}
			}
			results.append((layer.report.index, count > 0 ? sum / count : .infinity, worst))
		}
		return results
	}
}
