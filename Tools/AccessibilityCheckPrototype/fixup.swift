// fixup.swift — PoC of the catalog/page fixes PDFKit can't make: appends a PDF incremental update
// (no rewrite, no dependencies) that adds catalog /Lang, /ViewerPreferences<</DisplayDocTitle true>>,
// /MarkInfo (when a StructTreeRoot exists) and page /Tabs /S. Classic xref tables only (what Quartz and
// PDFKit write); bails out on xref streams and encrypted files.
// Usage: fixup in.pdf out.pdf en-US
import Foundation

let args = CommandLine.arguments
guard args.count == 4 else { print("usage: fixup in.pdf out.pdf lang"); exit(2) }
var bytes = try! Data(contentsOf: URL(fileURLWithPath: args[1]))
let text = String(decoding: bytes, as: UTF8.self) // only used for ASCII structure searches
let latin = String(data: bytes, encoding: .isoLatin1)!

func fail(_ s: String) -> Never { print("fixup: \(s)"); exit(1) }
guard let sx = latin.range(of: "startxref", options: .backwards) else { fail("no startxref") }
let xrefOffset = Int(latin[sx.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: \.isNewline).first ?? "")!
let latinBytes = Array(bytes)
func substring(_ from: Int, _ len: Int) -> String { String(decoding: latinBytes[from..<min(from + len, latinBytes.count)], as: UTF8.self) }

