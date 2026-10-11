// gen.swift — makes the two test PDFs for the accessibility-check PoC.
//  untagged.pdf : what SearchablePDF makes today (image + invisible Helvetica text), plus an image-only page.
//  tagged.pdf   : CGPDFContextBeginTag output (H1, P, Figure+Alt, Figure without Alt, H3 skip, Table, List),
//                 XMP via CGPDFContextAddDocumentMetadata, outline via CGPDFContextSetOutline, one link annotation.
import Foundation
import CoreGraphics
import CoreText

let dir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

func makeImage(_ w: Int, _ h: Int) -> CGImage {
	let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
						space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
	ctx.setFillColor(CGColor(red: 0.95, green: 0.94, blue: 0.9, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
	ctx.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1))
	for row in 0..<20 { ctx.fill(CGRect(x: 40, y: h - 60 - row * 30, width: w - 80 - (row % 3) * 60, height: 12)) }
	return ctx.makeImage()!
}

func text(_ s: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat, _ ctx: CGContext, invisible: Bool = false) {
	let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
	let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
	ctx.saveGState()
	if invisible { ctx.setTextDrawingMode(.invisible) }
	ctx.textMatrix = .identity
	ctx.textPosition = CGPoint(x: x, y: y)
	CTLineDraw(line, ctx)
	ctx.restoreGState()
}

func tag(_ ctx: CGContext, _ type: CGPDFTagType, _ props: [CGPDFTagProperty: String]? = nil, _ body: () -> Void) {
	// Keys must be the raw CFStrings: bridging [CGPDFTagProperty: String] boxes the keys and Quartz silently drops them.
	let bridged = ProcessInfo.processInfo.environment["NAIVE_BRIDGE"] != nil
	if bridged { CGPDFContextBeginTag(ctx, type, (props ?? [:]) as CFDictionary) } else {
		let d = NSMutableDictionary(); props?.forEach { d[$0.key.rawValue] = $0.value }
		CGPDFContextBeginTag(ctx, type, d as CFDictionary)
	}
	body()
	CGPDFContextEndTag(ctx)
}

let image = makeImage(600, 780)
var box = CGRect(x: 0, y: 0, width: 612, height: 792)

// (a) Untagged, SearchablePDF-style.
do {
	let url = URL(fileURLWithPath: dir).appendingPathComponent("untagged.pdf") as CFURL
	let ctx = CGContext(url, mediaBox: &box, [kCGPDFContextTitle: "Untagged Scan", kCGPDFContextCreator: "Folio PoC"] as CFDictionary)!
	ctx.beginPDFPage(nil)
	ctx.draw(image, in: CGRect(x: 6, y: 6, width: 600, height: 780))
	text("Quarterly report heading", 46, 720, 14, ctx, invisible: true)
	text("Body line recognized by OCR", 46, 690, 12, ctx, invisible: true)
	ctx.endPDFPage()
	ctx.beginPDFPage(nil) // image-only page (OCR found nothing)
	ctx.draw(image, in: CGRect(x: 6, y: 6, width: 600, height: 780))
	ctx.endPDFPage()
	ctx.closePDF()
}

// (b) Tagged via CGPDFContextBeginTag.
do {
	let url = URL(fileURLWithPath: dir).appendingPathComponent("tagged.pdf") as CFURL
	// "Lang" is not a documented aux key; included to see if Quartz passes it through to the catalog (it should not).
	let aux: [CFString: Any] = [kCGPDFContextTitle: "Tagged Sample", kCGPDFContextCreator: "Folio PoC", "Lang" as CFString: "en-US"]
	let ctx = CGContext(url, mediaBox: &box, aux as CFDictionary)!
	let xmp = """
	<?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
	<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
	<rdf:Description rdf:about="" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:pdfuaid="http://www.aiim.org/pdfua/ns/id/">
	<dc:title><rdf:Alt><rdf:li xml:lang="x-default">Tagged Sample</rdf:li></rdf:Alt></dc:title>
	<pdfuaid:part>1</pdfuaid:part></rdf:Description></rdf:RDF></x:xmpmeta>
	<?xpacket end="w"?>
	"""
	ctx.addDocumentMetadata(xmp.data(using: .utf8)! as CFData)
	CGPDFContextSetOutline(ctx, [kCGPDFOutlineChildren: [[kCGPDFOutlineTitle: "Annual Report", kCGPDFOutlineDestination: 1] as CFDictionary]] as CFDictionary)
	ctx.beginPDFPage(nil)
	tag(ctx, .document, [.languageText: "en-US"]) {
		tag(ctx, .header1) { text("Annual Report", 50, 740, 24, ctx) }
		tag(ctx, .paragraph) { text("This paragraph is tagged as P.", 50, 710, 12, ctx) }
		tag(ctx, .figure, [.alternativeText: "Bar chart of revenue by quarter"]) {
			ctx.draw(image, in: CGRect(x: 50, y: 560, width: 120, height: 130))
		}
		tag(ctx, .figure) { ctx.draw(image, in: CGRect(x: 200, y: 560, width: 120, height: 130)) } // seeded defect: no Alt
		tag(ctx, .header3) { text("Skipped to H3", 50, 530, 16, ctx) } // seeded defect: H1 -> H3
		tag(ctx, .table) {
			tag(ctx, .tableRow) {
				tag(ctx, .tableHeaderCell) { text("Quarter", 50, 500, 11, ctx) }
				tag(ctx, .tableHeaderCell) { text("Revenue", 150, 500, 11, ctx) }
			}
			tag(ctx, .tableRow) {
				tag(ctx, .tableDataCell) { text("Q1", 50, 485, 11, ctx) }
				tag(ctx, .tableDataCell) { text("$10", 150, 485, 11, ctx) }
			}
		}
		tag(ctx, .list) {
			tag(ctx, .listItem) {
				tag(ctx, .label) { text("•", 50, 450, 11, ctx) }
				tag(ctx, .listBody) { text("First item", 62, 450, 11, ctx) }
			}
		}
	}
	// Drawn after the Document tag closes — tests what Quartz does with content outside any pushed tag.
	ctx.setFillColor(CGColor(red: 0.8, green: 0.1, blue: 0.1, alpha: 1))
	ctx.fill(CGRect(x: 50, y: 40, width: 512, height: 2))
	ctx.setURL(URL(string: "https://example.com")! as CFURL, for: CGRect(x: 50, y: 50, width: 100, height: 14))
	ctx.endPDFPage()
	ctx.closePDF()
}
print("wrote untagged.pdf, tagged.pdf to \(dir)")
