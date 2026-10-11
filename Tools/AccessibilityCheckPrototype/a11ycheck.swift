// a11ycheck.swift — proof of concept: Acrobat-style accessibility checks with CoreGraphics' CGPDF* only.
// Usage: a11ycheck file.pdf [...]
import Foundation
import CoreGraphics

// MARK: - Tiny CGPDF helpers (CGPDF resolves indirect references for us; it never exposes object numbers)

extension CGPDFDictionaryRef {
	func name(_ k: String) -> String? { var p: UnsafePointer<CChar>?; return CGPDFDictionaryGetName(self, k, &p) ? p.map { String(cString: $0) } : nil }
	func dict(_ k: String) -> CGPDFDictionaryRef? { var d: CGPDFDictionaryRef?; return CGPDFDictionaryGetDictionary(self, k, &d) ? d : nil }
	func array(_ k: String) -> CGPDFArrayRef? { var a: CGPDFArrayRef?; return CGPDFDictionaryGetArray(self, k, &a) ? a : nil }
	func stream(_ k: String) -> CGPDFStreamRef? { var s: CGPDFStreamRef?; return CGPDFDictionaryGetStream(self, k, &s) ? s : nil }
	func int(_ k: String) -> Int? { var i: CGPDFInteger = 0; return CGPDFDictionaryGetInteger(self, k, &i) ? Int(i) : nil }
	func bool(_ k: String) -> Bool? { var b: CGPDFBoolean = 0; return CGPDFDictionaryGetBoolean(self, k, &b) ? b != 0 : nil }
	func string(_ k: String) -> String? { var s: CGPDFStringRef?; guard CGPDFDictionaryGetString(self, k, &s), let s else { return nil }; return CGPDFStringCopyTextString(s) as String? }
	func object(_ k: String) -> CGPDFObjectRef? { var o: CGPDFObjectRef?; return CGPDFDictionaryGetObject(self, k, &o) ? o : nil }
	func has(_ k: String) -> Bool { object(k) != nil }
	var keys: [String] { var r: [String] = []; CGPDFDictionaryApplyBlock(self, { key, _, _ in r.append(String(cString: key)); return true }, nil); return r }
}
extension CGPDFArrayRef {
	var count: Int { CGPDFArrayGetCount(self) }
	func object(_ i: Int) -> CGPDFObjectRef? { var o: CGPDFObjectRef?; return CGPDFArrayGetObject(self, i, &o) ? o : nil }
	func dict(_ i: Int) -> CGPDFDictionaryRef? { var d: CGPDFDictionaryRef?; return CGPDFArrayGetDictionary(self, i, &d) ? d : nil }
	func int(_ i: Int) -> Int? { var v: CGPDFInteger = 0; return CGPDFArrayGetInteger(self, i, &v) ? Int(v) : nil }
}
func asDict(_ o: CGPDFObjectRef) -> CGPDFDictionaryRef? { var d: CGPDFDictionaryRef?; return CGPDFObjectGetValue(o, .dictionary, &d) ? d : nil }
func asArray(_ o: CGPDFObjectRef) -> CGPDFArrayRef? { var a: CGPDFArrayRef?; return CGPDFObjectGetValue(o, .array, &a) ? a : nil }
func asInt(_ o: CGPDFObjectRef) -> Int? { var i: CGPDFInteger = 0; return CGPDFObjectGetValue(o, .integer, &i) ? Int(i) : nil }
func asName(_ o: CGPDFObjectRef) -> String? { var p: UnsafePointer<CChar>?; return CGPDFObjectGetValue(o, .name, &p) ? p.map { String(cString: $0) } : nil }
func asStream(_ o: CGPDFObjectRef) -> CGPDFStreamRef? { var s: CGPDFStreamRef?; return CGPDFObjectGetValue(o, .stream, &s) ? s : nil }
func key(_ d: CGPDFDictionaryRef) -> UnsafeRawPointer { unsafeBitCast(d, to: UnsafeRawPointer.self) } // identity: CGPDF caches resolved objects

func ver(_ d: CGPDFDocument) -> String { var a: Int32 = 0, b: Int32 = 0; d.getVersion(majorVersion: &a, minorVersion: &b); return "\(a).\(b)" }

