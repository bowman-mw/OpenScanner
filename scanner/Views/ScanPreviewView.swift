//
//  ScanPreviewView.swift
//  Folio (fork of Open Scanner)
//
//  What opens when you tap a scan: a calm, read-only look at it — the rebuilt
//  document for Word and Slides scans, the pages for everything — with Edit
//  (Scan & pages), Annotate and Share at the top.
//

import SwiftUI

/// What the preview shows.
enum PreviewMode: String, CaseIterable {
	case document, pages

	var label: LocalizedStringKey {
		switch self {
		case .document: return "Document"
		case .pages: return "Pages"
		}
	}
}

struct ScanPreviewView: View {
	@Environment(FolioRouter.self) private var router
	@ObservedObject var scan: Scan

	@State private var mode: PreviewMode
	@State private var exportRequest: ExportRequest?
	@State private var zoomedPage: ScanCapture?
	@State private var annotateRequest: AnnotateRequest?

	init(scan: Scan) {
		self.scan = scan
		_mode = State(initialValue: scan.isRebuilt ? .document : .pages)
	}

	var body: some View {
		ZStack {
			GrainBackground()
			ScrollView {
				VStack(alignment: .leading, spacing: 0) {
					topBar
					header
					if document != nil {
						FolioSegmentedPicker(options: PreviewMode.allCases, selection: $mode) { $0.label }
							.padding(.horizontal, 16)
							.padding(.bottom, 14)
					}
					content
				}
				.padding(.bottom, 48)
			}
			.overlay(alignment: .top) { StatusBarScrim() }
			.fullScreenCover(item: $annotateRequest) { request in
				AnnotateView(request: request) {
					// Annotations sit on the pages, so show them there.
					withAnimation(FolioMotion.ui) { mode = .pages }
				}
			}
		}
		.sheet(item: $exportRequest) { request in
			ExportSheet(scan: scan, initialFormat: request.format) { message in router.showToast(message) }
		}
		.fullScreenCover(item: $zoomedPage) { capture in
			QuickLookView(scanCapture: capture)
				.ignoresSafeArea()
		}
	}

	/// The rebuilt document, for scans headed to Word or Slides.
	private var document: FolioDocument? {
		scan.output == .pdf ? nil : scan.rebuiltDocument
	}

	private var topBar: some View {
		HStack {
			BackPill(title: "Scans") { router.pop() }
			Spacer()
			Button {
				router.push(.scan(scan))
			} label: {
				Text("Edit")
					.font(FolioFont.ui(14, weight: .medium))
					.foregroundStyle(.bark)
					.frame(height: 40)
					.padding(.horizontal, 16)
					.background(Color.cream, in: Capsule())
					.folioShadow(.small)
			}
			.buttonStyle(PressScaleStyle(scale: 0.94))
			.accessibilityHint("Opens the pages, rebuild and look settings")
			if !scan.capturesArray.isEmpty {
				CircleIconButton(systemName: "pencil.tip.crop.circle", label: "Annotate") {
					annotate(startingAt: 0)
				}
			}
			CircleIconButton(systemName: "square.and.arrow.up", label: "Share") {
				exportRequest = ExportRequest(format: defaultExportFormat)
			}
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 6)
	}

	private var header: some View {
		VStack(alignment: .leading, spacing: 6) {
			HStack(alignment: .firstTextBaseline, spacing: 10) {
				Text(scan.displayTitle)
					.font(FolioFont.header(26))
					.foregroundStyle(.bark)
					.accessibilityAddTraits(.isHeader)
				Spacer(minLength: 0)
				Text(scan.output.chipLabel)
					.font(FolioFont.ui(11, weight: .medium))
					.foregroundStyle(.bark)
					.padding(.vertical, 4)
					.padding(.horizontal, 9)
					.background(scan.output.chipColor, in: RoundedRectangle(cornerRadius: FolioRadius.small, style: .continuous))
			}
			Text(scan.detailMeta)
				.font(FolioFont.ui(12))
				.foregroundStyle(.slate)
		}
		.padding(.horizontal, 20)
		.padding(.top, 10)
		.padding(.bottom, 16)
	}

	@ViewBuilder
	private var content: some View {
		if mode == .document, let document {
			RebuiltDocumentView(document: document, output: scan.output, selectedBlock: nil, activeFlag: nil,
								onSelectBlock: { _ in }, onOpenFlag: { _ in }, onToggleItem: { _, _ in })
				.environment(\.documentIsInteractive, false)
				.padding(.vertical, 22)
				.padding(.horizontal, 20)
				.background(Color.paper, in: RoundedRectangle(cornerRadius: FolioRadius.medium, style: .continuous))
				.folioShadow(.card)
				.padding(.horizontal, 16)
				.transition(.opacity)
		} else {
			pages
				.transition(.opacity)
		}
	}

	@ViewBuilder
	private var pages: some View {
		let captures = scan.capturesArray
		if captures.isEmpty {
			Text("No pages yet. Tap Edit to add some.")
				.font(FolioFont.bubble(16))
				.foregroundStyle(.slate)
				.frame(maxWidth: .infinity)
				.padding(.vertical, 40)
		} else {
			LazyVStack(spacing: 22) {
				ForEach(Array(captures.enumerated()), id: \.element.objectID) { index, capture in
					PreviewPage(capture: capture, number: index + 1, look: scan.lookFilter) {
						zoomedPage = capture
					} onAnnotate: {
						annotate(startingAt: index)
					}
				}
			}
			.padding(.horizontal, 20)
		}
	}

	private func annotate(startingAt index: Int) {
		let pages = scan.annotationPages()
		guard !pages.isEmpty else { return }
		annotateRequest = AnnotateRequest(pages: pages, startIndex: index)
	}

	private var defaultExportFormat: ExportFormat {
		guard DeviceTier.current.canRebuild, scan.isRebuilt else { return .pdf }
		return scan.output == .pptx ? .pptx : .docx
	}
}

/// One page in the preview: the scan on paper, with its look applied.
private struct PreviewPage: View {
	@ObservedObject var capture: ScanCapture
	let number: Int
	let look: LookFilter
	let onOpen: () -> Void
	let onAnnotate: () -> Void

	var body: some View {
		VStack(spacing: 8) {
			Button(action: onOpen) {
				pageImage
					.overlay { MarksOverlay(marks: capture.pageMarks) }
					.background(Color.paper)
					.clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
					.shadow(color: Color.bark.opacity(0.10), radius: 4, x: 0, y: 2)
					.shadow(color: Color.bark.opacity(0.10), radius: 14, x: 0, y: 12)
			}
			.buttonStyle(PressScaleStyle(scale: 0.98))
			.contextMenu {
				Button("Annotate", systemImage: "pencil.tip.crop.circle", action: onAnnotate)
			}
			.accessibilityLabel("Page \(number)")
			.accessibilityHint("Opens the full page")
			.accessibilityAction(named: "Annotate", onAnnotate)
			Text("Page \(number)")
				.font(FolioFont.ui(12))
				.foregroundStyle(.slate)
		}
	}

	@ViewBuilder
	private var pageImage: some View {
		if let image = capture.image ?? capture.thumbnail {
			let base = Image(uiImage: image).resizable().scaledToFit()
			switch look {
			case .color: base.contrast(1.05).saturation(1.08)
			case .gray: base.grayscale(1).contrast(1.05)
			case .blackAndWhite: base.grayscale(1).contrast(1.8)
			case .original: base
			}
		} else {
			PaperThumbnail(image: nil, width: 260, height: 340)
		}
	}
}
