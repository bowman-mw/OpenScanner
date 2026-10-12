//
//  WebPagePDF.swift
//  Rescriva (fork of Open Scanner)
//
//  Saves a web page as a PDF the way Safari prints one: a web view lays the page out for print
//  (the site's print styles apply) and a print renderer cuts it into sheets of Rescriva's paper.
//  A page sent from Safari arrives as the HTML Safari showed, so its scripts stay off; a link is
//  loaded fresh with scripts on. Both load in a private session that keeps no cookies.
//  App-target only.
//

import UIKit
import WebKit

enum WebPagePDFError: LocalizedError {
	case timedOut
	case nothingToPrint

	var errorDescription: String? {
		switch self {
		case .timedOut: return String(localized: "The page took too long to load.")
		case .nothingToPrint: return String(localized: "The page came out empty.")
		}
	}
}

@MainActor
final class WebPagePDF: NSObject, WKNavigationDelegate {
	static let loadTimeout: TimeInterval = 30
	/// Time a freshly loaded page gets for its scripts to fill it in.
	static let settleTime: Duration = .milliseconds(800)
	static let maxPages = 300
	/// Each side's margin, in points: half an inch, as Safari prints.
	static let margin: CGFloat = 36
	/// The window width a page lays out in before printing, so sites show their full layout.
	static let layoutWidth: CGFloat = 1024
	/// CSS pixels per point: the window is as tall as a sheet's printable area, so a page's
	/// viewport units (`vh`) measure the sheet, as when Safari prints.
	static let pixelsPerPoint: CGFloat = 96 / 72

	private let webView: WKWebView
	private var waiting: CheckedContinuation<Void, Error>?

	private init(javaScript: Bool, paper: CGSize) {
		let configuration = WKWebViewConfiguration()
		configuration.websiteDataStore = .nonPersistent()
		configuration.defaultWebpagePreferences.allowsContentJavaScript = javaScript
		configuration.suppressesIncrementalRendering = true
		let height = (paper.height - 2 * Self.margin) * Self.pixelsPerPoint
		webView = WKWebView(frame: CGRect(x: 0, y: 0, width: Self.layoutWidth, height: height), configuration: configuration)
		super.init()
		webView.navigationDelegate = self
	}

	/// The HTML Safari showed, its links and images resolved against `baseURL`.
	static func pdf(html: String, baseURL: URL?, paper: CGSize = preferredPaper) async throws -> Data {
		let page = WebPagePDF(javaScript: false, paper: paper)
		try await page.load { $0.loadHTMLString(html, baseURL: baseURL) }
		return try page.paginate(paper: paper)
	}

	/// The page at `url`, loaded fresh.
	static func pdf(loading url: URL, paper: CGSize = preferredPaper) async throws -> Data {
		let page = WebPagePDF(javaScript: true, paper: paper)
		try await page.load { $0.load(URLRequest(url: url, timeoutInterval: loadTimeout)) }
		try await Task.sleep(for: settleTime)
		return try page.paginate(paper: paper)
	}

	/// The paper chosen for PDFs in Export; A4 or Letter by region when that's "Page size".
	nonisolated static var preferredPaper: CGSize {
		let stored = UserDefaults.standard.string(forKey: RescrivaPreference.pdfPaperSize).flatMap(PDFPaperSize.init(rawValue:))
		if let size = stored?.portraitSize { return size }
		let letterRegions: Set<String> = ["US", "CA", "MX", "PH", "CL", "CO", "VE"]
		let region = Locale.current.region?.identifier ?? "US"
		return (letterRegions.contains(region) ? PDFPaperSize.letter : .a4).portraitSize ?? CGSize(width: 612, height: 792)
	}

	// MARK: Loading

	private func load(_ start: (WKWebView) -> Void) async throws {
		let timeout = Task { [weak self] in
			try await Task.sleep(for: .seconds(Self.loadTimeout))
			self?.webView.stopLoading()
			self?.finish(WebPagePDFError.timedOut)
		}
		defer { timeout.cancel() }
		try await withCheckedThrowingContinuation { continuation in
			waiting = continuation
			start(webView)
		}
	}

	/// Resumes the waiting load once; later calls (a timeout after a failure) do nothing.
	private func finish(_ error: Error?) {
		guard let waiting else { return }
		self.waiting = nil
		if let error {
			waiting.resume(throwing: error)
		} else {
			waiting.resume()
		}
	}

	func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
		finish(nil)
	}

	func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: Error) {
		finish(error)
	}

	func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?, withError error: Error) {
		finish(error)
	}

	// MARK: Printing

	/// Cuts the laid-out page into sheets of `paper`, at most `maxPages`.
	private func paginate(paper: CGSize) throws -> Data {
		let sheet = CGRect(origin: .zero, size: paper)
		let renderer = SheetRenderer(paper: sheet, printable: sheet.insetBy(dx: Self.margin, dy: Self.margin))
		renderer.addPrintFormatter(webView.viewPrintFormatter(), startingAtPageAt: 0)
		let count = min(renderer.numberOfPages, Self.maxPages)
		guard count > 0 else { throw WebPagePDFError.nothingToPrint }
		let format = UIGraphicsPDFRendererFormat()
		format.documentInfo = [kCGPDFContextCreator as String: "Rescriva"]
		if let title = webView.title, !title.isEmpty {
			format.documentInfo[kCGPDFContextTitle as String] = title
		}
		renderer.prepare(forDrawingPages: NSRange(location: 0, length: count))
		return UIGraphicsPDFRenderer(bounds: sheet, format: format).pdfData { context in
			for page in 0..<count {
				context.beginPage()
				renderer.drawPage(at: page, in: context.pdfContextBounds)
			}
		}
	}
}

/// A print renderer with a fixed sheet, which the print system would otherwise choose.
private final class SheetRenderer: UIPrintPageRenderer {
	private let paper: CGRect
	private let printable: CGRect

	init(paper: CGRect, printable: CGRect) {
		self.paper = paper
		self.printable = printable
		super.init()
	}

	override var paperRect: CGRect { paper }
	override var printableRect: CGRect { printable }
}
