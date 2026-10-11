//
//  PageReprocessor.swift
//  Folio (fork of Open Scanner)
//
//  Non-destructive pages. Each page keeps its recipe on `ScanCapture` — the
//  crop quad on the original photo, the cleanup mode and switches, and the
//  rotation — and its original stays on this iPhone (OriginalStore). Changing
//  the recipe re-makes the page from the original through the same steps the
//  camera uses. What was read from the old pixels goes with them: the page's
//  recognized lines are read again, and its page of the scan's rebuilt
//  document is marked stale, then rebuilt and spliced in place once they are
//  (PageSplice), so every other page keeps its Review work. A rebuilt
//  document that doesn't match the scan's pages is cleared instead, as it
//  would be rebuilt whole anyway. A spread split in two (SpreadSplit) becomes
//  two pages in its place, each with its own recipe and its own copy of the
//  original, both read again and rebuilt the same way.
//
//  App-target only.
//

import CoreData
import CoreImage
import UIKit

// MARK: - PageRecipe

/// How a page image was made from its original photo. Stored on `ScanCapture`.
struct PageRecipe: Equatable {
	/// The crop on the upright original (normalized, top-left origin). `.fullFrame` means no
	/// perspective correction at all.
	var quad: PageQuad
	/// The cleanup recipe; nil keeps the photo's own pixels (an imported photo with no page in it).
	var mode: CaptureMode?
	/// Clockwise quarter turns applied after cleanup, 0...3.
	var rotation: Int
	/// Document cleanup: flatten shadows.
	var removeShadows: Bool
	/// Whiteboard cleanup: keep marker colours.
	var keepMarkerColors: Bool
}

/// A page fresh from the camera or an import: the cleaned image, plus its original and the recipe
/// that made it, when there are ones. Pages from PDFs and the sample library have neither. The
/// original is a file in OriginalStore's staging folder, not bytes in memory; `Scan.append` moves
/// it into place, and whoever drops an unsaved page deletes it (`OriginalStore.discard`).
struct CapturedPage {
	var image: UIImage
	var original: OriginalStore.Staged?
	var recipe: PageRecipe?

	init(image: UIImage, original: OriginalStore.Staged? = nil, recipe: PageRecipe? = nil) {
		self.image = image
		self.original = original
		self.recipe = recipe
	}
}

extension ScanCapture {
	/// The page's recipe, or nil for pages made without one (PDF imports, sample pages, scans from
	/// before originals were kept). Setting nil clears the crop and mode but keeps the rotation.
	var recipe: PageRecipe? {
		get {
			guard let stored = cropQuad, let quad = PageQuad(storageString: stored) else { return nil }
			return PageRecipe(
				quad: quad,
				mode: cleanupMode.flatMap(CaptureMode.init(rawValue:)),
				rotation: QuarterTurns.normalized(Int(rotation)),
				removeShadows: removeShadows,
				keepMarkerColors: keepMarkerColors
			)
		}
		set {
			cropQuad = newValue?.quad.storageString
			cleanupMode = newValue?.mode?.rawValue
			guard let newValue else { return }
			rotation = Int16(QuarterTurns.normalized(newValue.rotation))
			removeShadows = newValue.removeShadows
			keepMarkerColors = newValue.keepMarkerColors
		}
	}

	/// True when this iPhone can re-make the page from its original (crop and mode editing).
	func canReprocess(originals: OriginalStore = .shared) -> Bool {
		guard recipe != nil, let id else { return false }
		return originals.contains(id)
	}
}

extension QuarterTurns {
	/// The UIKit orientation that draws an upright image turned `turns` clockwise.
	static func imageOrientation(_ turns: Int) -> UIImage.Orientation {
		switch normalized(turns) {
		case 1: return .right
		case 2: return .down
		case 3: return .left
		default: return .up
		}
	}
}

// MARK: - Page revisions

