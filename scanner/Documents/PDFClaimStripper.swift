//
//  PDFClaimStripper.swift
//  Rescriva (fork of Open Scanner)
//
//  PDFKit's saves keep a PDF/A or PDF/X file's "I conform" metadata but drop
//  the colour profile (output intent) those standards need, and markup it adds
//  isn't tagged for PDF/UA. So an edited copy would claim a standard it no
//  longer meets. This removes the claims from the XMP packet and the Info
//  dictionary by appending an incremental update: the bytes PDFKit wrote stay
//  as they are, and the new metadata and Info objects supersede the old ones.
//
//  Works on PDFKit's own output: a classic cross-reference table, no object
//  streams, no encryption (PDF/A and PDF/X forbid encryption anyway). Anything
//  else is left alone.
//

import CoreGraphics
import Foundation

enum PDFClaimStripper {
	enum Outcome: Equatable {
		/// An update was appended; the file no longer makes the claims.
		case stripped
		/// The file made no claims to remove.
		case nothingToStrip
		/// The file's layout isn't one this can update safely (xref streams, encryption).
		case unsupported
	}

	/// Removes conformance claims from the PDF at `url` in place.
	static func stripClaims(inFileAt url: URL) throws -> Outcome {
		let data = try Data(contentsOf: url, options: .mappedIfSafe)
		guard let update = try update(for: data) else {
			return PDFFormatInspector.inspect(data: data)?.strippableClaims.isEmpty == false ? .unsupported : .nothingToStrip
		}
		guard !update.isEmpty else { return .nothingToStrip }
		let handle = try FileHandle(forWritingTo: url)
		defer { try? handle.close() }
		try handle.seekToEnd()
		try handle.write(contentsOf: update)
		return .stripped
	}

	/// The bytes to append to `data` to drop its claims: empty when there are none,
	/// nil when the file can't be updated safely.
	static func update(for data: Data) throws -> Data? {
		guard let trailer = Trailer.last(in: data), trailer.encrypt == nil,
			  let xref = CrossReference.parse(data, at: trailer.startXref) else { return nil }

		var objects: [(number: Int, generation: Int, body: Data)] = []

		// The XMP packet, decoded by Core Graphics, cleaned and written back uncompressed.
		if let catalogBody = xref.objectBody(trailer.root.number, in: data),
		   let metadata = Reference.find("Metadata", in: catalogBody),
		   let provider = CGDataProvider(data: data as CFData),
		   let document = CGPDFDocument(provider), let catalog = document.catalog,
		   let stream = CGPDF.stream(catalog, "Metadata"), let packet = CGPDF.data(stream),
		   let xmp = String(data: packet, encoding: .utf8) {
			let cleaned = cleanedXMP(xmp)
			if cleaned != xmp {
				let bytes = Data(cleaned.utf8)
				var body = Data("<< /Type /Metadata /Subtype /XML /Length \(bytes.count) >>\nstream\n".utf8)
				body.append(bytes)
				body.append(Data("\nendstream".utf8))
				objects.append((metadata.number, metadata.generation, body))
			}
		}

		// The Info dictionary's GTS_PDFX keys (PDF/X-1a and X-3 put their claim there).
		if let info = trailer.info, let infoBody = xref.objectBody(info.number, in: data),
		   let text = String(data: infoBody, encoding: .isoLatin1) {
			let cleaned = cleanedInfo(text)
			if cleaned != text, let bytes = cleaned.data(using: .isoLatin1) {
				objects.append((info.number, info.generation, bytes))
			}
		}

		guard !objects.isEmpty else { return Data() }
		return appendix(objects, after: data, trailer: trailer)
	}

	// MARK: Cleaning

	/// XMP namespaces whose properties are conformance claims. `pdfx:` also holds a file's
	/// custom Info keys, so only its GTS_PDFX properties go.
	private static let claimProperty = "(?:pdfaid|pdfuaid|pdfxid|pdfvtid|pdfe):[A-Za-z_]+|pdfx:GTS_PDFX[A-Za-z_]*"

