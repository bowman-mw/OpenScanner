//
//  LookPreview.swift
//  Folio (fork of Open Scanner)
//
//  Pages shown with their scan's look exactly as the PDF will have it: made
//  by the export's own `LookRenderer`, off the main thread, one page at a
//  time, and kept per page, look and size until the page changes. A quick
//  SwiftUI likeness of the look stands in while a page renders.
//

import SwiftUI
import UIKit

extension LookRenderer {
	/// `look` on stored page `data` for the screen: the export's recipe (`apply`), scaled to at most
	/// `maxPixels` on the long side. Nil when the data isn't an image. Safe off the main thread.
	static func preview(_ look: LookFilter, of data: Data, maxPixels: CGFloat) -> UIImage? {
		guard maxPixels > 0, let image = UIImage(data: data) else { return nil }
		return PDFImageEncoder.scaled(apply(look, to: image), maxPixels: maxPixels)
	}
}

/// One page's look at one size, read on the main thread from the capture.
struct LookPreviewRequest: Sendable {
	let data: Data
	let look: LookFilter
	let maxPixels: CGFloat
	/// Names the page and its pixels, so a page re-made since is a different page.
	let page: String

	var key: String { "\(page)·\(look.rawValue)·\(Int(maxPixels))" }

	/// Nil for Original (nothing to render) and for pages without an image.
	@MainActor
	init?(capture: ScanCapture, look: LookFilter, maxPixels: CGFloat) {
		guard look != .original, maxPixels > 0, let data = capture.imageData, !data.isEmpty else { return nil }
		self.init(data: data, look: look, maxPixels: maxPixels,
				  page: "\(capture.id?.uuidString ?? "page")·\(Self.fingerprint(data))")
	}

	init(data: Data, look: LookFilter, maxPixels: CGFloat, page: String) {
		self.data = data
		self.look = look
		self.maxPixels = maxPixels
		self.page = page
	}

	/// The same page and look at another size.
	func resized(to pixels: CGFloat) -> LookPreviewRequest {
		LookPreviewRequest(data: data, look: look, maxPixels: pixels, page: page)
	}

	/// A cheap fingerprint of the page's bytes: their count and 64 bytes spread across them, enough
	/// to tell a re-made page from the one before it.
	static func fingerprint(_ data: Data) -> Int {
		var hasher = Hasher()
		hasher.combine(data.count)
		let step = max(1, data.count / 64)
		for offset in stride(from: 0, to: data.count, by: step) {
			hasher.combine(data[data.startIndex + offset])
		}
		return hasher.finalize()
	}
}

/// Makes and keeps the looked pages the screens show. An actor, so pages render one at a time off
/// the main thread; a thumbnail is scaled from its page's kept preview, so each page renders once
/// per look.
actor LookPreviewRenderer {
	static let shared = LookPreviewRenderer()
	/// Long side of a page preview, in pixels: sharp across a phone's width.
	static let previewPixels: CGFloat = 1600
	/// Long side of a list thumbnail, in pixels.
	static let thumbnailPixels: CGFloat = 200

	private let kept: NSCache<NSString, UIImage>

	init(costLimit: Int = 128 << 20) {
		kept = NSCache()
		kept.totalCostLimit = costLimit
	}

	/// The request's page with its look, from what's kept when it can be. Nil without a render
	/// when the asking view has gone or moved on (its task was cancelled while this one waited).
	func image(for request: LookPreviewRequest) -> UIImage? {
		if let image = kept.object(forKey: request.key as NSString) { return image }
		guard !Task.isCancelled else { return nil }
		guard request.maxPixels < Self.previewPixels else { return preview(for: request) }
		let image = preview(for: request.resized(to: Self.previewPixels)).flatMap {
			PDFImageEncoder.scaled($0, maxPixels: request.maxPixels)
		}
		keep(image, for: request)
		return image
	}

	/// Renders (or finds) the request at its own size.
	private func preview(for request: LookPreviewRequest) -> UIImage? {
		if let image = kept.object(forKey: request.key as NSString) { return image }
		let image = LookRenderer.preview(request.look, of: request.data, maxPixels: request.maxPixels)
		keep(image, for: request)
		return image
	}

	private func keep(_ image: UIImage?, for request: LookPreviewRequest) {
		guard let image else { return }
		let pixels = image.size.width * image.scale * image.size.height * image.scale
		kept.setObject(image, forKey: request.key as NSString, cost: Int(pixels) * 4)
	}
}

/// A page with its scan's look as the PDF will have it. `content` draws the image it's given: the
/// finished render (`isFinal`), or until then the stored image, to dress as a likeness of the look
/// (`lookStandIn`).
struct LookedPage<Content: View>: View {
	@ObservedObject var capture: ScanCapture
	let look: LookFilter
	let maxPixels: CGFloat
	@ViewBuilder let content: (_ image: UIImage?, _ isFinal: Bool) -> Content

	@State private var rendered: (key: String, image: UIImage)?

	var body: some View {
		let request = LookPreviewRequest(capture: capture, look: look, maxPixels: maxPixels)
		let final = rendered.flatMap { $0.key == request?.key ? $0.image : nil }
		content(final ?? storedImage, final != nil || request == nil)
			.task(id: request?.key) {
				guard let request else { return }
				let image = await LookPreviewRenderer.shared.image(for: request)
				guard !Task.isCancelled, let image else { return }
				rendered = (request.key, image)
			}
	}

	/// The page as stored: the thumbnail for small views, the full image otherwise.
	private var storedImage: UIImage? {
		maxPixels > LookPreviewRenderer.thumbnailPixels ? (capture.image ?? capture.thumbnail) : (capture.thumbnail ?? capture.image)
	}
}

extension View {
	/// A quick SwiftUI likeness of `look`, shown only until the real render arrives (Ink has none).
	@ViewBuilder
	func lookStandIn(_ look: LookFilter) -> some View {
		switch look {
		case .color: contrast(1.05).saturation(1.08)
		case .gray: grayscale(1).contrast(1.05)
		case .blackAndWhite: grayscale(1).contrast(1.8)
		case .ink, .original: self
		}
	}
}
