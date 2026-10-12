//
//  PDFFormatInspector.swift
//  Rescriva (fork of Open Scanner)
//
//  Reads what kind of PDF a file says it is: the ISO subsets (PDF/A, /X, /E,
//  /VT, /UA, /R), tags, form fields and XFA, layers, 3D and encryption, so the
//  viewer can label it, warn before edits and explain what it can't show.
//  Claims are what the file says about itself, not a validation.
//
//  Core Graphics and PDFKit (no UIKit), so it also runs in the macOS test harness.
//

import CoreGraphics
import Foundation
import PDFKit

/// A conformance claim a PDF makes in its metadata, e.g. PDF/A-2b.
struct PDFConformanceClaim: Hashable {
	enum Standard: String, CaseIterable {
		case a = "PDF/A", x = "PDF/X", e = "PDF/E", vt = "PDF/VT", ua = "PDF/UA", r = "PDF/R"

		/// What the standard is for, in a few words.
		var purpose: String {
			switch self {
			case .a: return String(localized: "Archiving")
			case .x: return String(localized: "Printing")
			case .e: return String(localized: "Engineering drawings")
			case .vt: return String(localized: "Personalized print runs")
			case .ua: return String(localized: "Accessibility")
			case .r: return String(localized: "Scanned pages")
			}
		}
	}

	let standard: Standard
	/// What follows the standard's name: "2b", "4", "1a", "1.0".
	let version: String

	/// "PDF/A-2b".
	var label: String { version.isEmpty ? standard.rawValue : "\(standard.rawValue)-\(version)" }
}

/// How a PDF uses XFA, Adobe's XML form technology (deprecated in PDF 2.0).
enum XFAKind: String {
	/// XFA plus standard AcroForm fields: fillable once the XFA part is dropped.
	case hybrid
	/// XFA with drawn pages but no standard fields: it shows, but can't be filled.
	case staticOnly
	/// The pages are drawn from XFA at open time; PDFKit only shows a placeholder.
	case dynamic
}

/// What a PDF says about itself.
struct PDFFormatReport: Equatable {
	/// "1.7".
	var version = ""
	var pageCount = 0
	var claims: [PDFConformanceClaim] = []
	/// Has a structure tree (tags), the basis of PDF/UA.
	var isTagged = false
	var formFieldCount = 0
	var xfa: XFAKind?
	/// Has an output intent (the colour profile PDF/A and PDF/X rely on).
	var hasOutputIntent = false
	/// Has optional content (layers), drawn in their default state.
	var hasLayers = false
	/// Has 3D or rich media annotations, which PDFKit doesn't draw.
	var has3D = false
	var isEncrypted = false

	/// The claims Rescriva's saves can't keep true: every one but PDF/R, which
	/// lives in the file header that a save rewrites anyway.
	var strippableClaims: [PDFConformanceClaim] { claims.filter { $0.standard != .r } }

	func claim(_ standard: PDFConformanceClaim.Standard) -> PDFConformanceClaim? {
		claims.first { $0.standard == standard }
	}
}

enum PDFFormatInspector {
	/// Pages checked for 3D annotations; enough to catch PDF/E models, cheap on 5,000-page PDF/VT runs.
	static let annotationScanLimit = 100

	static func inspect(url: URL) -> PDFFormatReport? {
		guard let document = CGPDFDocument(url as CFURL) else { return nil }
		let header = (try? FileHandle(forReadingFrom: url)).flatMap { handle -> Data? in
			defer { try? handle.close() }
			return try? handle.read(upToCount: 1024)
		}
		return inspect(document, header: header ?? Data(), pdf: PDFDocument(url: url))
	}