// Parse classic xref sections, newest first, following /Prev.
var offsets: [Int: (off: Int, gen: Int)] = [:]
var trailerText = ""
var cursor: Int? = xrefOffset
while let at = cursor {
	let chunk = String(data: bytes[at...], encoding: .isoLatin1)!
	guard chunk.hasPrefix("xref") else { fail("xref stream / object stream file — needs a real parser (not supported in PoC)") }
	let lines = chunk.split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\n" || $0 == "\r" })
	var i = 1
	while i < lines.count, !lines[i].hasPrefix("trailer") {
		let head = lines[i].split(separator: " ")
		let start = Int(head[0])!, count = Int(head[1])!
		for j in 0..<count {
			let e = lines[i + 1 + j].split(separator: " ")
			if e.count >= 3, e[2].hasPrefix("n"), offsets[start + j] == nil { offsets[start + j] = (Int(e[0])!, Int(e[1])!) }
		}
		i += 1 + count
	}
	let tr = chunk.range(of: "trailer")!
	let end = chunk.range(of: "startxref", range: tr.upperBound..<chunk.endIndex)!
	let t = String(chunk[tr.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
	if trailerText.isEmpty { trailerText = t }
	if t.contains("/Encrypt") { fail("encrypted — new strings would need encrypting") }
	cursor = t.range(of: #"/Prev\s+(\d+)"#, options: .regularExpression).map { Int(t[$0].split(separator: " ").last!)! }
}
func ref(_ dict: String, _ key: String) -> Int? {
	guard let r = dict.range(of: "/\(key)\\s+(\\d+)\\s+\\d+\\s+R", options: .regularExpression) else { return nil }
	return Int(dict[r].split(whereSeparator: { $0 == " " || $0.isNewline })[1])
}
/// The raw dictionary text of object `num` (between its first "<<" and the matching ">>").
func rawDict(_ num: Int) -> String {
	guard let o = offsets[num] else { fail("object \(num) not in xref") }
	let s = String(data: bytes[o.off..<min(o.off + 20000, bytes.count)], encoding: .isoLatin1)!
	let start = s.range(of: "<<")!.lowerBound
	var depth = 0, i = start, inString = 0
	while i < s.endIndex {
		let c = s[i]
		if c == "(" { inString += 1 } else if c == ")" && inString > 0 { inString -= 1 }
		else if inString == 0, s[i...].hasPrefix("<<") { depth += 1; i = s.index(i, offsetBy: 2); continue }
		else if inString == 0, s[i...].hasPrefix(">>") { depth -= 1; i = s.index(i, offsetBy: 2); if depth == 0 { return String(s[start..<i]) }; continue }
		i = s.index(after: i)
	}
	fail("unterminated dict in \(num)")
}
func adding(_ dict: String, _ entries: [(String, String)]) -> String {
	var d = dict
	for (k, v) in entries where !d.contains("/\(k) ") && !d.contains("/\(k)<<") && !d.contains("/\(k)(") { d = String(d.dropLast(2)) + " /\(k) \(v) >>" }
	return d
}

guard let rootNum = ref(trailerText, "Root") else { fail("no /Root") }
let catalog = rawDict(rootNum)
var updates: [(Int, String)] = []
var catEntries = [("Lang", "(\(args[3]))"), ("ViewerPreferences", "<< /DisplayDocTitle true >>")]
if catalog.contains("/StructTreeRoot") { catEntries.append(("MarkInfo", "<< /Marked true >>")) }
updates.append((rootNum, adding(catalog, catEntries)))
// Pages with annotations get /Tabs /S (walks the page tree by raw refs).
func pages(_ num: Int, depth: Int = 0) -> [Int] {
	let d = rawDict(num)
	if d.contains("/Type /Page") && !d.contains("/Type /Pages") { return [num] }
	guard depth < 32, let kidsRange = d.range(of: #"/Kids\s*\[[^\]]*\]"#, options: .regularExpression) else { return [] }
	let nums = try! NSRegularExpression(pattern: #"(\d+)\s+\d+\s+R"#).matches(in: String(d[kidsRange]), range: NSRange(location: 0, length: String(d[kidsRange]).utf16.count)).map { Int((String(d[kidsRange]) as NSString).substring(with: $0.range(at: 1)))! }
	return nums.flatMap { pages($0, depth: depth + 1) }
}
/// Object `num` is a dictionary (not a stream, array or string)?
func isPlainDict(_ num: Int) -> Bool {
	guard let o = offsets[num] else { return false }
	let s = String(data: bytes[o.off..<min(o.off + 64, bytes.count)], encoding: .isoLatin1)!
	guard let r = s.range(of: "obj") else { return false }
	return s[r.upperBound...].drop(while: { $0.isWhitespace }).hasPrefix("<<")
}
func int(_ dict: String, _ key: String) -> Int? {
	guard let r = dict.range(of: "/\(key)\\s+(\\d+)(?![\\d\\s]*R)", options: .regularExpression) else { return nil }
	return Int(dict[r].split(whereSeparator: { $0 == " " || $0.isNewline }).last!)
}
// Quartz's tagged output references /ParentTree N 0 R but never writes object N (seen on iOS 26.5 and
// macOS 26.6). Rebuild it from the leaf StructElems (/Pg + integer /K) and give each page /StructParents.
let pageNums = pages(ref(catalog, "Pages")!)
var structParents: [Int: Int] = [:]
if let treeNum = ref(catalog, "StructTreeRoot"), let ptNum = ref(rawDict(treeNum), "ParentTree"), offsets[ptNum] == nil || offsets[ptNum]!.off == 0 {
	var leaf: [Int: [Int: Int]] = [:] // page obj -> MCID -> StructElem obj
	for num in offsets.keys.sorted() where offsets[num]!.off > 0 && isPlainDict(num) {
		let d = rawDict(num)
		guard d.contains("/StructElem"), let pg = ref(d, "Pg"), let mcid = int(d, "K") else { continue }
		leaf[pg, default: [:]][mcid] = num
	}
	var nums = ""
	for (i, p) in pageNums.enumerated() {
		structParents[p] = i
		let map = leaf[p] ?? [:]
		let maxID = map.keys.max() ?? -1
		nums += " \(i) [" + (0...max(maxID, 0)).map { map[$0].map { "\($0) 0 R" } ?? "null" }.joined(separator: " ") + "]"
	}
	offsets[ptNum] = (0, 0)
	updates.append((ptNum, "<< /Nums [\(nums) ] >>"))
	updates.append((treeNum, adding(rawDict(treeNum), [("ParentTreeNextKey", "\(pageNums.count)")])))
	print("fixup: rebuilt missing ParentTree \(ptNum) from \(leaf.values.map(\.count).reduce(0, +)) leaf StructElems")
}
for p in pageNums {
	let d = rawDict(p)
	var add: [(String, String)] = []
	if d.contains("/Annots") { add.append(("Tabs", "/S")) }
	if let sp = structParents[p] { add.append(("StructParents", "\(sp)")) }
	if !add.isEmpty { updates.append((p, adding(d, add))) }
}

// Append the incremental update.
var tail = "\n"
var newOffsets: [(Int, Int, Int)] = []
for (num, dict) in updates {
	newOffsets.append((num, offsets[num]!.gen, bytes.count + tail.utf8.count))
	tail += "\(num) \(offsets[num]!.gen) obj\n\(dict)\nendobj\n"
}
let xrefAt = bytes.count + tail.utf8.count
tail += "xref\n"
for (num, gen, off) in newOffsets.sorted(by: { $0.0 < $1.0 }) { tail += "\(num) 1\n" + String(format: "%010d %05d n \n", off, gen) }
var newTrailer = trailerText.replacingOccurrences(of: #"/Prev\s+\d+"#, with: "", options: .regularExpression)
newTrailer = String(newTrailer.dropLast(2)) + " /Prev \(xrefOffset) >>"
tail += "trailer\n\(newTrailer)\nstartxref\n\(xrefAt)\n%%EOF\n"
bytes.append(tail.data(using: .isoLatin1)!)
try! bytes.write(to: URL(fileURLWithPath: args[2]))
print("fixup: appended objects \(updates.map(\.0)) (catalog \(rootNum)), \(tail.utf8.count) bytes")
_ = text; _ = substring
