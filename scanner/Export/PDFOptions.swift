//
//  PDFOptions.swift
//  Rescriva (fork of Open Scanner)
//
//  The searchable PDF's options: paper size, image quality and an optional
//  password, with the page layout and page-image encoding they imply. Export
//  remembers the paper and quality (stored tokens); the password lives only
//  as long as the sheet and is never stored or logged.
//

import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The paper the PDF's pages are on. Stored token (`RescrivaPreference.pdfPaperSize`).
enum PDFPaperSize: String, CaseIterable, Identifiable {
	/// Each page the shape of its image, 612 pt across (792 when wide): the scan as it is.
	case pageSize = "page"
	case a4
	case letter

	var id: String { rawValue }

	var label: LocalizedStringKey {
		switch self {
		case .pageSize: return "Page size"
		case .a4: return "A4"
		case .letter: return "Letter"
		}
	}

	/// The sheet upright, in points; nil when each page takes its image's shape.
	var portraitSize: CGSize? {
		switch self {
		case .pageSize: return nil
		case .a4: return CGSize(width: 595.28, height: 841.89)
		case .letter: return CGSize(width: 612, height: 792)
		}
	}
}

/// How large and how compressed the page images are. Stored token (`RescrivaPreference.pdfImageQuality`).
enum PDFImageQuality: String, CaseIterable, Identifiable {
	case high, medium, small

	var id: String { rawValue }

	var label: LocalizedStringKey {
		switch self {
		case .high: return "High"
		case .medium: return "Medium"
		case .small: return "Small"
		}
	}

	/// The longest side a page image keeps, in pixels (smaller images are never enlarged).
	var maxPixels: CGFloat {
		switch self {
		case .high: return 2400
		case .medium: return 1800
		case .small: return 1200
		}
	}

	/// JPEG quality, 0–1.
	var jpegQuality: CGFloat {
		switch self {
		case .high: return 0.8
		case .medium: return 0.7
		case .small: return 0.6
		}
	}
}

/// What Export chose for a PDF. The description never shows the password, so the options can't
/// leak it into a log by accident.
struct PDFExportOptions: CustomStringConvertible {
	var paperSize: PDFPaperSize = .pageSize
	var quality: PDFImageQuality = .high
	/// Needed to open the file (and to change its permissions); nil or empty for none.
	var password: String?

	/// The password to encrypt with, when there is one.
	var encryptionPassword: String? {
		guard let password, !password.isEmpty else { return nil }
		return password
	}

	var description: String {
		"PDFExportOptions(paper: \(paperSize.rawValue), quality: \(quality.rawValue), password: \(encryptionPassword == nil ? "none" : "set"))"
	}
}

/// Where a PDF page and its image sit, in points with a top-left origin (as UIKit draws). The
/// image rect is the one place the image, its invisible text layer and its notes are all drawn.
struct PDFPageLayout: Equatable {
	/// Space kept around the image on A4 and Letter.
	static let margin: CGFloat = 18
	/// Width ÷ height assumed for an image with no usable size (US Letter's).
	static let fallbackAspect: CGFloat = 0.773

	var pageRect: CGRect
	var imageRect: CGRect

	/// Lays out an image of `aspect` (width ÷ height) on `paper`. With `.pageSize` the page is the
	/// image's shape, 612 pt across (792 when wide), as Rescriva's PDFs always were. On A4 and Letter
	/// the sheet turns to the image's orientation and the image is fitted inside the margin, centred.
	static func fitting(aspect: CGFloat, on paper: PDFPaperSize) -> PDFPageLayout {
		let usable = aspect.isFinite && aspect > 0 ? aspect : fallbackAspect
		let shape = min(max(usable, 0.1), 10)
		guard let portrait = paper.portraitSize else {
			let width: CGFloat = shape > 1 ? 792 : 612
			let page = CGRect(x: 0, y: 0, width: width, height: width / shape)
			return PDFPageLayout(pageRect: page, imageRect: page)
		}
		let sheet = shape > 1 ? CGSize(width: portrait.height, height: portrait.width) : portrait
		let page = CGRect(origin: .zero, size: sheet)
		let room = page.insetBy(dx: margin, dy: margin)
		assert(room.width > 0 && room.height > 0, "the margin leaves room for the image")
		let size = shape > room.width / room.height
			? CGSize(width: room.width, height: room.width / shape)
			: CGSize(width: room.height * shape, height: room.height)
		let image = CGRect(x: room.midX - size.width / 2, y: room.midY - size.height / 2, width: size.width, height: size.height)
		return PDFPageLayout(pageRect: page, imageRect: image)
	}
}