// MARK: - Report

enum Status: String { case pass = "PASS", fail = "FAIL", manual = "MANUAL", na = "n/a" }
struct Finding { var category: String; var rule: String; var status: Status; var detail: String }
var findings: [Finding] = []
func report(_ c: String, _ r: String, _ s: Status, _ d: String = "") { findings.append(Finding(category: c, rule: r, status: s, detail: d)) }

// MARK: - Content-stream scan (marked content vs untagged painting)

final class PageScan {
	var mcStack: [(tag: String, mcid: Int?)] = []
	var gsStack: [Int] = [0] // text render mode per q/Q level
	var mcids: [Int] = []
	var textOps = 0, invisibleTextOps = 0, imageOps = 0, pathPaints = 0
	var untaggedText = 0, untaggedImages = 0, untaggedPaths = 0
	var artifactOps = 0
	var nestedMCID = 0
	var formDepth = 0
	var table: CGPDFOperatorTableRef!
	var inTagged: Bool { mcStack.contains { $0.mcid != nil || $0.tag == "Artifact" } }
	var inArtifact: Bool { mcStack.contains { $0.tag == "Artifact" } }
	func painted(_ kind: Int) { // 0 text, 1 image, 2 path
		if inArtifact { artifactOps += 1; return }
		if !inTagged { switch kind { case 0: untaggedText += 1; case 1: untaggedImages += 1; default: untaggedPaths += 1 } }
	}
}

func makeTable() -> CGPDFOperatorTableRef {
	let t = CGPDFOperatorTableCreate()!
	func info(_ p: UnsafeMutableRawPointer?) -> PageScan { Unmanaged<PageScan>.fromOpaque(p!).takeUnretainedValue() }
	CGPDFOperatorTableSetCallback(t, "BDC") { s, p in
		let ps = info(p)
		var props: CGPDFObjectRef?
		_ = CGPDFScannerPopObject(s, &props)
		var tagName: UnsafePointer<CChar>?
		_ = CGPDFScannerPopName(s, &tagName)
		var dict: CGPDFDictionaryRef? = props.flatMap(asDict)
		if dict == nil, let props, let n = asName(props), // named property list in /Properties
		   let res = CGPDFContentStreamGetResource(CGPDFScannerGetContentStream(s), "Properties", n) { dict = asDict(res) }
		let mcid = dict?.int("MCID")
		if mcid != nil, ps.mcStack.contains(where: { $0.mcid != nil }) { ps.nestedMCID += 1 }
		if let mcid { ps.mcids.append(mcid) }
		ps.mcStack.append((tagName.map { String(cString: $0) } ?? "?", mcid))
	}
	CGPDFOperatorTableSetCallback(t, "BMC") { s, p in
		var tagName: UnsafePointer<CChar>?; _ = CGPDFScannerPopName(s, &tagName)
		info(p).mcStack.append((tagName.map { String(cString: $0) } ?? "?", nil))
	}
	CGPDFOperatorTableSetCallback(t, "EMC") { _, p in _ = info(p).mcStack.popLast() }
	CGPDFOperatorTableSetCallback(t, "q") { _, p in let ps = info(p); ps.gsStack.append(ps.gsStack.last ?? 0) }
	CGPDFOperatorTableSetCallback(t, "Q") { _, p in let ps = info(p); if ps.gsStack.count > 1 { ps.gsStack.removeLast() } }
	CGPDFOperatorTableSetCallback(t, "Tr") { s, p in var m: CGPDFInteger = 0; if CGPDFScannerPopInteger(s, &m) { let ps = info(p); ps.gsStack[ps.gsStack.count - 1] = Int(m) } }
	for op in ["Tj", "TJ", "'", "\""] {
		CGPDFOperatorTableSetCallback(t, op) { _, p in
			let ps = info(p); ps.textOps += 1; if ps.gsStack.last == 3 { ps.invisibleTextOps += 1 }; ps.painted(0)
		}
	}
	for op in ["f", "F", "f*", "S", "s", "B", "B*", "b", "b*", "sh"] {
		CGPDFOperatorTableSetCallback(t, op) { _, p in let ps = info(p); ps.pathPaints += 1; ps.painted(2) }
	}
	CGPDFOperatorTableSetCallback(t, "BI") { _, p in let ps = info(p); ps.imageOps += 1; ps.painted(1) }
	CGPDFOperatorTableSetCallback(t, "Do") { s, p in
		let ps = info(p)
		var n: UnsafePointer<CChar>?
		guard CGPDFScannerPopName(s, &n), let n, let cs = Optional(CGPDFScannerGetContentStream(s)),
			  let obj = CGPDFContentStreamGetResource(cs, "XObject", n), let stream = asStream(obj),
			  let sd = CGPDFStreamGetDictionary(stream) else { return }
		if sd.name("Subtype") == "Image" { ps.imageOps += 1; ps.painted(1); return }
		guard sd.name("Subtype") == "Form", ps.formDepth < 8 else { return }
		// Recurse into the form XObject with the same marked-content stack.
		let child = CGPDFContentStreamCreateWithStream(stream, sd.dict("Resources") ?? CGPDFStreamGetDictionary(stream)!, cs)
		let sub = CGPDFScannerCreate(child, ps.table, p)
		ps.formDepth += 1; CGPDFScannerScan(sub); ps.formDepth -= 1
		CGPDFScannerRelease(sub); CGPDFContentStreamRelease(child)
	}
	return t
}