	static func inspect(data: Data) -> PDFFormatReport? {
		guard let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider) else { return nil }
		return inspect(document, header: data.prefix(1024), pdf: PDFDocument(data: data))
	}

	/// `pdf` is the same file opened in PDFKit, for its annotations.
	static func inspect(_ document: CGPDFDocument, header: Data, pdf: PDFDocument?) -> PDFFormatReport {
		var report = PDFFormatReport()
		var major: Int32 = 0
		var minor: Int32 = 0
		document.getVersion(majorVersion: &major, minorVersion: &minor)
		report.version = "\(major).\(minor)"
		report.isEncrypted = document.isEncrypted
		report.pageCount = document.numberOfPages
		if let raster = rasterVersion(in: header) {
			report.claims.append(PDFConformanceClaim(standard: .r, version: raster))
		}
		// An encrypted file still has a readable catalog once unlocked; Core Graphics tries the empty password itself.
		guard document.isUnlocked, let catalog = document.catalog else { return report }

		let xmp = CGPDF.stream(catalog, "Metadata").flatMap(CGPDF.data).flatMap { String(data: $0, encoding: .utf8) }
		let info = document.info
		report.claims.append(contentsOf: claims(xmp: xmp ?? "", info: info))

		report.isTagged = CGPDF.dictionary(catalog, "StructTreeRoot") != nil
			|| CGPDF.dictionary(catalog, "MarkInfo").map { CGPDF.bool($0, "Marked") } == true
		report.hasOutputIntent = CGPDF.array(catalog, "OutputIntents").map { CGPDFArrayGetCount($0) > 0 } ?? false
		report.hasLayers = CGPDF.dictionary(catalog, "OCProperties") != nil

		if let form = CGPDF.dictionary(catalog, "AcroForm") {
			report.formFieldCount = CGPDF.array(form, "Fields").map { CGPDFArrayGetCount($0) } ?? 0
			if CGPDF.hasKey(form, "XFA") {
				if CGPDF.bool(catalog, "NeedsRendering") {
					report.xfa = .dynamic
				} else {
					report.xfa = report.formFieldCount > 0 ? .hybrid : .staticOnly
				}
			}
		}
		report.has3D = containsRichAnnotations(pdf)
		return report
	}

	// MARK: Claims

	/// The conformance claims in `xmp` (the catalog's XMP packet) and the Info dictionary.
	static func claims(xmp: String, info: CGPDFDictionaryRef?) -> [PDFConformanceClaim] {
		var claims: [PDFConformanceClaim] = []
		if let part = xmpValue("pdfaid:part", in: xmp) {
			let conformance = xmpValue("pdfaid:conformance", in: xmp)?.lowercased() ?? ""
			claims.append(PDFConformanceClaim(standard: .a, version: part + conformance))
		}
		let pdfx = xmpValue("pdfxid:GTS_PDFXVersion", in: xmp) ?? xmpValue("pdfx:GTS_PDFXVersion", in: xmp)
			?? info.flatMap { CGPDF.text($0, "GTS_PDFXConformance") ?? CGPDF.text($0, "GTS_PDFXVersion") }
		if let pdfx, let version = version(of: pdfx, prefix: "PDF/X-") {
			claims.append(PDFConformanceClaim(standard: .x, version: version))
		}
		if let pdfe = xmpValue("pdfe:ISO_PDFEVersion", in: xmp), let version = version(of: pdfe, prefix: "PDF/E-") {
			claims.append(PDFConformanceClaim(standard: .e, version: version))
		}
		if let pdfvt = xmpValue("pdfvtid:GTS_PDFVTVersion", in: xmp), let version = version(of: pdfvt, prefix: "PDF/VT-") {
			claims.append(PDFConformanceClaim(standard: .vt, version: version))
		}
		if let part = xmpValue("pdfuaid:part", in: xmp) {
			claims.append(PDFConformanceClaim(standard: .ua, version: part))
		}
		return claims
	}

	/// A property's value, written either as an element (`<pdfaid:part>2</pdfaid:part>`) or as
	/// an attribute (`pdfaid:part="2"`).
	static func xmpValue(_ property: String, in xmp: String) -> String? {
		let escaped = NSRegularExpression.escapedPattern(for: property)
		let patterns = ["<\(escaped)>\\s*([^<]*?)\\s*</\(escaped)>", "\(escaped)\\s*=\\s*[\"']([^\"']*)[\"']"]
		for pattern in patterns {
			guard let regex = try? NSRegularExpression(pattern: pattern),
				  let match = regex.firstMatch(in: xmp, range: NSRange(xmp.startIndex..., in: xmp)),
				  let range = Range(match.range(at: 1), in: xmp) else { continue }
			let value = xmp[range].trimmingCharacters(in: .whitespacesAndNewlines)
			if !value.isEmpty { return value }
		}
		return nil
	}

	/// "PDF/X-1a:2001" → "1a"; "PDF/E-1" → "1". Nil when `value` doesn't start with `prefix`.
	static func version(of value: String, prefix: String) -> String? {
		guard value.uppercased().hasPrefix(prefix.uppercased()) else { return nil }
		let rest = value.dropFirst(prefix.count)
		return String(rest.prefix { $0 != ":" && !$0.isWhitespace })
	}

	/// PDF/R files say so in a header comment: `%PDF-raster-1.0`.
	static func rasterVersion(in header: Data) -> String? {
		guard let text = String(data: header, encoding: .isoLatin1), let range = text.range(of: "%PDF-raster-") else { return nil }
		let version = text[range.upperBound...].prefix { $0.isNumber || $0 == "." }
		return version.isEmpty ? nil : String(version)
	}

	// MARK: Annotations

	/// True when an early page carries a 3D or rich media annotation.
	private static func containsRichAnnotations(_ document: PDFDocument?) -> Bool {
		guard let document, !document.isLocked else { return false }
		for index in 0..<min(document.pageCount, annotationScanLimit) {
			guard let page = document.page(at: index) else { continue }
			if page.annotations.contains(where: { $0.type == "3D" || $0.type == "RichMedia" }) { return true }
		}
		return false
	}
}

