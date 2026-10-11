//
//  PDFKitView.swift
//  Folio (fork of Open Scanner)
//
//  PDFKit's PDFView for SwiftUI. Reading: scroll, zoom, select text, fill form
//  fields, follow links, and find's matches. Markup: one finger draws (or
//  drags across text, or taps to place a note) and two fingers scroll. On wide
//  screens (iPad, the unfolded iPhone Duo) pages sit side by side like a book.
//

import PDFKit
import SwiftUI
import UIKit

/// A page to jump to once: a new token means "do it again".
struct PDFViewerRequest: Equatable {
	let page: Int
	let token = UUID()
}

struct PDFKitView: UIViewRepresentable {
	let session: PDFEditSession
	/// Two pages side by side.
	var spread: Bool
	/// In a spread, the first page sits alone on the right like a cover.
	var coverPage: Bool
	var request: PDFViewerRequest?
	/// A tap with the text box or note tool: where (page space) and on which page.
	var onPlace: (PDFMarkupTool, CGPoint, PDFPage) -> Void
	/// A tap on a note or text box while reading, to open it.
	var onOpenAnnotation: (PDFAnnotation) -> Void

	func makeCoordinator() -> Coordinator { Coordinator(self) }

	func makeUIView(context: Context) -> PDFView {
		let view = PDFView()
		view.document = session.document
		view.displayDirection = .vertical
		view.displayMode = spread ? .twoUpContinuous : .singlePageContinuous
		view.displaysAsBook = coverPage
		view.autoScales = true
		view.pageShadowsEnabled = true
		view.backgroundColor = UIColor(Color.scanBackdrop)
		context.coordinator.attach(to: view)
		return view
	}

	func updateUIView(_ view: PDFView, context: Context) {
		let coordinator = context.coordinator
		coordinator.parent = self
		coordinator.setMarkup(session.mode == .markup && session.canMarkUp, tool: session.tool)
		if coordinator.lastRevision != session.revision {
			coordinator.lastRevision = session.revision
			view.layoutDocumentView()
			// Rotated or inserted pages change the widest page; fit the width again.
			DispatchQueue.main.async {
				view.autoScales = false
				view.autoScales = true
			}
		}
		let mode: PDFDisplayMode = spread ? .twoUpContinuous : .singlePageContinuous
		if view.displayMode != mode || view.displaysAsBook != coverPage {
			// Keep the reader's place across the change (folding, rotating).
			let page = view.currentPage
			view.displayMode = mode
			view.displaysAsBook = coverPage
			view.autoScales = true
			if let page {
				DispatchQueue.main.async { view.go(to: page) }
			}
		}
		if let request, request.token != coordinator.handledRequest {
			coordinator.handledRequest = request.token
			if let page = session.document.page(at: request.page) { view.go(to: page) }
		}
		coordinator.showFindResults(session.findResults, current: session.findIndex)
	}

	static func dismantleUIView(_ view: PDFView, coordinator: Coordinator) {
		coordinator.detach()
	}

	// MARK: - Coordinator

	@MainActor
	final class Coordinator: NSObject, UIGestureRecognizerDelegate {
		var parent: PDFKitView
		var lastRevision = -1
		var handledRequest: UUID?
		private var shownFind = ""

		private weak var view: PDFView?
		private let pan = UIPanGestureRecognizer()
		private let tap = UITapGestureRecognizer()
		private let overlay = CAShapeLayer()
		private var observers: [NSObjectProtocol] = []

		// The stroke in progress.
		private var page: PDFPage?
		private var pagePoints: [CGPoint] = []
		private var viewPoints: [CGPoint] = []
		private var erased: [(annotation: PDFAnnotation, page: PDFPage)] = []

		init(_ parent: PDFKitView) {
			self.parent = parent
		}