	/// `xmp` without conformance claims, in element or attribute form. Namespace
	/// declarations and PDF/A extension schemas stay; they claim nothing.
	static func cleanedXMP(_ xmp: String) -> String {
		var text = xmp
		let element = "<(\(claimProperty))\\s*>[^<]*</\\1\\s*>"
		let empty = "<(?:\(claimProperty))\\s*/>"
		let attribute = "\\s(?:\(claimProperty))\\s*=\\s*(?:\"[^\"]*\"|'[^']*')"
		for pattern in [element, empty, attribute] {
			guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
			text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
		}
		return text
	}

	/// An Info dictionary's text without its PDF/X keys.
	static func cleanedInfo(_ info: String) -> String {
		let pattern = "/GTS_PDFX(?:Version|Conformance)\\s*(?:\\((?:\\\\.|[^\\\\)])*\\)|<[0-9A-Fa-f\\s]*>|/[^\\s/>]+)"
		guard let regex = try? NSRegularExpression(pattern: pattern) else { return info }
		return regex.stringByReplacingMatches(in: info, range: NSRange(info.startIndex..., in: info), withTemplate: "")
	}

	// MARK: Writing

	/// The update section: the replacement objects, a cross-reference subsection for each,
	/// and a trailer pointing back at the previous section.
	private static func appendix(_ objects: [(number: Int, generation: Int, body: Data)], after data: Data, trailer: Trailer) -> Data {
		var out = Data()
		if data.last != UInt8(ascii: "\n") { out.append(Data("\n".utf8)) }
		var offsets: [(number: Int, generation: Int, offset: Int)] = []
		for object in objects {
			offsets.append((object.number, object.generation, data.count + out.count))
			out.append(Data("\(object.number) \(object.generation) obj\n".utf8))
			out.append(object.body)
			out.append(Data("\nendobj\n".utf8))
		}
		let xrefOffset = data.count + out.count
		var table = "xref\n"
		for entry in offsets.sorted(by: { $0.number < $1.number }) {
			table += "\(entry.number) 1\n" + String(format: "%010d %05d n \n", entry.offset, entry.generation)
		}
		var dictionary = "/Size \(trailer.size) /Root \(trailer.root.text)"
		if let info = trailer.info { dictionary += " /Info \(info.text)" }
		if let id = trailer.id { dictionary += " /ID \(id)" }
		dictionary += " /Prev \(trailer.startXref)"
		table += "trailer\n<< \(dictionary) >>\nstartxref\n\(xrefOffset)\n%%EOF\n"
		out.append(Data(table.utf8))
		return out
	}
}

// MARK: - Parsing PDFKit's file layout

/// An indirect reference, `12 0 R`.
private struct Reference {
	let number: Int
	let generation: Int
	var text: String { "\(number) \(generation) R" }

	/// The reference stored under `/key` in a dictionary's text.
	static func find(_ key: String, in body: Data) -> Reference? {
		guard let text = String(data: body, encoding: .isoLatin1),
			  let regex = try? NSRegularExpression(pattern: "/\(key)\\s+(\\d+)\\s+(\\d+)\\s+R"),
			  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
			  let number = Range(match.range(at: 1), in: text).flatMap({ Int(text[$0]) }),
			  let generation = Range(match.range(at: 2), in: text).flatMap({ Int(text[$0]) }) else { return nil }
		return Reference(number: number, generation: generation)
	}
}

/// The last trailer of a file with classic cross-reference tables.
private struct Trailer {
	var size: Int
	var root: Reference
	var info: Reference?
	var encrypt: Reference?
	/// The ID array's text, `[ <…> <…> ]`.
	var id: String?
	/// Where the last cross-reference section starts.
	var startXref: Int

