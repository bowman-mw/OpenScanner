//
//  QuickLookController.swift
//  Open Scanner
//
//  Created by Slaven Radic on 2024-09-01.
//

import SwiftUI
import UIKit
import QuickLook

struct QuickLookView: View {
	@Environment(\.dismiss) private var dismiss
	@State var scanCapture: ScanCapture
	
	var body: some View {
		ZStack(alignment: .top) {
			QuickLookController(scanCapture: scanCapture)
				.ignoresSafeArea(edges: .all)
			
			HStack {

				buttonBack
				Spacer()
			}
			// Inside the safe area (only the preview runs edge to edge), where
			// the back pill sits on every other screen.
			.padding(.horizontal, 12)
			.padding(.vertical, 6)
		}
	}
	
	var buttonBack: some View {
		BackPill(title: "Page") {
			dismiss()
		}
	}
	
}

struct QuickLookController: UIViewControllerRepresentable {
	
	var scanCapture: ScanCapture
	
	func makeUIViewController(context: Context) -> UINavigationController {
		let controller = QLPreviewController()
		controller.dataSource = context.coordinator
		controller.delegate = context.coordinator
		controller.setEditing(true, animated: true)
		let navigationController = UINavigationController(rootViewController: controller)
		return navigationController
	}
	
	func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {}
	
	func makeCoordinator() -> Coordinator {
		return Coordinator(parent: self)
	}
	
	class Coordinator: NSObject, QLPreviewControllerDelegate, QLPreviewControllerDataSource {
		
		let parent: QuickLookController
		
		init(parent: QuickLookController) {
			self.parent = parent
		}
		
		func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
		
		func previewController(_ controller: QLPreviewController, editingModeFor previewItem: QLPreviewItem) -> QLPreviewItemEditingMode {
			// Markup here rewrites the scan itself; an annotated page is shown with its
			// marks drawn in, so editing it would bake them into the image.
			marks.isEmpty ? .updateContents : .disabled
		}
		
		func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
			
			let url = imageUrl
			var data: Data = self.parent.scanCapture.imageData ?? Data()
			let pageMarks = marks
			if !pageMarks.isEmpty, let image = parent.scanCapture.image,
			   let annotated = MarkRenderer.flattened(image, marks: pageMarks).jpegData(compressionQuality: 0.85) {
				data = annotated
			}
			do {
				try data.write(to: url)
			} catch {
				print("Error loading image")
			}
			
			let previewItem = ScanPreview(url: url, title: "Scan")
			return previewItem as QLPreviewItem
		}
		
		func previewController(_ controller: QLPreviewController, didUpdateContentsOf previewItem: QLPreviewItem) {
			
			do {
				let imageData = try Data(contentsOf: imageUrl)
				// Folio: through PageReprocessor, so the page is read again, its page of the rebuilt
				// document redone, and figures are never cut from its original with the old recipe.
				let capture = parent.scanCapture
				Task { @MainActor in
					PageReprocessor.storeEdited(imageData, on: capture)
				}
			} catch {
				print("Error loading modified image")
			}
		}
		
		/// The page's marks from Annotate.
		private var marks: [PageMark] {
			MainActor.assumeIsolated { parent.scanCapture.pageMarks }
		}
		
		var imageUrl: URL {
			getDocumentsDirectory().appendingPathComponent((self.parent.scanCapture.id?.uuidString ?? "scan") + ".jpg")
		}
	}
}

class ScanPreview: NSObject, QLPreviewItem {
	
	var previewItemURL: URL?
	var previewItemTitle: String?
	
	init(url: URL?, title: String?) {
		previewItemURL = url
		previewItemTitle = title
	}
}