		func attach(to view: PDFView) {
			self.view = view
			pan.addTarget(self, action: #selector(handlePan(_:)))
			pan.maximumNumberOfTouches = 1
			pan.delegate = self
			pan.isEnabled = false
			tap.addTarget(self, action: #selector(handleTap(_:)))
			tap.delegate = self
			tap.isEnabled = false
			view.addGestureRecognizer(pan)
			view.addGestureRecognizer(tap)

			overlay.fillColor = nil
			overlay.lineCap = .round
			overlay.lineJoin = .round
			view.layer.addSublayer(overlay)

			let center = NotificationCenter.default
			observers.append(center.addObserver(forName: .PDFViewPageChanged, object: view, queue: .main) { [weak self] _ in
				MainActor.assumeIsolated { self?.pageChanged() }
			})
			observers.append(center.addObserver(forName: .PDFViewAnnotationHit, object: view, queue: .main) { [weak self] note in
				let annotation = note.userInfo?["PDFAnnotationHit"] as? PDFAnnotation
				MainActor.assumeIsolated { self?.annotationHit(annotation) }
			})
		}

		func detach() {
			observers.forEach(NotificationCenter.default.removeObserver)
			observers.removeAll()
		}

		/// Markup mode: one finger draws, two scroll.
		func setMarkup(_ enabled: Bool, tool: PDFMarkupTool) {
			pan.isEnabled = enabled && !tool.placesOnTap
			tap.isEnabled = enabled && (tool.placesOnTap || tool == .eraser)
			scrollView?.panGestureRecognizer.minimumNumberOfTouches = enabled ? 2 : 1
			if !enabled { clearStroke() }
		}

		private var scrollView: UIScrollView? {
			guard let view else { return nil }
			var queue: [UIView] = view.subviews
			while !queue.isEmpty {
				let next = queue.removeFirst()
				if let scroll = next as? UIScrollView { return scroll }
				queue.append(contentsOf: next.subviews)
			}
			return nil
		}

		/// Highlights every match and brings the current one into view.
		func showFindResults(_ results: [PDFSelection], current: Int?) {
			guard let view, parent.session.mode == .read else { return }
			let state = "\(results.count)-\(current ?? -1)"
			guard state != shownFind else { return }
			shownFind = state
			var shown = results
			if let current, results.indices.contains(current), let emphasized = results[current].copy() as? PDFSelection {
				// The match you're on, drawn stronger over the rest.
				emphasized.color = UIColor(Color.terracotta).withAlphaComponent(0.5)
				shown.append(emphasized)
				view.go(to: results[current])
			}
			view.highlightedSelections = shown.isEmpty ? nil : shown
		}

		private func pageChanged() {
			guard let view, let page = view.currentPage else { return }
			let index = parent.session.document.index(for: page)
			if index != NSNotFound { parent.session.currentPageIndex = index }
		}

		private func annotationHit(_ annotation: PDFAnnotation?) {
			guard parent.session.mode == .read, let annotation, annotation.type == "Text" || annotation.type == "FreeText" else { return }
			parent.onOpenAnnotation(annotation)
		}

		// MARK: Gestures

		func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
			false
		}

		@objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
			guard let view, let (page, point) = pagePoint(recognizer.location(in: view), in: view) else { return }
			let session = parent.session
			if session.tool == .eraser {
				session.erase(at: point, on: page)
			} else if session.tool.placesOnTap {
				parent.onPlace(session.tool, point, page)
			}
		}

		@objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
			guard let view else { return }
			let session = parent.session
			let location = recognizer.location(in: view)
			switch recognizer.state {
			case .began:
				// A pan begins only after the finger has moved a little; start the stroke where it touched down.
				let translation = recognizer.translation(in: view)
				let touchDown = CGPoint(x: location.x - translation.x, y: location.y - translation.y)
				guard let (page, start) = pagePoint(touchDown, in: view) else { return }
				self.page = page
				pagePoints = [start, view.convert(location, to: page)]
				viewPoints = [touchDown, location]
				let point = pagePoints[1]
				erased = []
				styleOverlay(for: session, scale: view.scaleFactor)
				if session.tool == .eraser { eraseLive(at: point, on: page) }
			case .changed:
				guard let page else { return }
				let point = view.convert(location, to: page)
				pagePoints.append(point)
				viewPoints.append(location)
				if session.tool.marksText {
					showSelection(on: page, in: view, session: session)
				} else if session.tool == .eraser {
					eraseLive(at: point, on: page)
				} else {
					drawOverlay(for: session.tool)
				}
			case .ended:
				finishStroke(in: view, session: session)
			default:
				if !erased.isEmpty { session.recordApplied(.removeAnnotations(erased)) }
				clearStroke()
			}
		}