/// How many times each page's pixels were re-made this session. A reading checks it before
/// storing its lines (`PageOCR.process`): a page's first reading, still running when the page
/// was re-made, read pixels the page no longer has, and the reading of the new ones stores its own.
@MainActor
final class PageRevisions {
	static let shared = PageRevisions()
	private var revisions: [NSManagedObjectID: Int] = [:]

	/// Which version of the page's pixels a reading starting now sees.
	func revision(of id: NSManagedObjectID) -> Int {
		revisions[id, default: 0]
	}

	/// The page's pixels were replaced: readings already running are stale.
	func pageRemade(_ id: NSManagedObjectID) {
		revisions[id, default: 0] += 1
	}
}

// MARK: - PageReprocessor

/// Re-makes pages from their originals, and turns pages that have none.
enum PageReprocessor {
	enum ReprocessError: LocalizedError {
		/// The original isn't on this iPhone.
		case missingOriginal
		/// The image couldn't be decoded or rendered.
		case renderFailed
		/// The page couldn't be split in two (it left its scan, or its original couldn't be copied).
		case splitFailed

		var errorDescription: String? {
			switch self {
			case .missingOriginal:
				return String(localized: "The original photo isn't on this iPhone.")
			case .renderFailed:
				return String(localized: "The page couldn't be re-made.")
			case .splitFailed:
				return String(localized: "The page couldn't be split in two.")
			}
		}
	}

	/// Pages are stored at most 2400 px wide (as `ScanCapture.createImage` does).
	static let maxOutputWidth: CGFloat = 2400
	/// Long side of the downscaled original that Vision looks for the page in.
	static let detectionSize: CGFloat = 1024
	/// The camera's trim on a detected outline (see `CapturePipeline.detectedQuadInset`).
	static let detectedQuadInset: CGFloat = 0.01

	/// Thread-safe; shared by every render.
	private static let context = CIContext(options: [.cacheIntermediates: false])
	private static let outputColorSpace = CGColorSpace(name: CGColorSpace.sRGB)

	// MARK: Rendering (any thread)

	/// Makes a page from its original, in the camera's order: crop → limit width → clean → turn.
	static func render(original: CGImage, recipe: PageRecipe) -> CGImage? {
		guard original.width >= 1, original.height >= 1 else { return nil }
		var page = CIImage(cgImage: original)
		if recipe.quad != .fullFrame {
			page = PageCleanup.correctPerspective(page, quad: recipe.quad)
		}
		page = PageCleanup.limitWidth(page, to: maxOutputWidth)
		if let mode = recipe.mode {
			page = PageCleanup.clean(page, mode: mode, removeShadows: recipe.removeShadows, keepMarkerColors: recipe.keepMarkerColors)
		}
		return renderImage(rotated(page, quarterTurns: recipe.rotation))
	}

	/// `image` turned `quarterTurns` clockwise, moved to the origin.
	static func rotated(_ image: CIImage, quarterTurns: Int) -> CIImage {
		let orientation: CGImagePropertyOrientation
		switch QuarterTurns.normalized(quarterTurns) {
		case 1: orientation = .right
		case 2: orientation = .down
		case 3: orientation = .left
		default: return image
		}
		let turned = image.oriented(orientation)
		let origin = turned.extent.origin
		return turned.transformed(by: CGAffineTransform(translationX: -origin.x, y: -origin.y))
	}

	/// `image` turned `quarterTurns` clockwise.
	static func rotated(_ image: CGImage, quarterTurns: Int) -> CGImage? {
		guard image.width >= 1, image.height >= 1 else { return nil }
		guard QuarterTurns.normalized(quarterTurns) != 0 else { return image }
		return renderImage(rotated(CIImage(cgImage: image), quarterTurns: quarterTurns))
	}

	/// `image` scaled down (never up) to the originals' size cap; `image` itself when it fits.
	static func cappedOriginal(_ image: CGImage) -> CGImage? {
		guard image.width >= 1, image.height >= 1 else { return nil }
		guard CGFloat(max(image.width, image.height)) > OriginalStore.maxLongSide else { return image }
		return renderImage(PageCleanup.limitLongSide(CIImage(cgImage: image), to: OriginalStore.maxLongSide))
	}

