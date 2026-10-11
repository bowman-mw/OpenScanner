//
//  PDFDocumentsTests.swift
//  Folio (fork of Open Scanner)
//
//  PDFs kept as PDFs: what the inspector reads (PDF/A, /X, /E, /VT, /UA, /R,
//  tags, XFA), removing claims an edited copy can't keep, the Library's
//  original-and-copy storage, page edits with undo, and the markup factory.
//

import PDFKit
import UIKit
import XCTest
@testable import scanner

@MainActor
final class PDFDocumentsTests: XCTestCase {
	private var folder: URL!

	override func setUpWithError() throws {
		folder = FileManager.default.temporaryDirectory.appendingPathComponent("PDFDocumentsTests-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
	}

	override func tearDownWithError() throws {
		try? FileManager.default.removeItem(at: folder)
	}

	// MARK: Inspector

	func testReadsEveryStandardsClaimFromXMPAndInfo() throws {
		let report = try XCTUnwrap(PDFFormatInspector.inspect(data: TestPDF.make(xmp: TestPDF.claimsXMP)))
		XCTAssertEqual(report.claims.map(\.label), ["PDF/X-4", "PDF/E-1", "PDF/VT-1", "PDF/UA-1"])

		let pdfa = try XCTUnwrap(PDFFormatInspector.inspect(data: TestPDF.make(xmp: TestPDF.xmp(#"<pdfaid:part>2</pdfaid:part><pdfaid:conformance>B</pdfaid:conformance>"#))))
		XCTAssertEqual(pdfa.claims.map(\.label), ["PDF/A-2b"])

		let x1a = try XCTUnwrap(PDFFormatInspector.inspect(data: TestPDF.make(info: "/GTS_PDFXVersion (PDF/X-1:2001) /GTS_PDFXConformance (PDF/X-1a:2001)")))
		XCTAssertEqual(x1a.claims.map(\.label), ["PDF/X-1a"])
	}

	func testReadsThePDFRHeader() throws {
		let report = try XCTUnwrap(PDFFormatInspector.inspect(data: TestPDF.make(header: "%PDF-1.4\n%PDF-raster-1.0\n")))
		XCTAssertEqual(report.claim(.r)?.label, "PDF/R-1.0")
		XCTAssertTrue(report.strippableClaims.isEmpty, "a save rewrites the header, so there's nothing to strip")
	}

	func testTellsTheThreeKindsOfXFAApart() throws {
		XCTAssertEqual(PDFFormatInspector.inspect(data: TestPDF.make(form: .hybrid))?.xfa, .hybrid)
		XCTAssertEqual(PDFFormatInspector.inspect(data: TestPDF.make(form: .staticOnly))?.xfa, .staticOnly)
		XCTAssertEqual(PDFFormatInspector.inspect(data: TestPDF.make(form: .dynamic))?.xfa, .dynamic)
		XCTAssertNil(PDFFormatInspector.inspect(data: TestPDF.make())?.xfa)
	}

	func testNoticesThreeDContent() throws {
		XCTAssertEqual(PDFFormatInspector.inspect(data: TestPDF.make(threeD: true))?.has3D, true)
		XCTAssertEqual(PDFFormatInspector.inspect(data: TestPDF.make())?.has3D, false)
	}

	func testNoticesTags() throws {
		let tagged = TestPDF.quartz { context in
			CGPDFContextBeginTag(context, .paragraph, [:] as CFDictionary)
			TestPDF.draw("Tagged", in: context)
			CGPDFContextEndTag(context)
		}
		XCTAssertEqual(PDFFormatInspector.inspect(data: tagged)?.isTagged, true)
		XCTAssertEqual(PDFFormatInspector.inspect(data: TestPDF.make())?.isTagged, false)
	}

	// MARK: Claim stripping

	func testEditedPDFALosesItsClaimButStaysReadable() throws {
		let pdfa = TestPDF.quartz(info: [kCGPDFContextCreatePDFA as String: true]) { TestPDF.draw("Archive", in: $0) }
		let before = try XCTUnwrap(PDFFormatInspector.inspect(data: pdfa))
		XCTAssertEqual(before.claim(.a)?.standard, .a)
		XCTAssertTrue(before.hasOutputIntent)

		// What PDFKit does to it: keeps the claim, drops the colour profile.
		let document = try XCTUnwrap(PDFDocument(data: pdfa))
		try document.page(at: 0)?.addAnnotation(XCTUnwrap(PDFMarkupFactory.ink([CGPoint(x: 10, y: 10), CGPoint(x: 90, y: 40)], color: .red, width: 2)))
		let url = folder.appendingPathComponent("edited.pdf")
		XCTAssertTrue(document.write(to: url))
		let resaved = try XCTUnwrap(PDFFormatInspector.inspect(url: url))
		XCTAssertNotNil(resaved.claim(.a))
		XCTAssertFalse(resaved.hasOutputIntent)

		XCTAssertEqual(try PDFClaimStripper.stripClaims(inFileAt: url), .stripped)
		XCTAssertNil(PDFFormatInspector.inspect(url: url)?.claim(.a))
		let reopened = try XCTUnwrap(PDFDocument(url: url))
		XCTAssertEqual(reopened.pageCount, 1)
		XCTAssertEqual(reopened.page(at: 0)?.annotations.filter { $0.type == "Ink" }.count, 1)
		XCTAssertEqual(try PDFClaimStripper.stripClaims(inFileAt: url), .nothingToStrip)
	}

	func testStripsXEVUAClaimsAfterAPDFKitSave() throws {
		let document = try XCTUnwrap(PDFDocument(data: TestPDF.make(xmp: TestPDF.claimsXMP)))
		let url = folder.appendingPathComponent("claims.pdf")
		XCTAssertTrue(document.write(to: url))
		XCTAssertEqual(PDFFormatInspector.inspect(url: url)?.claims.count, 4)
		XCTAssertEqual(try PDFClaimStripper.stripClaims(inFileAt: url), .stripped)
		XCTAssertEqual(PDFFormatInspector.inspect(url: url)?.claims, [])
		XCTAssertEqual(PDFDocument(url: url)?.string?.contains("Claims test"), true)
	}

	func testCleaningKeepsMetadataThatIsNotAClaim() {
		let cleaned = PDFClaimStripper.cleanedXMP(TestPDF.claimsXMP)
		XCTAssertFalse(cleaned.contains("GTS_PDFXVersion"))
		XCTAssertFalse(cleaned.contains("pdfuaid:part>"))
		XCTAssertTrue(cleaned.contains(#"pdfx:Customer="Acme""#))
		XCTAssertTrue(cleaned.contains("<dc:title>"))
		XCTAssertTrue(cleaned.contains(#"xmlns:pdfuaid="#), "namespace declarations stay")

		let info = PDFClaimStripper.cleanedInfo("<< /Title (Plan) /GTS_PDFXVersion (PDF/X-1:2001) /GTS_PDFXConformance (PDF/X-1a:2001) >>")
		XCTAssertEqual(info.replacingOccurrences(of: " ", with: ""), "<</Title(Plan)>>")
	}

	// MARK: Library

	func testSavingWritesACopyAndRevertRestoresTheOriginal() throws {
		let library = PDFLibrary(root: folder.appendingPathComponent("Library"))
		let source = folder.appendingPathComponent("Lease.pdf")
		try TestPDF.quartz(pages: 2) { TestPDF.draw("Lease terms", in: $0) }.write(to: source)
		let item = try awaitImport(source, into: library)
		XCTAssertEqual(item.title, "Lease")
		XCTAssertEqual(item.pageCount, 2)

		let session = try XCTUnwrap(PDFEditSession.open(item, in: library))
		let page = try XCTUnwrap(session.document.page(at: 0))
		session.add([PDFMarkupFactory.note(at: CGPoint(x: 72, y: 700), text: "Check this", color: .orange)], on: page)
		session.deletePages([1])
		XCTAssertTrue(session.needsSave)
		try session.save(in: library)

		let saved = try XCTUnwrap(library.item(item.id))
		XCTAssertTrue(saved.isEdited)
		XCTAssertEqual(saved.pageCount, 1)
		XCTAssertEqual(PDFDocument(url: library.editedURL(for: saved))?.pageCount, 1)
		XCTAssertEqual(PDFDocument(url: library.originalURL(for: saved))?.pageCount, 2, "the original is never changed")
		XCTAssertEqual(PDFDocument(url: source)?.pageCount, 2, "nor is the file it came from")

		try library.revertToOriginal(saved)
		XCTAssertFalse(try XCTUnwrap(library.item(item.id)).isEdited)
		XCTAssertEqual(library.currentURL(for: saved), library.originalURL(for: saved))

		// A fresh library reads the same items back from disk.
		XCTAssertEqual(PDFLibrary(root: folder.appendingPathComponent("Library")).items.map(\.id), [item.id])
	}

	func testHybridXFAFormSavesAsAStandardFillableForm() throws {
		let library = PDFLibrary(root: folder.appendingPathComponent("Library"))
		let source = folder.appendingPathComponent("Form.pdf")
		try TestPDF.make(form: .hybrid).write(to: source)
		let item = try awaitImport(source, into: library)
		let session = try XCTUnwrap(PDFEditSession.open(item, in: library))
		XCTAssertTrue(session.canFillForms)

		let field = try XCTUnwrap(session.document.page(at: 0)?.annotations.first { $0.type == "Widget" })
		field.widgetStringValue = "Ada Lovelace"
		XCTAssertTrue(session.needsSave)
		try session.save(in: library)

		XCTAssertNil(session.currentReport.xfa)
		XCTAssertEqual(session.currentReport.formFieldCount, 1)
		let reopened = try XCTUnwrap(PDFDocument(url: library.currentURL(for: XCTUnwrap(library.item(item.id)))))
		XCTAssertEqual(reopened.page(at: 0)?.annotations.first { $0.type == "Widget" }?.widgetStringValue, "Ada Lovelace")
	}

	func testDynamicXFAFormIsReadOnly() throws {
		let library = PDFLibrary(root: folder.appendingPathComponent("Library"))
		let source = folder.appendingPathComponent("Dynamic.pdf")
		try TestPDF.make(form: .dynamic).write(to: source)
		let session = try XCTUnwrap(PDFEditSession.open(awaitImport(source, into: library), in: library))
		XCTAssertFalse(session.canSave)
		XCTAssertFalse(session.canMarkUp)
		XCTAssertNotNil(session.readOnlyReason)
	}

	func testPasswordProtectedPDFKeepsItsPasswordWhenSaved() throws {
		let library = PDFLibrary(root: folder.appendingPathComponent("Library"))
		let source = folder.appendingPathComponent("Locked.pdf")
		try TestPDF.quartz(info: [kCGPDFContextUserPassword as String: "open sesame", kCGPDFContextOwnerPassword as String: "open sesame"]) {
			TestPDF.draw("Secret", in: $0)
		}.write(to: source)
		let item = try awaitImport(source, into: library)
		let session = try XCTUnwrap(PDFEditSession.open(item, in: library))
		XCTAssertTrue(session.isLocked)
		XCTAssertFalse(session.unlock(with: "wrong"))
		XCTAssertTrue(session.unlock(with: "open sesame"))
		XCTAssertTrue(session.canSave)

		session.add([PDFMarkupFactory.note(at: CGPoint(x: 50, y: 50), text: "Hi", color: .blue)], on: try XCTUnwrap(session.document.page(at: 0)))
		try session.save(in: library)
		let saved = try XCTUnwrap(PDFDocument(url: library.editedURL(for: XCTUnwrap(library.item(item.id)))))
		XCTAssertTrue(saved.isEncrypted)
		XCTAssertTrue(saved.isLocked)
		XCTAssertTrue(saved.unlock(withPassword: "open sesame"))
	}

	// MARK: Page edits

	func testPageEditsUndoBackToTheStart() throws {
		let document = try XCTUnwrap(PDFDocument(data: TestPDF.quartz(pages: 4) { TestPDF.draw("Page", in: $0) }))
		let session = PDFEditSession(item: PDFItem(id: UUID(), title: "T", sourceName: "T.pdf", importedAt: Date(), pageCount: 4, byteCount: 0),
									 document: document, report: PDFFormatReport(), originalReport: PDFFormatReport())
		let start = (0..<4).compactMap { document.page(at: $0) }

		session.movePage(from: 0, to: 3)
		XCTAssertTrue(document.page(at: 3) === start[0])
		session.rotate([1, 2], degrees: 90)
		XCTAssertEqual(document.page(at: 1)?.rotation, 90)
		session.deletePages([0, 2])
		XCTAssertEqual(document.pageCount, 2)
		session.insertBlankPage(at: 1)
		XCTAssertEqual(document.pageCount, 3)
		session.deletePages([0, 1, 2])
		XCTAssertEqual(document.pageCount, 3, "a PDF keeps at least one page")

		while session.canUndo { session.undo() }
		XCTAssertEqual((0..<document.pageCount).compactMap { document.page(at: $0) }.map(ObjectIdentifier.init), start.map(ObjectIdentifier.init))
		XCTAssertTrue(start.allSatisfy { $0.rotation == 0 })

		while session.canRedo { session.redo() }
		XCTAssertEqual(document.pageCount, 3)
	}

	func testInsertingAnotherPDFCopiesItsPages() throws {
		let document = try XCTUnwrap(PDFDocument(data: TestPDF.quartz(pages: 2) { TestPDF.draw("Mine", in: $0) }))
		let other = try XCTUnwrap(PDFDocument(data: TestPDF.quartz(pages: 3) { TestPDF.draw("Theirs", in: $0) }))
		let session = PDFEditSession(item: PDFItem(id: UUID(), title: "T", sourceName: "T.pdf", importedAt: Date(), pageCount: 2, byteCount: 0),
									 document: document, report: PDFFormatReport(), originalReport: PDFFormatReport())
		session.insertPages(of: other, at: 1)
		XCTAssertEqual(document.pageCount, 5)
		XCTAssertEqual(other.pageCount, 3, "the other PDF keeps its pages")
		XCTAssertEqual(document.page(at: 1)?.string?.contains("Theirs"), true)

		let extracted = try XCTUnwrap(session.extractedPDF([1, 2, 3]).flatMap(PDFDocument.init(data:)))
		XCTAssertEqual(extracted.pageCount, 3)
		XCTAssertEqual(document.pageCount, 5)
	}

	// MARK: Find

	func testFindReportsEveryMatchAndSteps() throws {
		let document = try XCTUnwrap(PDFDocument(data: TestPDF.quartz(pages: 3) { context in
			TestPDF.draw("Ferns and moss", in: context, at: CGPoint(x: 72, y: 700))
			TestPDF.draw("More fernS here", in: context, at: CGPoint(x: 72, y: 670))
		}))
		let session = PDFEditSession(item: PDFItem(id: UUID(), title: "T", sourceName: "T.pdf", importedAt: Date(), pageCount: 3, byteCount: 0),
									 document: document, report: PDFFormatReport(), originalReport: PDFFormatReport())
		session.find("ferns")
		let found = expectation(description: "search ends")
		Task {
			while session.isFinding { try? await Task.sleep(for: .milliseconds(20)) }
			found.fulfill()
		}
		wait(for: [found], timeout: 10)
		XCTAssertEqual(session.findResults.count, 6, "two per page, any case")
		XCTAssertEqual(session.findIndex, 0)
		session.showPreviousResult()
		XCTAssertEqual(session.findIndex, 5, "wraps to the last match")
		session.showNextResult()
		XCTAssertEqual(session.findIndex, 0)
		session.endFind()
		XCTAssertTrue(session.findResults.isEmpty)
	}

	// MARK: Markup

	func testInkIsDrawnWhereTheFingerWent() throws {
		let points = [CGPoint(x: 110, y: 110), CGPoint(x: 150, y: 130), CGPoint(x: 190, y: 140)]
		let ink = try XCTUnwrap(PDFMarkupFactory.ink(points, color: .black, width: 3))
		let path = try XCTUnwrap(ink.paths?.first)
		let drawn = path.bounds.offsetBy(dx: ink.bounds.minX, dy: ink.bounds.minY)
		XCTAssertEqual(drawn.minX, 110, accuracy: 0.5)
		XCTAssertEqual(drawn.maxX, 190, accuracy: 0.5)
		XCTAssertEqual(drawn.minY, 110, accuracy: 0.5)
		XCTAssertEqual(drawn.maxY, 140, accuracy: 0.5)
		XCTAssertTrue(ink.bounds.contains(drawn))
	}

	func testTextMarksFollowEachLineOfTheSelection() throws {
		let data = TestPDF.quartz { context in
			TestPDF.draw("First line of text", in: context, at: CGPoint(x: 72, y: 700))
			TestPDF.draw("Second line of text", in: context, at: CGPoint(x: 72, y: 670))
		}
		let page = try XCTUnwrap(PDFDocument(data: data)?.page(at: 0))
		let selection = try XCTUnwrap(page.selection(from: CGPoint(x: 70, y: 712), to: CGPoint(x: 200, y: 672)))
		let marks = PDFMarkupFactory.textMarks(.highlight, over: selection, on: page, color: .yellow)
		XCTAssertEqual(marks.count, 2)
		for mark in marks {
			XCTAssertEqual(mark.type, "Highlight")
			XCTAssertEqual(mark.quadrilateralPoints?.count, 4)
		}
	}

	func testShapesNeedARealDrag() {
		XCTAssertNil(PDFMarkupFactory.shape(.rectangle, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 11, y: 12), color: .red, width: 2))
		let arrow = PDFMarkupFactory.shape(.arrow, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 200, y: 160), color: .red, width: 2)
		XCTAssertEqual(arrow?.type, "Line")
		XCTAssertEqual(arrow?.endLineStyle, .openArrow)
		if let arrow {
			XCTAssertEqual(arrow.startPoint.x + arrow.bounds.minX, 100, accuracy: 0.01)
			XCTAssertEqual(arrow.endPoint.y + arrow.bounds.minY, 160, accuracy: 0.01)
		}
	}

	func testEraserTakesMarksButNotLinksOrFields() throws {
		let document = try XCTUnwrap(PDFDocument(data: TestPDF.quartz { TestPDF.draw("Erase", in: $0) }))
		let page = try XCTUnwrap(document.page(at: 0))
		let link = PDFAnnotation(bounds: CGRect(x: 100, y: 100, width: 50, height: 20), forType: .link, withProperties: nil)
		page.addAnnotation(link)
		let session = PDFEditSession(item: PDFItem(id: UUID(), title: "T", sourceName: "T.pdf", importedAt: Date(), pageCount: 1, byteCount: 0),
									 document: document, report: PDFFormatReport(), originalReport: PDFFormatReport())
		XCTAssertFalse(session.erase(at: CGPoint(x: 120, y: 110), on: page))
		session.add([try XCTUnwrap(PDFMarkupFactory.shape(.rectangle, from: CGPoint(x: 90, y: 90), to: CGPoint(x: 160, y: 130), color: .red, width: 2))], on: page)
		XCTAssertTrue(session.erase(at: CGPoint(x: 120, y: 110), on: page))
		XCTAssertEqual(page.annotations.map(\.type), ["Link"])
		session.undo()
		XCTAssertEqual(page.annotations.count, 2)
	}

	// MARK: Helpers

	private func awaitImport(_ url: URL, into library: PDFLibrary) throws -> PDFItem {
		let expectation = expectation(description: "import")
		var result: Result<PDFItem, Error>?
		Task {
			do { result = .success(try await library.importPDF(at: url)) } catch { result = .failure(error) }
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 10)
		return try XCTUnwrap(result).get()
	}
}

/// Small PDFs for the tests: hand-written ones for exact catalog contents, Quartz ones for real text.
enum TestPDF {
	enum Form { case hybrid, staticOnly, dynamic }

	static let claimsXMP = xmp("""
		<pdfe:ISO_PDFEVersion>PDF/E-1</pdfe:ISO_PDFEVersion>
		<pdfvtid:GTS_PDFVTVersion>PDF/VT-1</pdfvtid:GTS_PDFVTVersion>
		<pdfuaid:part>1</pdfuaid:part>
		<dc:title><rdf:Alt><rdf:li xml:lang="x-default">Claims</rdf:li></rdf:Alt></dc:title>
		""", attributes: #"pdfxid:GTS_PDFXVersion="PDF/X-4" pdfx:Customer="Acme""#)

	static func xmp(_ properties: String, attributes: String = "") -> String {
		"""
		<?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
		<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
		<rdf:Description rdf:about="" xmlns:pdfaid="http://www.aiim.org/pdfa/ns/id/" xmlns:pdfxid="http://www.npes.org/pdfx/ns/id/"
		 xmlns:pdfe="http://www.aiim.org/pdfe/ns/id/" xmlns:pdfvtid="http://www.npes.org/pdfvt/ns/id/"
		 xmlns:pdfuaid="http://www.aiim.org/pdfua/ns/id/" xmlns:pdfx="http://ns.adobe.com/pdfx/1.3/"
		 xmlns:dc="http://purl.org/dc/elements/1.1/" \(attributes)>
		\(properties)
		</rdf:Description></rdf:RDF></x:xmpmeta>
		<?xpacket end="w"?>
		"""
	}

	/// A one-page PDF written by hand, with optional XMP, extra Info keys and a form.
	static func make(xmp: String? = nil, info: String = "", form: Form? = nil, threeD: Bool = false, header: String = "%PDF-1.7\n") -> Data {
		var catalog = "<< /Type /Catalog /Pages 2 0 R"
		if xmp != nil { catalog += " /Metadata 6 0 R" }
		if form != nil { catalog += " /AcroForm 8 0 R" }
		if form == .dynamic { catalog += " /NeedsRendering true" }
		catalog += " >>"
		let annotRefs = (form == .hybrid ? ["9 0 R"] : []) + (threeD ? ["11 0 R"] : [])
		let annots = annotRefs.isEmpty ? "" : " /Annots [\(annotRefs.joined(separator: " "))]"
		let content = "BT /F1 18 Tf 72 720 Td (Claims test) Tj ET"
		let packet = xmp ?? ""
		let xfa = #"<xdp:xdp xmlns:xdp="http://ns.adobe.com/xdp/"><template/></xdp:xdp>"#
		let objects = [
			catalog,
			"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
			"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R\(annots) /Resources << /Font << /F1 5 0 R >> >> >>",
			"<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream",
			"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
			"<< /Type /Metadata /Subtype /XML /Length \(packet.utf8.count) >>\nstream\n\(packet)\nendstream",
			"<< /Title (Claims) /Producer (test) \(info) >>",
			"<< /Fields [\(form == .hybrid ? "9 0 R" : "")] /XFA 10 0 R /DA (/Helv 0 Tf 0 g) /DR << /Font << /Helv 5 0 R >> >> >>",
			"<< /Type /Annot /Subtype /Widget /FT /Tx /T (name) /Rect [72 650 300 674] /P 3 0 R /F 4 /DA (/Helv 12 Tf 0 g) /V (hello) >>",
			"<< /Length \(xfa.utf8.count) >>\nstream\n\(xfa)\nendstream",
			"<< /Type /Annot /Subtype /3D /Rect [100 100 300 300] /P 3 0 R >>",
		]
		var out = Data(header.utf8)
		var offsets: [Int] = []
		for (index, body) in objects.enumerated() {
			offsets.append(out.count)
			out.append(Data("\(index + 1) 0 obj\n\(body)\nendobj\n".utf8))
		}
		let xref = out.count
		var table = "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
		for offset in offsets { table += String(format: "%010d 00000 n \n", offset) }
		table += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R /Info 7 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
		out.append(Data(table.utf8))
		return out
	}

	/// A PDF drawn by Quartz, the way Folio's exporter writes them.
	static func quartz(pages: Int = 1, info: [String: Any] = [:], draw: (CGContext) -> Void) -> Data {
		let format = UIGraphicsPDFRendererFormat()
		format.documentInfo = info
		let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792), format: format)
		return renderer.pdfData { context in
			for _ in 0..<pages {
				context.beginPage()
				draw(context.cgContext)
			}
		}
	}

	/// Draws a line of text with its baseline at `point` (PDF space, origin bottom-left).
	static func draw(_ text: String, in context: CGContext, at point: CGPoint = CGPoint(x: 72, y: 700)) {
		let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: UIFont.systemFont(ofSize: 14)]))
		context.saveGState()
		// UIGraphicsPDFRenderer's context is flipped (origin top-left); draw text upright at the PDF point.
		context.translateBy(x: 0, y: 792)
		context.scaleBy(x: 1, y: -1)
		context.textPosition = point
		CTLineDraw(line, context)
		context.restoreGState()
	}
}
