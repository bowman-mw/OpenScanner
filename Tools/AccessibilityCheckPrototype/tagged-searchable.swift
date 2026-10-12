// tagged-searchable.swift — sketch of a tagged SearchablePDF page via UIGraphicsPDFRenderer (iOS):
// page image wrapped in NonStruct (no Artifact API), invisible OCR text inside H1/P, a figure crop in Figure+Alt.
import UIKit
import CoreText
let out = URL(fileURLWithPath: CommandLine.arguments[1])
func tag(_ c: CGContext, _ t: CGPDFTagType, _ p: [CGPDFTagProperty: String] = [:], _ body: () -> Void) {
	let d = NSMutableDictionary(); p.forEach { d[$0.key.rawValue] = $0.value }
	CGPDFContextBeginTag(c, t, d as CFDictionary); body(); CGPDFContextEndTag(c)
}
func invisible(_ s: String, _ r: CGRect, _ c: CGContext) {
	let font = CTFontCreateWithName("Helvetica" as CFString, r.height * 0.82, nil)
	let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [.font: font]))
	c.saveGState(); c.setTextDrawingMode(.invisible); c.textMatrix = .identity
	c.translateBy(x: r.minX, y: r.maxY); c.scaleBy(x: 1, y: -1); c.textPosition = .zero; CTLineDraw(line, c); c.restoreGState()
}
let img = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 780)).image { ctx in
	UIColor.white.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 600, height: 780))
	UIColor.darkGray.setFill(); ctx.fill(CGRect(x: 40, y: 300, width: 200, height: 150))
}
let fmt = UIGraphicsPDFRendererFormat()
fmt.documentInfo = [kCGPDFContextTitle as String: "Tagged Scan", kCGPDFContextCreator as String: "Rescriva"]
let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792), format: fmt).pdfData { ctx in
	ctx.beginPage()
	let c = ctx.cgContext
	tag(c, .nonStructure) { img.draw(in: CGRect(x: 6, y: 6, width: 600, height: 780)) }
	tag(c, .header1) { invisible("Quarterly Report", CGRect(x: 46, y: 60, width: 300, height: 24), c) }
	tag(c, .paragraph) { invisible("Revenue grew in every region.", CGRect(x: 46, y: 100, width: 400, height: 14), c) }
	tag(c, .figure, [.alternativeText: "Chart: revenue by region"]) {
		img.cgImage!.cropping(to: CGRect(x: 40, y: 300, width: 200, height: 150)).map { UIImage(cgImage: $0).draw(in: CGRect(x: 46, y: 306, width: 200, height: 150)) }
	}
}
try! data.write(to: out)
print("wrote \(out.lastPathComponent)")