	/// Finds the page on an original (normalized, top-left origin, untrimmed), or nil.
	static func detectPage(in original: CGImage) -> PageQuad? {
		let small = PageCleanup.limitLongSide(CIImage(cgImage: original), to: detectionSize)
		guard let image = renderImage(small) else { return nil }
		return PageDetector().detect(cgImage: image)
	}

	private static func renderImage(_ image: CIImage) -> CGImage? {
		let bounds = image.extent.integral
		guard !bounds.isInfinite, bounds.width >= 1, bounds.height >= 1, let outputColorSpace else { return nil }
		return context.createCGImage(image, from: bounds, format: .RGBA8, colorSpace: outputColorSpace)
	}

	// MARK: Applying to a page (main actor)

	/// Re-makes `capture` from its original with `recipe` (off the main thread), stores the new
	/// image, thumbnail and recipe, and reads the page again. Returns the task that reads it and then
	/// redoes its page of the rebuilt document. Pass `original` when it's already decoded (the
	/// editor holds it) to skip decoding it again.
	@MainActor
	@discardableResult
	static func apply(_ recipe: PageRecipe, to capture: ScanCapture, original: CGImage? = nil,
					  originals: OriginalStore = .shared) async throws -> Task<Void, Never> {
		guard let id = capture.id else { throw ReprocessError.missingOriginal }
		let page = try await Task.detached(priority: .userInitiated) { () throws -> EncodedPage in
			guard let source = original ?? originals.loadImage(for: id) else { throw ReprocessError.missingOriginal }
			guard let rendered = render(original: source, recipe: recipe) else { throw ReprocessError.renderFailed }
			return EncodedPage(UIImage(cgImage: rendered, scale: 1, orientation: .up))
		}.value
		guard !capture.isDeleted, capture.managedObjectContext != nil else { throw ReprocessError.renderFailed }
		capture.recipe = recipe
		return store(page, on: capture)
	}

	/// Turns the stored page itself to `quarterTurns` (absolute, clockwise) — for pages whose
	/// original isn't on this iPhone. The turn keeps every pixel: capping the width again would
	/// shrink a portrait page each time it went landscape, with no original to make it again.
	/// Returns the task that reads the page again and redoes its page of the rebuilt document.
	@MainActor
	@discardableResult
	static func rotateStoredPage(_ capture: ScanCapture, to quarterTurns: Int) async throws -> Task<Void, Never> {
		guard let data = capture.imageData else { throw ReprocessError.renderFailed }
		let target = QuarterTurns.normalized(quarterTurns)
		let delta = QuarterTurns.normalized(target - Int(capture.rotation))
		let page = try await Task.detached(priority: .userInitiated) { () throws -> EncodedPage in
			guard let decoded = CIImage(data: data, options: [.applyOrientationProperty: true]),
				  let turned = renderImage(rotated(decoded, quarterTurns: delta)) else {
				throw ReprocessError.renderFailed
			}
			return EncodedPage(UIImage(cgImage: turned, scale: 1, orientation: .up), keepingSize: true)
		}.value
		guard !capture.isDeleted, capture.managedObjectContext != nil else { throw ReprocessError.renderFailed }
		capture.rotation = Int16(target)
		return store(page, on: capture)
	}

	/// Drops what was read from a page's old pixels, then saves: its recognized lines, its page of
	/// the scan's rebuilt document, which is marked stale for Rebuilder to redo once the page has
	/// been read again (every other page keeps its Review work), and that page's figure pictures. A
	/// rebuilt document that can't take a spliced page (see `splicesRebuiltPage(of:)`) is cleared,
	/// Review fixes and all.
	@MainActor
	static func invalidateText(of capture: ScanCapture) {
		guard let context = capture.managedObjectContext else { return }
		for item in capture.recognizedItemsArray {
			context.delete(item)
		}
		if let scan = capture.parent, scan.rebuiltData != nil {
			let captureIDs = scan.capturesArray.compactMap(\.id)
			scan.rebuiltDocument = capture.id.flatMap { id in
				scan.rebuiltDocument.flatMap { PageSplice.markingStale(id, in: $0, captureIDs: captureIDs) }
			}
		}
		capture.parent?.lastUpdate = Date()
		context.saveQuietly()
		// The page's figure pictures were cut from the old pixels.
		if let scan = capture.parent {
			FigureAssets.prune(scan)
		}
	}