// MARK: - Structure tree

struct Elem { var type: String; var raw: String; var alt: String?; var actualText: String?; var lang: String?; var attrs: CGPDFObjectRef?; var children: [Elem] = []; var mcids: [(page: Int?, mcid: Int)] = []; var objrs = 0 }

func walk(_ d: CGPDFDictionaryRef, roleMap: CGPDFDictionaryRef?, pageIndex: [UnsafeRawPointer: Int], inheritedPg: Int?, depth: Int) -> Elem {
	let raw = d.name("S") ?? "?"
	var type = raw
	var hops = 0
	while let rm = roleMap, let mapped = rm.name(type), hops < 10 { type = mapped; hops += 1 }
	let pg = d.dict("Pg").flatMap { pageIndex[key($0)] } ?? inheritedPg
	var e = Elem(type: type, raw: raw, alt: d.string("Alt"), actualText: d.string("ActualText"), lang: d.string("Lang"), attrs: d.object("A"))
	guard depth < 100, let k = d.object("K") else { return e }
	func visit(_ o: CGPDFObjectRef) {
		if let i = asInt(o) { e.mcids.append((pg, i)); return }
		guard let kd = asDict(o) else { return }
		switch kd.name("Type") {
		case "MCR": if let i = kd.int("MCID") { e.mcids.append((kd.dict("Pg").flatMap { pageIndex[key($0)] } ?? pg, i)) }
		case "OBJR": e.objrs += 1
		default: if kd.has("S") { e.children.append(walk(kd, roleMap: roleMap, pageIndex: pageIndex, inheritedPg: pg, depth: depth + 1)) }
		}
	}
	if let a = asArray(k) { for i in 0..<a.count { if let o = a.object(i) { visit(o) } } } else { visit(k) }
	return e
}
func flatten(_ e: Elem) -> [Elem] { [e] + e.children.flatMap(flatten) }

/// Look up `index` in a number tree (ParentTree). Returns the value object.
func numberTreeLookup(_ node: CGPDFDictionaryRef, _ index: Int, depth: Int = 0) -> CGPDFObjectRef? {
	if let nums = node.array("Nums") {
		var i = 0
		while i + 1 < nums.count { if nums.int(i) == index { return nums.object(i + 1) }; i += 2 }
	}
	if let kids = node.array("Kids"), depth < 32 {
		for i in 0..<kids.count {
			guard let kid = kids.dict(i) else { continue }
			if let lim = kid.array("Limits"), let lo = lim.int(0), let hi = lim.int(1), !(lo...hi).contains(index) { continue }
			if let v = numberTreeLookup(kid, index, depth: depth + 1) { return v }
		}
	}
	return nil
}