		/// The page under `location` and the point on it, in page space.
		private func pagePoint(_ location: CGPoint, in view: PDFView) -> (PDFPage, CGPoint)? {
			guard let page = view.page(for: location, nearest: true) else { return nil }
			return (page, view.convert(location, to: page))
		}

		private func finishStroke(in view: PDFView, session: PDFEditSession) {
			defer { clearStroke() }
			guard let page, let start = pagePoints.first, let end = pagePoints.last else { return }
			let color = session.currentColor
			let size = session.currentSize
			switch session.tool {
			case .pen:
				if let ink = PDFMarkupFactory.ink(simplified(pagePoints), color: color, width: size) { session.add([ink], on: page) }
			case .highlighter:
				if let ink = PDFMarkupFactory.ink(simplified(pagePoints), color: color, width: size, alpha: PDFMarkupPalette.highlighterAlpha) {
					session.add([ink], on: page)
				}
			case .line, .arrow, .rectangle, .ellipse:
				if let shape = PDFMarkupFactory.shape(session.tool, from: start, to: end, color: color, width: size) { session.add([shape], on: page) }
			case .highlight, .underline, .strikeOut:
				if let selection = page.selection(from: start, to: end) {
					session.add(PDFMarkupFactory.textMarks(session.tool, over: selection, on: page, color: color), on: page)
				}
			case .eraser:
				if !erased.isEmpty { session.recordApplied(.removeAnnotations(erased)) }
			case .text, .note:
				break
			}
		}

		private func eraseLive(at point: CGPoint, on page: PDFPage) {
			guard let annotation = page.annotations.last(where: { PDFMarkupFactory.isErasable($0) && PDFMarkupFactory.hitTest($0, point) }) else { return }
			if let popup = annotation.popup { page.removeAnnotation(popup) }
			page.removeAnnotation(annotation)
			erased.append((annotation, page))
		}

		// MARK: Live feedback

		private func styleOverlay(for session: PDFEditSession, scale: CGFloat) {
			let tool = session.tool
			let alpha = tool == .highlighter ? PDFMarkupPalette.highlighterAlpha : 1
			overlay.strokeColor = session.currentColor.withAlphaComponent(alpha).cgColor
			overlay.lineWidth = max(session.currentSize * scale, 1)
			overlay.frame = view?.bounds ?? .zero
		}

		private func drawOverlay(for tool: PDFMarkupTool) {
			guard let start = viewPoints.first, let end = viewPoints.last else { return }
			let path = UIBezierPath()
			switch tool {
			case .pen, .highlighter:
				path.move(to: start)
				for point in viewPoints.dropFirst() { path.addLine(to: point) }
			case .line, .arrow:
				path.move(to: start)
				path.addLine(to: end)
			case .rectangle:
				path.append(UIBezierPath(rect: CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))))
			case .ellipse:
				path.append(UIBezierPath(ovalIn: CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))))
			default:
				break
			}
			CATransaction.begin()
			CATransaction.setDisableActions(true)
			overlay.path = path.cgPath
			CATransaction.commit()
		}

		private func showSelection(on page: PDFPage, in view: PDFView, session: PDFEditSession) {
			guard let start = pagePoints.first, let end = pagePoints.last, let selection = page.selection(from: start, to: end) else { return }
			selection.color = session.currentColor.withAlphaComponent(0.45)
			view.highlightedSelections = [selection]
		}

		private func clearStroke() {
			page = nil
			pagePoints = []
			viewPoints = []
			erased = []
			overlay.path = nil
			view?.highlightedSelections = nil
		}

		/// Drops points closer than half a point to the last kept one, so long strokes stay small.
		private func simplified(_ points: [CGPoint]) -> [CGPoint] {
			var kept: [CGPoint] = []
			for point in points {
				if let last = kept.last, hypot(point.x - last.x, point.y - last.y) < 0.5 { continue }
				kept.append(point)
			}
			if let last = points.last, kept.last != last { kept.append(last) }
			return kept
		}
	}
}