	/// True when re-making `capture` redoes only its own page of the scan's rebuilt document; false
	/// when there's no rebuilt document, or one that doesn't match the scan's pages (which
	/// re-making any page clears).
	@MainActor
	static func splicesRebuiltPage(of capture: ScanCapture) -> Bool {
		guard let scan = capture.parent, let id = capture.id, let document = scan.rebuiltDocument else { return false }
		return PageSplice.pageIndex(of: id, in: document, captureIDs: scan.capturesArray.compactMap(\.id)) != nil
	}

	/// A page's JPEG and thumbnail, encoded off the main thread with `ScanCapture`'s own encoders.
	/// `keepingSize` skips the width cap, for a stored page that is only being turned.
	private struct EncodedPage {
		let image: UIImage
		let imageData: Data?
		let thumbnailData: Data?

		init(_ image: UIImage, keepingSize: Bool = false) {
			self.image = image
			let width = image.size.width * image.scale
			imageData = ScanCapture.encodedPageImage(image, maxWidth: keepingSize ? width : PageReprocessor.maxOutputWidth)
			thumbnailData = ScanCapture.encodedThumbnail(image)
		}
	}

	/// Stores pixels edited outside the page editor (Quick Look's markup and turn) on `capture`, as
	/// JPEG `data`. The page can't be re-made from its original any more without losing the edit,
	/// so its crop and cleanup are cleared (the original stays, and the page keeps its turn); what
	/// was read from the old pixels goes, as after a re-make. Returns the task that reads the page
	/// again and redoes its page of the rebuilt document; nil when `data` isn't an image or the
	/// page is gone.
	@MainActor
	@discardableResult
	static func storeEdited(_ data: Data, on capture: ScanCapture) -> Task<Void, Never>? {
		guard let image = UIImage(data: data), !capture.isDeleted, capture.managedObjectContext != nil else { return nil }
		capture.recipe = nil
		storePixels(data, thumbnail: ScanCapture.encodedThumbnail(image), on: capture)
		return readingAgain(capture, image: image)
	}

	@MainActor
	private static func store(_ page: EncodedPage, on capture: ScanCapture) -> Task<Void, Never> {
		storePixels(page.imageData, thumbnail: page.thumbnailData, on: capture)
		return readingAgain(capture, image: page.image)
	}

	/// Reads the page again, then redoes its part of the scan's rebuilt document, if it has one waiting.
	@MainActor
	private static func readingAgain(_ capture: ScanCapture, image: UIImage) -> Task<Void, Never> {
		let scan = capture.parent
		return Task { @MainActor in
			await PageOCR.process(capture, image: image)
			guard let scan, scan.rebuiltDocument?.hasStalePages == true else { return }
			await Rebuilder(tier: DeviceTier.current).refreshStalePages(of: scan)
		}
	}

	/// Puts new pixels on the page and drops what was read from the old ones (saves).
	@MainActor
	private static func storePixels(_ imageData: Data?, thumbnail: Data?, on capture: ScanCapture) {
		// A reading of the old pixels may still be running (the page's first one, say); it mustn't
		// store its lines over the new ones.
		PageRevisions.shared.pageRemade(capture.objectID)
		capture.imageData = imageData
		capture.thumbnailData = thumbnail
		invalidateText(of: capture)
	}
}

// MARK: - Splitting a spread

extension PageReprocessor {
	/// The pages a spread was split into: the page itself, now the first, and the new one after it.
	struct SplitResult {
		let first: ScanCapture
		let second: ScanCapture
		/// Reads both pages again, then redoes their pages of the rebuilt document.
		let reading: Task<Void, Never>
	}