func colSpan(_ attrs: CGPDFObjectRef?, _ key: String) -> Int {
	guard let attrs else { return 1 }
	if let d = asDict(attrs) { return d.int(key) ?? 1 }
	if let a = asArray(attrs) { for i in 0..<a.count { if let d = a.dict(i), let v = d.int(key) { return v } } }
	return 1
}

// MARK: - The check

func check(_ path: String) {
	findings = []
	guard let doc = CGPDFDocument(URL(fileURLWithPath: path) as CFURL) else { print("cannot open \(path)"); return }
	print("\n=== \(URL(fileURLWithPath: path).lastPathComponent)  (\(doc.numberOfPages) pages, PDF \(ver(doc)))")
	guard let cat = doc.catalog else { return }
	let info = doc.info
	var pages: [CGPDFPage] = []
	var pageIndex: [UnsafeRawPointer: Int] = [:]
	for i in 1...max(doc.numberOfPages, 1) { if let p = doc.page(at: i) { pages.append(p); if let d = p.dictionary { pageIndex[key(d)] = i - 1 } } }

	// Document
	let perms = doc.accessPermissions
	report("Document", "Accessibility permission flag", doc.isEncrypted && !perms.contains(.allowsContentAccessibility) ? .fail : .pass,
		   doc.isEncrypted ? "encrypted; accessibility extraction \(perms.contains(.allowsContentAccessibility) ? "allowed" : "BLOCKED")" : "not encrypted")
	let markInfo = cat.dict("MarkInfo")?.bool("Marked") ?? false
	let tree = cat.dict("StructTreeRoot")
	report("Document", "Tagged PDF", (markInfo && tree != nil) ? .pass : .fail, "MarkInfo/Marked=\(markInfo) StructTreeRoot=\(tree != nil)")
	report("Document", "Logical reading order", .manual, "verify tag order matches visual order")
	let lang = cat.string("Lang")
	report("Document", "Primary language", lang?.isEmpty == false ? .pass : .fail, lang.map { "catalog /Lang=\($0)" } ?? "no catalog /Lang")
	var xmp = ""
	if let ms = cat.stream("Metadata") { var f = CGPDFDataFormat.raw; if let d = CGPDFStreamCopyData(ms, &f) { xmp = String(data: d as Data, encoding: .utf8) ?? "" } }
	let infoTitle = info?.string("Title")
	let xmpTitle = xmp.range(of: "<dc:title>") != nil
	let displayTitle = cat.dict("ViewerPreferences")?.bool("DisplayDocTitle") ?? false
	report("Document", "Title", (infoTitle?.isEmpty == false || xmpTitle) && displayTitle ? .pass : .fail,
		   "Info/Title=\(infoTitle ?? "nil") XMP dc:title=\(xmpTitle) DisplayDocTitle=\(displayTitle)")
	let outlineCount = doc.outline.flatMap { ($0 as NSDictionary)[kCGPDFOutlineChildren as String] as? [Any] }?.count ?? 0
	report("Document", "Bookmarks", doc.numberOfPages < 21 ? (outlineCount > 0 ? .pass : .na) : (outlineCount > 0 ? .pass : .fail),
		   "\(outlineCount) top-level outline items (Acrobat requires for 21+ pages)")
	report("Document", "Color contrast", .manual)
	report("Document", "PDF/UA identifier (XMP pdfuaid:part)", xmp.contains("pdfuaid:part") ? .pass : .na)

	// Structure tree
	var elems: [Elem] = []
	var root: Elem?
	if let tree {
		let rm = tree.dict("RoleMap")
		var top = Elem(type: "StructTreeRoot", raw: "StructTreeRoot", alt: nil, actualText: nil, lang: nil, attrs: nil)
		if let k = tree.object("K") {
			if let a = asArray(k) { for i in 0..<a.count { if let d = a.dict(i) { top.children.append(walk(d, roleMap: rm, pageIndex: pageIndex, inheritedPg: nil, depth: 0)) } } }
			else if let d = asDict(k) { top.children.append(walk(d, roleMap: rm, pageIndex: pageIndex, inheritedPg: nil, depth: 0)) }
		}
		root = top
		elems = top.children.flatMap(flatten)
	}

	// Page content
	let table = makeTable()
	var totals = (text: 0, invisible: 0, images: 0, untaggedText: 0, untaggedImages: 0, untaggedPaths: 0, nested: 0)
	var imageOnlyPages: [Int] = [], contentMCIDs = Set<String>(), annotsTotal = 0, annotsUntagged = 0, tabsMissing = 0, fontIssues: [String] = []
	var parentTreeHits = 0, parentTreeMisses = 0
	let parentTree = tree?.dict("ParentTree")
	for (i, page) in pages.enumerated() {
		let ps = PageScan(); ps.table = table
		let cs = CGPDFContentStreamCreateWithPage(page)
		let sc = CGPDFScannerCreate(cs, table, Unmanaged.passUnretained(ps).toOpaque())
		CGPDFScannerScan(sc); CGPDFScannerRelease(sc); CGPDFContentStreamRelease(cs)
		totals.text += ps.textOps; totals.invisible += ps.invisibleTextOps; totals.images += ps.imageOps
		totals.untaggedText += ps.untaggedText; totals.untaggedImages += ps.untaggedImages; totals.untaggedPaths += ps.untaggedPaths; totals.nested += ps.nestedMCID
		if ps.imageOps > 0 && ps.textOps == 0 { imageOnlyPages.append(i + 1) }
		ps.mcids.forEach { contentMCIDs.insert("\(i):\($0)") }
		guard let pd = page.dictionary else { continue }
		// ParentTree: page /StructParents -> array indexed by MCID -> struct elem
		if let sp = pd.int("StructParents"), let parentTree, let arr = numberTreeLookup(parentTree, sp).flatMap(asArray) {
			for m in ps.mcids { if m < arr.count, arr.dict(m) != nil { parentTreeHits += 1 } else { parentTreeMisses += 1 } }
		} else if !ps.mcids.isEmpty { parentTreeMisses += ps.mcids.count }
		// Annotations
		if let annots = pd.array("Annots") {
			for a in 0..<annots.count {
				guard let ad = annots.dict(a), ad.name("Subtype") != "Popup" else { continue }
				annotsTotal += 1
				if ad.int("StructParent") == nil { annotsUntagged += 1 }
			}
			if annots.count > 0 && pd.name("Tabs") != "S" { tabsMissing += 1 }
		}
		// Fonts
		if let fonts = pd.dict("Resources")?.dict("Font") {
			for fk in fonts.keys {
				guard let f = fonts.dict(fk) else { continue }
				let sub = f.name("Subtype") ?? "?", base = f.name("BaseFont") ?? fk
				let desc = sub == "Type0" ? f.array("DescendantFonts")?.dict(0)?.dict("FontDescriptor") : f.dict("FontDescriptor")
				let embedded = desc.map { $0.has("FontFile") || $0.has("FontFile2") || $0.has("FontFile3") } ?? false
				let enc = f.name("Encoding")
				let unicodeOK = f.has("ToUnicode") || ["WinAnsiEncoding", "MacRomanEncoding", "StandardEncoding"].contains(enc ?? "") || f.dict("Encoding") != nil
				if !unicodeOK { fontIssues.append("p\(i + 1) \(base): no ToUnicode (\(sub), \(enc ?? "builtin"))") }
				if !embedded && sub != "Type3" { fontIssues.append("p\(i + 1) \(base): not embedded") }
			}
		}
	}
	report("Document", "Image-only PDF", imageOnlyPages.isEmpty ? .pass : .fail,
		   imageOnlyPages.isEmpty ? "\(totals.text) text ops (\(totals.invisible) invisible OCR)" : "pages without any text: \(imageOnlyPages)")
	let untagged = totals.untaggedText + totals.untaggedImages + totals.untaggedPaths
	report("Page Content", "Tagged content", untagged == 0 ? .pass : .fail,
		   "untagged painting ops: text \(totals.untaggedText), images \(totals.untaggedImages), paths \(totals.untaggedPaths)")
	report("Page Content", "Tagged annotations", annotsUntagged == 0 ? .pass : .fail, "\(annotsUntagged)/\(annotsTotal) annotations lack /StructParent")
	report("Page Content", "Tab order", tabsMissing == 0 ? .pass : .fail, "\(tabsMissing) pages with annotations lack /Tabs /S")
	report("Page Content", "Character encoding", fontIssues.isEmpty ? .pass : .fail, fontIssues.isEmpty ? "all fonts embedded + Unicode-mappable" : fontIssues.joined(separator: "; "))
	for r in ["Tagged multimedia", "Screen flicker", "Scripts", "Timed responses"] { report("Page Content", r, .manual, "(rare in scans; JS/RichMedia presence could be detected)") }
	report("Page Content", "Accessible links", .manual)

	// MCID cross-check: struct tree (Pg+MCID) vs content stream
	let treeMCIDs = Set(elems.flatMap { e in e.mcids.map { "\($0.page ?? -1):\($0.mcid)" } })
	let orphan = contentMCIDs.subtracting(treeMCIDs), dangling = treeMCIDs.subtracting(contentMCIDs)
	if tree != nil {
		report("Page Content", "MCID ↔ structure mapping", orphan.isEmpty && dangling.isEmpty && totals.nested == 0 ? .pass : .fail,
			   "content MCIDs \(contentMCIDs.count), referenced by tree \(treeMCIDs.count), orphan \(orphan.count), dangling \(dangling.count), nested-MCID BDCs \(totals.nested)")
		report("Page Content", "ParentTree resolves MCIDs", parentTreeMisses == 0 ? .pass : .fail,
			   "ParentTree \(parentTree == nil ? "MISSING/unresolvable" : "present"): \(parentTreeHits) hits, \(parentTreeMisses) misses")
	}

	// Forms
	var fields = 0, noTU = 0
	func walkFields(_ a: CGPDFArrayRef, _ depth: Int) {
		for i in 0..<a.count { guard let f = a.dict(i) else { continue }
			if let kids = f.array("Kids"), depth < 16, (0..<kids.count).contains(where: { kids.dict($0)?.has("T") == true }) { walkFields(kids, depth + 1) }
			else { fields += 1; if f.string("TU")?.isEmpty != false { noTU += 1 } } }
	}
	if let af = cat.dict("AcroForm")?.array("Fields") { walkFields(af, 0) }
	report("Forms", "Tagged form fields", fields == 0 ? .na : (annotsUntagged == 0 ? .pass : .fail), "\(fields) fields")
	report("Forms", "Field descriptions", fields == 0 ? .na : (noTU == 0 ? .pass : .fail), "\(noTU)/\(fields) fields lack /TU tooltip")

	// Alternate text
	let figures = elems.filter { $0.type == "Figure" }
	let noAlt = figures.filter { ($0.alt ?? $0.actualText ?? "").isEmpty }
	report("Alternate Text", "Figures alternate text", tree == nil ? .na : (noAlt.isEmpty ? .pass : .fail), "\(noAlt.count)/\(figures.count) Figure elements lack /Alt")
	var nestedAlt = 0
	for e in elems where e.alt != nil { nestedAlt += e.children.flatMap(flatten).filter { $0.alt != nil }.count }
	report("Alternate Text", "Nested alternate text", nestedAlt == 0 ? .pass : .fail, "\(nestedAlt) elements with /Alt inside an /Alt parent")
	let altNoContent = elems.filter { $0.alt != nil && $0.mcids.isEmpty && $0.children.isEmpty && $0.objrs == 0 }.count
	report("Alternate Text", "Associated with content", altNoContent == 0 ? .pass : .fail, "\(altNoContent) /Alt elements with no content")
	report("Alternate Text", "Hides annotation", elems.contains { $0.alt != nil && $0.children.flatMap(flatten).contains { $0.objrs > 0 } } ? .fail : .pass)
	report("Alternate Text", "Other elements alternate text", .manual)

	// Tables
	let tables = elems.filter { $0.type == "Table" }
	var rowIssues = 0, cellIssues = 0, noHeader = 0, irregular = 0
	for t in tables {
		var rows: [Elem] = []
		for c in t.children {
			if c.type == "TR" { rows.append(c) }
			else if ["THead", "TBody", "TFoot"].contains(c.type) { rows += c.children.filter { $0.type == "TR" }; rowIssues += c.children.filter { $0.type != "TR" }.count }
			else if c.type != "Caption" { rowIssues += 1 }
		}
		var hasTH = false
		var widths: [Int] = []
		var carry: [Int] = [] // pending rowspans per column
		for r in rows {
			cellIssues += r.children.filter { $0.type != "TH" && $0.type != "TD" }.count
			if r.children.contains(where: { $0.type == "TH" }) { hasTH = true }
			var w = carry.filter { $0 > 0 }.count
			var next = carry.map { max($0 - 1, 0) }
			for c in r.children where c.type == "TH" || c.type == "TD" {
				let cs = colSpan(c.attrs, "ColSpan"), rs = colSpan(c.attrs, "RowSpan")
				w += cs
				if rs > 1 { next += Array(repeating: rs - 1, count: cs) }
			}
			carry = next
			widths.append(w)
		}
		if !hasTH { noHeader += 1 }
		if Set(widths).count > 1 { irregular += 1 }
	}
	let tna = tables.isEmpty
	report("Tables", "Rows", tna ? .na : (rowIssues == 0 ? .pass : .fail), "\(tables.count) tables")
	report("Tables", "TH and TD", tna ? .na : (cellIssues == 0 ? .pass : .fail))
	report("Tables", "Headers", tna ? .na : (noHeader == 0 ? .pass : .fail), "\(noHeader) tables without TH")
	report("Tables", "Regularity", tna ? .na : (irregular == 0 ? .pass : .fail), "\(irregular) irregular (ColSpan/RowSpan from /A honored)")
	report("Tables", "Summary", tna ? .na : .manual, "optional")

	// Lists
	let lists = elems.filter { $0.type == "L" }
	let badLChildren = lists.reduce(0) { $0 + $1.children.filter { !["LI", "L", "Caption"].contains($0.type) }.count }
	let lis = elems.filter { $0.type == "LI" }
	let badLIChildren = lis.reduce(0) { $0 + $1.children.filter { !["Lbl", "LBody"].contains($0.type) }.count }
	func parentOf(_ type: String, _ r: Elem?) -> [String] { guard let r else { return [] }; return r.children.flatMap { c in (c.type == type ? [r.type] : []) + parentOf(type, c) } }
	let liOutsideL = parentOf("LI", root).filter { $0 != "L" }.count
	report("Lists", "List items", lists.isEmpty && lis.isEmpty ? .na : (badLChildren == 0 && liOutsideL == 0 ? .pass : .fail), "\(lists.count) L, \(lis.count) LI, \(liOutsideL) LI outside L")
	report("Lists", "Lbl and LBody", lis.isEmpty ? .na : (badLIChildren == 0 ? .pass : .fail))

	// Headings
	let levels = elems.compactMap { e -> Int? in e.type.count == 2 && e.type.first == "H" ? Int(String(e.type.last!)) : nil }
	var skips: [String] = []
	var prev = 0
	for l in levels { if l > prev + 1 { skips.append("H\(prev == 0 ? "-" : String(prev))→H\(l)") }; prev = l }
	report("Headings", "Appropriate nesting", levels.isEmpty ? .na : (skips.isEmpty ? .pass : .fail), levels.isEmpty ? "no Hn" : "sequence \(levels.map { "H\($0)" }.joined(separator: " ")); skips: \(skips)")

	// Print grouped like Acrobat
	var lastCat = ""
	for f in findings {
		if f.category != lastCat { print("  [\(f.category)]"); lastCat = f.category }
		print("    \(f.status.rawValue.padding(toLength: 6, withPad: " ", startingAt: 0)) \(f.rule)\(f.detail.isEmpty ? "" : " — \(f.detail)")")
	}
	let c = Dictionary(grouping: findings, by: \.status).mapValues(\.count)
	print("  totals: pass \(c[.pass] ?? 0), fail \(c[.fail] ?? 0), manual \(c[.manual] ?? 0), n/a \(c[.na] ?? 0)")
	if let root { print("  tree: " + root.children.map { describe($0) }.joined(separator: " ")) }
}
func describe(_ e: Elem) -> String { e.children.isEmpty ? e.type : "\(e.type)(\(e.children.map(describe).joined(separator: " ")))" }

for p in CommandLine.arguments.dropFirst() { check(p) }
