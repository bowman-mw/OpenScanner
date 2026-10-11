//
//  RecreateSource.swift
//  Folio (fork of Open Scanner)
//
//  What the drawing editor recreates from: a figure or diagram block, the
//  original page cropped to that block (shown translucent behind the
//  canvas), and the page's recognized text in the block's frame. Also
//  writes the finished drawing back into the block.
//

import UIKit

/// Everything the editor needs to recreate one block.
struct RecreateRequest: Identifiable {
	/// The block being recreated.
	let id: UUID
	var diagram: Diagram
	var backdrop: UIImage?
	var traceLines: [RecognizedLine]
}

/// Builds `RecreateRequest`s and applies their results.
enum RecreateSource {
	/// Aspect of a drawing with nothing to trace.
	static let blankAspect = 4.0 / 3.0

	/// Whether a block can be recreated as a drawing.
	static func canRecreate(_ content: BlockContent) -> Bool {
		switch content {
		case .diagram, .figure: return true
		case .heading, .paragraph, .list, .table, .equation: return false
		}
	}

	/// The request for recreating `blockID`, or nil when it isn't a figure or diagram.
	@MainActor
	static func request(for blockID: UUID, in document: FolioDocument, scan: Scan) -> RecreateRequest? {
		guard let (pageIndex, block) = locate(blockID, in: document), canRecreate(block.content) else { return nil }
		let capture = capture(forPage: pageIndex, of: document, in: scan)
		var backdrop: UIImage?
		var traceLines: [RecognizedLine] = []
		if let box = block.box, let capture {
			backdrop = capture.image.flatMap { crop($0, to: box) }
			traceLines = TraceLabels.lines(capture.recognizedItemsArray.map(\.recognizedLine), in: box)
		}
		let aspect = backdrop.map { Double($0.size.width / max($0.size.height, 1)) } ?? blankAspect
		guard let diagram = startingDiagram(for: block.content, aspect: aspect) else { return nil }
		return RecreateRequest(id: blockID, diagram: diagram, backdrop: backdrop, traceLines: traceLines)
	}

	/// The page index and block for `id`.
	static func locate(_ id: UUID, in document: FolioDocument) -> (Int, FolioBlock)? {
		for (index, page) in document.pages.enumerated() {
			if let block = page.blocks.first(where: { $0.id == id }) { return (index, block) }
		}
		return nil
	}

	/// The scan page a document page was rebuilt from.
	@MainActor
	static func capture(forPage index: Int, of document: FolioDocument, in scan: Scan) -> ScanCapture? {
		let captures = scan.capturesArray
		if let ids = document.sourceCaptureIDs, ids.indices.contains(index) {
			return captures.first { $0.id == ids[index] }
		}
		return captures.indices.contains(index) ? captures[index] : nil
	}

	/// What the editor starts with: a diagram as it is, or an empty drawing
	/// (carrying the figure's caption) for a figure.
	static func startingDiagram(for content: BlockContent, aspect: Double) -> Diagram? {
		switch content {
		case .diagram(let diagram):
			return diagram
		case .figure(_, let caption, _):
			return Diagram(nodes: [], edges: [], layout: .faithful, caption: caption, aspect: aspect > 0 ? aspect : blankAspect)
		case .heading, .paragraph, .list, .table, .equation:
			return nil
		}
	}

	/// Writes a finished drawing into `block`. A diagram replaces the old one;
	/// a figure becomes a diagram that keeps the figure's caption (its picture,
	/// no longer used, goes with `FigureAssets.prune`). A drawing with no
	/// shapes changes nothing.
	static func apply(_ diagram: Diagram, to block: inout FolioBlock) {
		guard !diagram.nodes.isEmpty else { return }
		var drawn = diagram
		switch block.content {
		case .figure(_, let caption, _):
			drawn.caption = drawn.caption ?? caption
		case .diagram:
			break
		case .heading, .paragraph, .list, .table, .equation:
			return
		}
		block.content = .diagram(drawn)
		block.provenance = Provenance(engine: "user", confidence: 1)
	}

	// MARK: The original behind the canvas

	/// `image` cropped to `box` (normalized, top-left origin).
	static func crop(_ image: UIImage, to box: NormalizedBox) -> UIImage? {
		guard let upright = uprightCGImage(image) else { return nil }
		let rect = pixelRect(box, width: upright.width, height: upright.height)
		guard rect.width >= 1, rect.height >= 1, let cropped = upright.cropping(to: rect) else { return nil }
		return UIImage(cgImage: cropped)
	}

	/// A normalized box in whole pixels of a `width` × `height` image, clipped to it.
	static func pixelRect(_ box: NormalizedBox, width: Int, height: Int) -> CGRect {
		let w = CGFloat(width), h = CGFloat(height)
		let rect = CGRect(x: box.x * w, y: box.y * h, width: box.width * w, height: box.height * h).integral
		return rect.intersection(CGRect(x: 0, y: 0, width: w, height: h))
	}

	/// The image's pixels with its orientation applied.
	private static func uprightCGImage(_ image: UIImage) -> CGImage? {
		guard image.imageOrientation != .up else { return image.cgImage }
		let format = UIGraphicsImageRendererFormat()
		format.scale = image.scale
		return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in image.draw(at: .zero) }.cgImage
	}
}