	/// Splits `capture`, a photo of two facing pages, into two pages in its place: it becomes the
	/// first, re-made with `first`, and a new page re-made with `second` follows it, with its own copy
	/// of the original (so deleting either page leaves the other's). The scan's rebuilt document gets
	/// the two in place of the one, each rebuilt once read (`PageSplice.splitting`), or is cleared
	/// when it can't take spliced pages. Pass `original` when it's already decoded.
	@MainActor
	@discardableResult
	static func split(_ capture: ScanCapture, first: PageRecipe, second: PageRecipe, original: CGImage? = nil,
					  originals: OriginalStore = .shared) async throws -> SplitResult {
		guard let id = capture.id, let scan = capture.parent, capture.managedObjectContext != nil else { throw ReprocessError.splitFailed }
		let newID = UUID()
		let pages = try await Task.detached(priority: .userInitiated) { () throws -> (first: EncodedPage, second: EncodedPage) in
			guard let source = original ?? originals.loadImage(for: id) else { throw ReprocessError.missingOriginal }
			guard let left = render(original: source, recipe: first), let right = render(original: source, recipe: second) else {
				throw ReprocessError.renderFailed
			}
			do {
				try originals.copy(id, to: newID)
			} catch {
				throw ReprocessError.splitFailed
			}
			return (EncodedPage(UIImage(cgImage: left, scale: 1, orientation: .up)),
					EncodedPage(UIImage(cgImage: right, scale: 1, orientation: .up)))
		}.value
		guard !capture.isDeleted, let context = capture.managedObjectContext, capture.parent == scan else {
			originals.remove(newID)
			throw ReprocessError.splitFailed
		}
		let before = scan.capturesArray.compactMap(\.id)
		let wasRebuilt = scan.rebuiltData != nil
		let added = insertedPage(newID, after: capture, in: scan, context: context)
		added.recipe = second
		added.imageData = pages.second.imageData
		added.thumbnailData = pages.second.thumbnailData
		capture.recipe = first
		if scan.rebuiltData != nil {
			scan.rebuiltDocument = scan.rebuiltDocument.flatMap { PageSplice.splitting(id, adding: newID, in: $0, captureIDs: before) }
		}
		// Saves the new page too.
		storePixels(pages.first.imageData, thumbnail: pages.first.thumbnailData, on: capture)
		if !wasRebuilt, startsOnWord(scan) {
			context.saveQuietly()
		}
		let images = (pages.first.image, pages.second.image)
		let reading = Task { @MainActor in
			await PageOCR.process(capture, image: images.0)
			await PageOCR.process(added, image: images.1)
			guard scan.rebuiltDocument?.hasStalePages == true else { return }
			await Rebuilder(tier: DeviceTier.current).refreshStalePages(of: scan)
		}
		return SplitResult(first: capture, second: added, reading: reading)
	}

	/// A scan made from a spread photo starts on Slides, as wide pages do (`Scan.create`). Once its
	/// pages aren't wide any more, a scan not yet rebuilt starts on Word instead, as one made from
	/// those pages would. True when that changed its output.
	@MainActor
	@discardableResult
	static func startsOnWord(_ scan: Scan) -> Bool {
		guard scan.output == .pptx, !scan.looksLikeSlides else { return false }
		scan.output = .docx
		return true
	}

	/// A new page with `id` right after `capture` in `scan`, every page numbered again.
	@MainActor
	static func insertedPage(_ id: UUID, after capture: ScanCapture, in scan: Scan, context: NSManagedObjectContext) -> ScanCapture {
		var pages = scan.capturesArray
		let page = ScanCapture(context: context)
		page.id = id
		page.timestamp = Date()
		let position = pages.firstIndex(of: capture).map { $0 + 1 } ?? pages.endIndex
		pages.insert(page, at: position)
		scan.addToCaptures(page)
		for (order, each) in pages.enumerated() {
			each.order = Int32(order)
		}
		scan.lastUpdate = Date()
		assert(scan.capturesArray.count == pages.count, "the new page joined the scan")
		return page
	}
}
