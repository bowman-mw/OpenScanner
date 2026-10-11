//
//  ImportCleanup.swift
//  Folio (fork of Open Scanner)
//
//  Photos imported from the library (a whiteboard snapped earlier, a page on
//  a desk) get the same treatment as camera captures: find the page, square
//  it up and even out the lighting. Photos without a page pass through.
//

import CoreImage
import UIKit

enum ImportCleanup {
	private static let context = CIContext()

	/// Returns the page found in `image`, perspective-corrected and cleaned,
	/// or `image` unchanged when there's no page in it.
	static func prepare(_ image: UIImage, removeShadows: Bool) async -> UIImage {
		await withCheckedContinuation { continuation in
			DispatchQueue.global(qos: .userInitiated).async {
				guard let cgImage = image.cgImage, let quad = PageDetector().detect(cgImage: cgImage) else {
					continuation.resume(returning: image)
					return
				}
				var page = PageCleanup.correctPerspective(CIImage(cgImage: cgImage), quad: quad)
				page = PageCleanup.clean(page, mode: .document, removeShadows: removeShadows, keepMarkerColors: true)
				page = PageCleanup.limitWidth(page, to: 2400)
				guard let output = context.createCGImage(page, from: page.extent) else {
					continuation.resume(returning: image)
					return
				}
				continuation.resume(returning: UIImage(cgImage: output))
			}
		}
	}
}