/// Small typed readers over Core Graphics' PDF object model.
enum CGPDF {
	static func dictionary(_ dictionary: CGPDFDictionaryRef, _ key: String) -> CGPDFDictionaryRef? {
		var value: CGPDFDictionaryRef?
		return CGPDFDictionaryGetDictionary(dictionary, key, &value) ? value : nil
	}

	static func array(_ dictionary: CGPDFDictionaryRef, _ key: String) -> CGPDFArrayRef? {
		var value: CGPDFArrayRef?
		return CGPDFDictionaryGetArray(dictionary, key, &value) ? value : nil
	}

	static func stream(_ dictionary: CGPDFDictionaryRef, _ key: String) -> CGPDFStreamRef? {
		var value: CGPDFStreamRef?
		return CGPDFDictionaryGetStream(dictionary, key, &value) ? value : nil
	}

	static func bool(_ dictionary: CGPDFDictionaryRef, _ key: String) -> Bool {
		var value: CGPDFBoolean = 0
		return CGPDFDictionaryGetBoolean(dictionary, key, &value) && value != 0
	}

	static func text(_ dictionary: CGPDFDictionaryRef, _ key: String) -> String? {
		var value: CGPDFStringRef?
		guard CGPDFDictionaryGetString(dictionary, key, &value), let value else { return nil }
		return CGPDFStringCopyTextString(value) as String?
	}

	static func hasKey(_ dictionary: CGPDFDictionaryRef, _ key: String) -> Bool {
		var value: CGPDFObjectRef?
		return CGPDFDictionaryGetObject(dictionary, key, &value)
	}

	/// A stream's decoded bytes.
	static func data(_ stream: CGPDFStreamRef) -> Data? {
		var format = CGPDFDataFormat.raw
		return CGPDFStreamCopyData(stream, &format) as Data?
	}
}
