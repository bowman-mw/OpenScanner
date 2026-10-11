//
//  SearchablePDF.swift
//  Folio (fork of Open Scanner)
//
//  The PDF scan every iPhone gets: each page image with an invisible OCR
//  text layer laid over the words, so the PDF looks like the scan and its
//  text is selectable and searchable. Replaces Open Scanner's image-only
//  `pdfDocument()`. Notes become PDF annotations.
//

import Foundation
import CoreImage
import CoreText
import PDFKit
import UIKit

enum SearchablePDF {
	/// One page to write: the image and its recognized lines.
	struct Page {
		var image: UIImage
		var lines: [RecognizedLine]
		/// Notes to pin to the page (top-left anchored at their box, if any).
		var notes: [(text: String, box: NormalizedBox?)] = []
	}

	/// Pages for a scan, with its look applied and (optionally) the rebuilt
	/// document's notes.
	@MainActor
	static func pages(for scan: Scan, includeNotes: Bool) -> [Page] {
		let document = includeNotes ? scan.rebuiltDocument : nil
		return scan.capturesArray.enumerated().compactMap { index, capture in
			guard let image = capture.image else { return nil }
			var notes: [(text: String, box: NormalizedBox?)] = []
			if let page = document?.pages[safe: index] {
				notes += page.notes.map { ($0.text, nil) }
				for block in page.blocks {
					notes += block.notes.map { ($0.text, block.box) }
				}
			}
			return Page(image: LookRenderer.apply(scan.lookFilter, to: image),
						lines: capture.recognizedItemsArray.map(\.recognizedLine),
						notes: notes)
		}
	}

	/// Writes the PDF. Pages are 612pt wide (US Letter width) at the image's aspect.
	static func render(_ pages: [Page], title: String) -> Data {
		let format = UIGraphicsPDFRendererFormat()
		format.documentInfo = [kCGPDFContextTitle as String: title, kCGPDFContextCreator as String: "Folio"]
		let first = pageRect(for: pages.first?.image)
		let renderer = UIGraphicsPDFRenderer(bounds: first, format: format)
		let data = renderer.pdfData { context in
			for page in pages {
				let rect = pageRect(for: page.image)
				context.beginPage(withBounds: rect, pageInfo: [:])
				page.image.draw(in: rect)
				drawInvisibleText(page.lines, in: rect, context: context.cgContext)
			}
		}
		guard pages.contains(where: { !$0.notes.isEmpty }), let document = PDFDocument(data: data) else { return data }
		for (index, page) in pages.enumerated() {
			guard let pdfPage = document.page(at: index) else { continue }
			let bounds = pdfPage.bounds(for: .mediaBox)
			for (offset, note) in page.notes.enumerated() {
				// PDF space is bottom-up; pin each note at its block's top-left corner.
				let x = (note.box?.x ?? 0.04) * bounds.width
				let y = bounds.height - (note.box?.y ?? 0.04) * bounds.height - 20 - CGFloat(offset) * 4
				let annotation = PDFAnnotation(bounds: CGRect(x: x, y: y, width: 20, height: 20), forType: .text, withProperties: nil)
				annotation.contents = note.text
				annotation.color = UIColor(red: 0.83, green: 0.66, blue: 0.26, alpha: 1)
				pdfPage.addAnnotation(annotation)
			}
		}
		return document.dataRepresentation() ?? data
	}

	private static func pageRect(for image: UIImage?) -> CGRect {
		let aspect = max(image?.aspectRatio ?? 0.773, 0.1)
		let width: CGFloat = aspect > 1 ? 792 : 612
		return CGRect(x: 0, y: 0, width: width, height: width / aspect)
	}

	/// Draws each line invisibly over its box, scaled to the box's width.
	private static func drawInvisibleText(_ lines: [RecognizedLine], in rect: CGRect, context: CGContext) {
		for line in lines where !line.text.isEmpty && line.box.width > 0 && line.box.height > 0 {
			let box = CGRect(x: rect.minX + line.box.minX * rect.width, y: rect.minY + line.box.minY * rect.height,
							 width: line.box.width * rect.width, height: line.box.height * rect.height)
			let font = CTFontCreateWithName("Helvetica" as CFString, max(box.height * 0.82, 1), nil)
			let attributed = NSAttributedString(string: line.text, attributes: [.font: font])
			let ctLine = CTLineCreateWithAttributedString(attributed)
			var ascent: CGFloat = 0
			var descent: CGFloat = 0
			let width = CGFloat(CTLineGetTypographicBounds(ctLine, &ascent, &descent, nil))
			guard width > 0 else { continue }
			context.saveGState()
			context.setTextDrawingMode(.invisible)
			context.textMatrix = .identity
			context.translateBy(x: box.minX, y: box.maxY)
			context.scaleBy(x: box.width / width, y: -1)
			context.textPosition = CGPoint(x: 0, y: descent)
			CTLineDraw(ctLine, context)
			context.restoreGState()
		}
	}
}

/// Applies a scan's "Look" to page images for export.
enum LookRenderer {
	private static let context = CIContext(options: [.useSoftwareRenderer: false])

	static func apply(_ look: LookFilter, to image: UIImage) -> UIImage {
		guard look != .original, let input = CIImage(image: image) else { return image }
		let filter = CIFilter(name: "CIColorControls")
		filter?.setValue(input, forKey: kCIInputImageKey)
		switch look {
		case .color:
			filter?.setValue(1.08, forKey: kCIInputSaturationKey)
			filter?.setValue(1.05, forKey: kCIInputContrastKey)
		case .gray:
			filter?.setValue(0, forKey: kCIInputSaturationKey)
			filter?.setValue(1.05, forKey: kCIInputContrastKey)
		case .blackAndWhite:
			filter?.setValue(0, forKey: kCIInputSaturationKey)
			filter?.setValue(1.8, forKey: kCIInputContrastKey)
			filter?.setValue(0.08, forKey: kCIInputBrightnessKey)
		case .original:
			break
		}
		guard let output = filter?.outputImage, let cgImage = context.createCGImage(output, from: input.extent) else { return image }
		return UIImage(cgImage: cgImage, scale: image.scale, orientation: image.imageOrientation)
	}
}

extension Array {
	subscript(safe index: Int) -> Element? {
		indices.contains(index) ? self[index] : nil
	}
}
