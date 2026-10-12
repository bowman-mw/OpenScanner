//
//  ImportCleanup.swift
//  Rescriva (fork of Open Scanner)
//
//  Photos imported from the library (a whiteboard snapped earlier, a page on
//  a desk) get the same treatment as camera captures: find the page, square
//  it up and even out the lighting. Photos without a page pass through. Like
//  a capture, the page keeps its recipe and (when Settings keeps originals)
//  the photo itself, so the crop can be fixed later.
//

import CoreImage
import UIKit

enum ImportCleanup {
	/// Returns the page found in `image`, perspective-corrected and cleaned as a document, or the
	/// photo as it is when there's no page in it, with the recipe and (when `keepsOriginal`) the
	/// photo staged in `originals` as its original. Runs off the main thread.
	static func prepare(_ image: UIImage, removeShadows: Bool, keepsOriginal: Bool,
						originals: OriginalStore = .shared) async -> CapturedPage {
		await Task.detached(priority: .userInitiated) {
			preparePage(image, removeShadows: removeShadows, originals: keepsOriginal ? originals : nil)
		}.value
	}

	private static func preparePage(_ image: UIImage, removeShadows: Bool, originals: OriginalStore?) -> CapturedPage {
		guard let cgImage = image.cgImage, let original = PageReprocessor.cappedOriginal(cgImage) else {
			return CapturedPage(image: image)
		}
		let quad = PageReprocessor.detectPage(in: original)
		let recipe = PageRecipe(quad: quad ?? .fullFrame, mode: quad == nil ? nil : .document, rotation: 0,
								removeShadows: removeShadows, keepMarkerColors: true)
		guard let page = PageReprocessor.render(original: original, recipe: recipe) else {
			return CapturedPage(image: image)
		}
		// Written to a file now: a big import mustn't hold every photo's encoded bytes until it's saved.
		let staged = originals?.stage(CIImage(cgImage: original))
		return CapturedPage(image: UIImage(cgImage: page, scale: 1, orientation: .up), original: staged, recipe: recipe)
	}
}