/// Page images as the PDF stores them: scaled to the quality's size, then JPEG, or for black and
/// white pages one bit per pixel (stored losslessly) when that is clearly smaller. A JPEG goes into
/// the PDF as it is, without being decoded and compressed again. Safe off the main thread.
enum PDFImageEncoder {
	/// A one-bit page must be at most this fraction of the JPEG's size (deflated, as the PDF stores it).
	static let bilevelShare = 0.5
	/// Scaled black and white pixels lighter than this level (0–255) are paper.
	static let bilevelPaper: UInt8 = 153

	/// `image` ready for the PDF at `quality`; `image` itself if it can't be encoded.
	static func encoded(_ image: UIImage, quality: PDFImageQuality, bilevel: Bool) -> UIImage {
		let size = pixelSize(of: image, maxPixels: quality.maxPixels)
		guard let colour = drawn(image, size: size, gray: false),
			  let jpeg = jpegData(colour, quality: quality.jpegQuality),
			  let jpegImage = jpegBacked(jpeg) else { return image }
		guard bilevel, let gray = drawn(image, size: size, gray: true), let bits = packedBits(gray),
			  let deflated = try? (bits as NSData).compressed(using: .zlib),
			  Double(deflated.length) <= Double(jpeg.count) * bilevelShare,
			  let oneBit = bilevelImage(bits, width: gray.width, height: gray.height) else { return UIImage(cgImage: jpegImage) }
		return UIImage(cgImage: oneBit)
	}

	/// `image` scaled to at most `maxPixels` on its long side (never enlarged), upright; nil when it
	/// has no pixels.
	static func scaled(_ image: UIImage, maxPixels: CGFloat) -> UIImage? {
		drawn(image, size: pixelSize(of: image, maxPixels: maxPixels), gray: false).map { UIImage(cgImage: $0) }
	}

	/// Whole pixels for `image` with its long side at most `maxPixels`.
	static func pixelSize(of image: UIImage, maxPixels: CGFloat) -> CGSize {
		let width = image.size.width * image.scale
		let height = image.size.height * image.scale
		guard width > 0, height > 0, maxPixels > 0 else { return .zero }
		let factor = min(1, maxPixels / max(width, height))
		return CGSize(width: max(1, (width * factor).rounded()), height: max(1, (height * factor).rounded()))
	}

	/// `image` drawn upright at `size` pixels: sRGB without alpha, or 8-bit grey.
	private static func drawn(_ image: UIImage, size: CGSize, gray: Bool) -> CGImage? {
		let width = Int(size.width)
		let height = Int(size.height)
		let space = gray ? CGColorSpaceCreateDeviceGray() : CGColorSpace(name: CGColorSpace.sRGB)
		let alpha = gray ? CGImageAlphaInfo.none : CGImageAlphaInfo.noneSkipLast
		guard width > 0, height > 0, let space,
			  let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
									  space: space, bitmapInfo: alpha.rawValue) else { return nil }
		context.interpolationQuality = .high
		// UIKit draws top-down and honours the image's orientation.
		context.translateBy(x: 0, y: CGFloat(height))
		context.scaleBy(x: 1, y: -1)
		UIGraphicsPushContext(context)
		image.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
		UIGraphicsPopContext()
		return context.makeImage()
	}

	private static func jpegData(_ image: CGImage, quality: CGFloat) -> Data? {
		let data = NSMutableData()
		guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
		CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
		guard CGImageDestinationFinalize(destination) else { return nil }
		return data as Data
	}

	/// An image backed by the JPEG data itself, which the PDF context embeds unchanged.
	private static func jpegBacked(_ data: Data) -> CGImage? {
		guard let provider = CGDataProvider(data: data as CFData) else { return nil }
		return CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
	}

	/// An 8-bit grey image packed to one bit per pixel, rows padded to whole bytes, 1 for paper.
	static func packedBits(_ gray: CGImage) -> Data? {
		let width = gray.width
		let height = gray.height
		let stride = gray.bytesPerRow
		guard gray.bitsPerPixel == 8, width > 0, height > 0, let data = gray.dataProvider?.data as Data? else { return nil }
		let bytes = [UInt8](data)
		guard bytes.count >= stride * (height - 1) + width else { return nil }
		let rowBytes = (width + 7) / 8
		var packed = [UInt8](repeating: 0, count: rowBytes * height)
		for row in 0..<height {
			let source = row * stride
			let target = row * rowBytes
			for column in 0..<width where bytes[source + column] > bilevelPaper {
				packed[target + column / 8] |= UInt8(0x80) >> UInt8(column % 8)
			}
		}
		return Data(packed)
	}

	/// A one-bit grey image from `packedBits` output.
	private static func bilevelImage(_ bits: Data, width: Int, height: Int) -> CGImage? {
		let rowBytes = (width + 7) / 8
		guard bits.count >= rowBytes * height, let provider = CGDataProvider(data: bits as CFData) else { return nil }
		return CGImage(width: width, height: height, bitsPerComponent: 1, bitsPerPixel: 1, bytesPerRow: rowBytes,
					   space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
					   provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
	}
}