	static func last(in data: Data) -> Trailer? {
		let tail = data.suffix(4096)
		guard let text = String(data: tail, encoding: .isoLatin1),
			  let startRange = text.range(of: "startxref", options: .backwards),
			  let startXref = Int(text[startRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
								.prefix { $0.isNumber }),
			  let trailerRange = text.range(of: "trailer", options: .backwards, range: text.startIndex..<startRange.lowerBound) else { return nil }
		let dictionary = Data(text[trailerRange.upperBound..<startRange.lowerBound].utf8)
		guard let dictionaryText = String(data: dictionary, encoding: .isoLatin1),
			  let size = firstInt(after: "/Size", in: dictionaryText),
			  let root = Reference.find("Root", in: dictionary) else { return nil }
		var id: String?
		if let regex = try? NSRegularExpression(pattern: "/ID\\s*(\\[[^\\]]*\\])"),
		   let match = regex.firstMatch(in: dictionaryText, range: NSRange(dictionaryText.startIndex..., in: dictionaryText)),
		   let range = Range(match.range(at: 1), in: dictionaryText) {
			id = String(dictionaryText[range]).replacingOccurrences(of: "\n", with: " ")
		}
		return Trailer(size: size, root: root, info: Reference.find("Info", in: dictionary),
					   encrypt: Reference.find("Encrypt", in: dictionary), id: id, startXref: startXref)
	}

	private static func firstInt(after key: String, in text: String) -> Int? {
		guard let range = text.range(of: key) else { return nil }
		return Int(text[range.upperBound...].trimmingCharacters(in: .whitespaces).prefix { $0.isNumber })
	}
}

/// Object offsets from a chain of classic cross-reference sections.
private struct CrossReference {
	private var offsets: [Int: Int] = [:]

	/// Reads the section at `offset` and every earlier one its trailer's /Prev points at.
	/// Nil when a section isn't a classic table (an xref stream).
	static func parse(_ data: Data, at offset: Int) -> CrossReference? {
		var table = CrossReference()
		var next: Int? = offset
		var visited = Set<Int>()
		while let start = next, !visited.contains(start), start >= 0, start < data.count {
			visited.insert(start)
			guard let section = parseSection(data, at: start) else { return nil }
			for (number, objectOffset) in section.entries where table.offsets[number] == nil {
				table.offsets[number] = objectOffset
			}
			next = section.previous
		}
		return table.offsets.isEmpty ? nil : table
	}

	private static func parseSection(_ data: Data, at start: Int) -> (entries: [(Int, Int)], previous: Int?)? {
		let bytes = data[(data.startIndex + start)...]
		guard bytes.starts(with: Data("xref".utf8)) else { return nil }
		let text = String(decoding: bytes.prefix(1_048_576), as: UTF8.self)
		var entries: [(Int, Int)] = []
		var lines = text.split(whereSeparator: \.isNewline).dropFirst().makeIterator()
		var trailerText = ""
		while let line = lines.next() {
			let fields = line.split(separator: " ")
			if line.hasPrefix("trailer") {
				trailerText = String(line)
				while let more = lines.next(), !more.hasPrefix("startxref") { trailerText += " " + more }
				break
			}
			guard fields.count == 2, let first = Int(fields[0]), let count = Int(fields[1]) else { return nil }
			for index in 0..<count {
				guard let entry = lines.next() else { return nil }
				let parts = entry.split(separator: " ")
				if parts.count >= 3, parts[2].hasPrefix("n"), let objectOffset = Int(parts[0]) {
					entries.append((first + index, objectOffset))
				}
			}
		}
		var previous: Int?
		if let range = trailerText.range(of: "/Prev") {
			previous = Int(trailerText[range.upperBound...].trimmingCharacters(in: .whitespaces).prefix { $0.isNumber })
		}
		return (entries, previous)
	}

	/// The text between `N G obj` and `endobj` for object `number`.
	func objectBody(_ number: Int, in data: Data) -> Data? {
		guard let offset = offsets[number], offset < data.count else { return nil }
		let slice = data[(data.startIndex + offset)...].prefix(262_144)
		guard let objRange = slice.range(of: Data("obj".utf8)),
			  let endRange = slice.range(of: Data("endobj".utf8), in: objRange.upperBound..<slice.endIndex) else { return nil }
		return Data(slice[objRange.upperBound..<endRange.lowerBound]).trimmingWhitespace()
	}
}

private extension Data {
	func trimmingWhitespace() -> Data {
		let isSpace: (UInt8) -> Bool = { $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }
		guard let first = firstIndex(where: { !isSpace($0) }), let last = lastIndex(where: { !isSpace($0) }) else { return Data() }
		return Data(self[first...last])
	}
}
