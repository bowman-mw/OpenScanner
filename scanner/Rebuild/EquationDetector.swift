//
//  EquationDetector.swift
//  Rescriva (fork of Open Scanner)
//
//  Text-based equation detection and LaTeX conversion — the first version,
//  ahead of the bundled image-to-LaTeX model. `mathScore` weighs how much a
//  recognized line reads like math rather than prose, `latex(fromLinear:)`
//  turns its linear reading ("v = Vmax[S] / (Km + [S])") into LaTeX in the
//  subset `LaTeXToOMML` accepts, and `refine` lets Apple's on-device model
//  correct that LaTeX on iPhones that have it.
//
//  Power of 10: no recursion (bracket levels are an explicit stack, closed
//  innermost first), every loop is a bounded `for`, and input is capped at
//  `maxLineLength` characters and `maxNestingDepth` bracket levels.
//

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Decides whether a recognized line is an equation and converts its linear
/// reading to LaTeX. Pure functions over `String` with no shared mutable
/// state, so every entry point is safe to call off the main thread.
enum EquationDetector {
	/// Lines at or above this `mathScore` are treated as equations.
	static let threshold: Double = 0.6
	/// Longest line, in characters, either entry point examines; longer lines are prose.
	static let maxLineLength = 300
	/// Deepest bracket nesting `latex(fromLinear:)` accepts.
	static let maxNestingDepth = 16
	/// How long `refine` waits for the on-device model before keeping the candidate.
	static let refineTimeoutNanoseconds: UInt64 = 4_000_000_000
	/// Longest model answer `refine` considers.
	static let maxModelAnswerLength = 600
	/// Added to the score's denominator so a lone symbol can't reach the threshold.
	static let scoreDamping = 1.5

	/// 0–1: how much a recognized line reads like math rather than prose; 0 for a line without
	/// the shape of math (`Shape.isMath`), such as a model number or a spec value.
	static func mathScore(_ text: String) -> Double {
		let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty, trimmed.count <= maxLineLength else { return 0 }
		let lexemes = Lexer.lexemes(of: trimmed)
		guard !lexemes.isEmpty, Shape.isMath(lexemes) else { return 0 }
		let evidence = Scorer.evidence(for: lexemes)
		let math = evidence.mathTotal
		guard math > 0 else { return 0 }
		return math / (math + evidence.prose + scoreDamping)
	}

	/// LaTeX for a linear OCR reading (e.g. "v = Vmax[S] / (Km + [S])"), or nil when the
	/// result wouldn't be accepted by LaTeXToOMML.
	static func latex(fromLinear text: String) -> String? {
		let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty, trimmed.count <= maxLineLength, !trimmed.contains("\\") else { return nil }
		let lexemes = Lexer.lexemes(of: String(BracketRepair.repaired(Array(trimmed))))
		guard !lexemes.isEmpty, let body = Converter.assemble(lexemes.map(Converter.term(for:))) else { return nil }
		let latex = body.trimmingCharacters(in: .whitespaces)
		guard !latex.isEmpty, LaTeXToOMML.convert(latex) != nil else { return nil }
		return latex
	}

	/// Smart tier: asks the on-device model to correct the LaTeX given the OCR text; returns the
	/// model's LaTeX only if LaTeXToOMML accepts it, otherwise `candidate`. No-op where unavailable.
	static func refine(_ candidate: String, linear: String) async -> String {
		let reading = linear.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !candidate.isEmpty, !reading.isEmpty, reading.count <= maxLineLength else { return candidate }
		#if canImport(FoundationModels)
		if #available(iOS 26.0, macOS 26.0, *) {
			guard SystemLanguageModel.default.isAvailable else { return candidate }
			guard let answer = await ModelRefiner.answer(candidate: candidate, linear: reading),
				  let latex = ModelRefiner.cleaned(answer, candidate: candidate, linear: reading),
				  LaTeXToOMML.convert(latex) != nil else { return candidate }
			return latex
		}
		#endif
		return candidate
	}
}

// MARK: - Lexing

extension EquationDetector {
	/// One lexical piece of a linear reading.
	fileprivate struct Lexeme {
		/// What kind of piece it is.
		enum Kind: Hashable {
			case word, number, letterDigits, symbol, relation, arrow, additive, product, slash
			case caret, underscore, superscript, subscriptRun, degree, radical, nary, open, close
			case punct, currency
		}

		var kind: Kind
		/// The characters as read (a word, a number, a symbol).
		var source: String
		/// LaTeX for the piece; for `.letterDigits` the letter alone.
		var latex: String
		/// The digits of a `.letterDigits` piece (`x1` → "1").
		var script = ""
		/// Whitespace preceded the piece in the line.
		var spaced: Bool
	}

	/// How the lexer groups characters into runs.
	fileprivate enum CharacterClass {
		case letter, digit, superscript, subscriptRun, single
	}

	/// A run of same-class characters, the lexer's first pass.
	fileprivate struct CharacterRun {
		var characterClass: CharacterClass
		var text: String
		var spaced: Bool
	}

	/// Splits a line into lexemes: letter, digit and Unicode-script runs, then one
	/// lexeme per remaining character (two for `<=`, `->` and the other digraphs).
	fileprivate enum Lexer {
		static func lexemes(of text: String) -> [Lexeme] {
			let runs = characterRuns(Array(normalized(text)))
			guard !runs.isEmpty else { return [] }
			var lexemes: [Lexeme] = []
			var skipNext = false
			for index in runs.indices {
				guard !skipNext else {
					skipNext = false
					continue
				}
				let run = runs[index]
				let next: CharacterRun? = index + 1 < runs.count ? runs[index + 1] : nil
				if let joined = digraph(run, next) ?? letterDigits(run, next) {
					lexemes.append(joined)
					skipNext = true
				} else if let lexeme = lexeme(for: run) {
					lexemes.append(lexeme)
				}
			}
			return lexemes
		}

		/// Canonical composition, with Greek capitals that look Latin folded to Latin.
		static func normalized(_ text: String) -> String {
			let composed = text.precomposedStringWithCanonicalMapping
			guard composed.contains(where: { latinLookalikes[$0] != nil }) else { return composed }
			return String(composed.map { latinLookalikes[$0] ?? $0 })
		}

		static func characterRuns(_ characters: [Character]) -> [CharacterRun] {
			guard !characters.isEmpty, characters.count <= EquationDetector.maxLineLength else { return [] }
			var runs: [CharacterRun] = []
			var spaced = false
			for index in characters.indices {
				let character = characters[index]
				guard !character.isWhitespace else {
					spaced = true
					continue
				}
				let characterClass = classify(characters, at: index)
				if characterClass != .single, !spaced, let last = runs.last, last.characterClass == characterClass {
					runs[runs.count - 1].text.append(character)
				} else {
					runs.append(CharacterRun(characterClass: characterClass, text: String(character), spaced: spaced))
				}
				spaced = false
			}
			return runs
		}

		static func classify(_ characters: [Character], at index: Int) -> CharacterClass {
			guard characters.indices.contains(index) else { return .single }
			let character = characters[index]
			if superscripts[character] != nil { return .superscript }
			if subscripts[character] != nil { return .subscriptRun }
			if isDigit(characters, index) { return .digit }
			if character == ".", isDigit(characters, index - 1), isDigit(characters, index + 1) { return .digit }
			if character.isLetter, entry(for: character) == nil { return .letter }
			return .single
		}

		static func isDigit(_ characters: [Character], _ index: Int) -> Bool {
			guard characters.indices.contains(index) else { return false }
			return characters[index].isASCII && characters[index].isNumber
		}

		static func lexeme(for run: CharacterRun) -> Lexeme? {
			guard !run.text.isEmpty else { return nil }
			switch run.characterClass {
			case .letter:
				return Lexeme(kind: .word, source: run.text, latex: run.text, spaced: run.spaced)
			case .digit:
				return Lexeme(kind: .number, source: run.text, latex: run.text, spaced: run.spaced)
			case .superscript:
				let content = String(run.text.compactMap { superscripts[$0] })
				return Lexeme(kind: .superscript, source: run.text, latex: content, spaced: run.spaced)
			case .subscriptRun:
				let content = String(run.text.compactMap { subscripts[$0] })
				return Lexeme(kind: .subscriptRun, source: run.text, latex: content, spaced: run.spaced)
			case .single:
				return single(run)
			}
		}

		static func single(_ run: CharacterRun) -> Lexeme? {
			guard let character = run.text.first, !skipped.contains(character) else { return nil }
			if let found = entry(for: character) {
				return Lexeme(kind: found.kind, source: run.text, latex: found.latex, spaced: run.spaced)
			}
			let latex = escapedPunctuation[character] ?? run.text
			return Lexeme(kind: .punct, source: run.text, latex: latex, spaced: run.spaced)
		}

		/// `x1` → one lexeme: a single ASCII letter directly followed by an integer.
		static func letterDigits(_ run: CharacterRun, _ next: CharacterRun?) -> Lexeme? {
			guard run.characterClass == .letter, run.text.count == 1,
				  let letter = run.text.first, letter.isASCII,
				  let next, next.characterClass == .digit, !next.spaced, !next.text.contains(".") else { return nil }
			return Lexeme(kind: .letterDigits, source: run.text + next.text, latex: run.text,
						  script: next.text, spaced: run.spaced)
		}

		static func digraph(_ run: CharacterRun, _ next: CharacterRun?) -> Lexeme? {
			guard run.characterClass == .single, let next, next.characterClass == .single, !next.spaced,
				  let found = digraphs[run.text + next.text] else { return nil }
			return Lexeme(kind: found.kind, source: run.text + next.text, latex: found.latex, spaced: run.spaced)
		}

		static func entry(for character: Character) -> (kind: Lexeme.Kind, latex: String)? {
			guard !character.isWhitespace else { return nil }
			for table in tables {
				if let latex = table.symbols[character] { return (table.kind, latex) }
			}
			return nil
		}

		// MARK: Tables

		static let relations: [Character: String] = [
			"=": "=", "<": "<", ">": ">", "≤": "\\leq", "≥": "\\geq", "⩽": "\\leq", "⩾": "\\geq",
			"≠": "\\neq", "≈": "\\approx", "≡": "\\equiv", "∝": "\\propto", "~": "\\sim", "∼": "\\sim",
			"≃": "\\simeq", "≪": "\\ll", "≫": "\\gg", "∈": "\\in",
		]
		static let arrows: [Character: String] = [
			"→": "\\to", "⟶": "\\to", "←": "\\leftarrow", "↔": "\\leftrightarrow",
			"⇒": "\\Rightarrow", "⇔": "\\Leftrightarrow", "⇌": "\\rightleftharpoons",
		]
		static let additives: [Character: String] = [
			"+": "+", "-": "-", "−": "-", "–": "-", "—": "-", "±": "\\pm", "∓": "\\mp",
		]
		static let products: [Character: String] = [
			"×": "\\times", "·": "\\cdot", "⋅": "\\cdot", "∙": "\\cdot", "*": "\\cdot", "÷": "\\div",
		]
		static let naries: [Character: String] = [
			"∑": "\\sum", "Σ": "\\sum", "∫": "\\int", "∏": "\\prod", "∮": "\\oint",
		]
		static let symbols: [Character: String] = [
			"∞": "\\infty", "∂": "\\partial", "∇": "\\nabla", "ħ": "\\hbar", "ℓ": "\\ell",
		]
		static let greek: [Character: String] = [
			"α": "\\alpha", "β": "\\beta", "γ": "\\gamma", "δ": "\\delta", "ε": "\\varepsilon",
			"ϵ": "\\epsilon", "ζ": "\\zeta", "η": "\\eta", "θ": "\\theta", "ϑ": "\\vartheta",
			"ι": "\\iota", "κ": "\\kappa", "λ": "\\lambda", "μ": "\\mu", "µ": "\\mu", "ν": "\\nu",
			"ξ": "\\xi", "π": "\\pi", "ϖ": "\\varpi", "ρ": "\\rho", "ϱ": "\\varrho", "σ": "\\sigma",
			"ς": "\\varsigma", "τ": "\\tau", "υ": "\\upsilon", "φ": "\\varphi", "ϕ": "\\phi",
			"χ": "\\chi", "ψ": "\\psi", "ω": "\\omega", "Γ": "\\Gamma", "Δ": "\\Delta", "∆": "\\Delta",
			"Θ": "\\Theta", "Λ": "\\Lambda", "Ξ": "\\Xi", "Π": "\\Pi", "Υ": "\\Upsilon",
			"Φ": "\\Phi", "Ψ": "\\Psi", "Ω": "\\Omega",
		]
		static let tables: [(kind: Lexeme.Kind, symbols: [Character: String])] = [
			(.relation, relations), (.arrow, arrows), (.additive, additives), (.product, products),
			(.slash, ["/": "/", "∕": "/", "⁄": "/"]), (.caret, ["^": "^"]), (.underscore, ["_": "_"]),
			(.radical, ["√": "\\sqrt"]), (.nary, naries), (.symbol, symbols), (.symbol, greek),
			(.degree, ["°": "\\circ"]), (.open, ["(": "(", "[": "[", "{": "\\{"]),
			(.close, [")": ")", "]": "]", "}": "\\}"]),
			(.currency, ["$": "\\$", "€": "€", "£": "£", "¥": "¥"]),
		]
		static let digraphs: [String: (kind: Lexeme.Kind, latex: String)] = [
			"<=": (.relation, "\\leq"), ">=": (.relation, "\\geq"), "!=": (.relation, "\\neq"),
			"->": (.arrow, "\\to"), "=>": (.arrow, "\\Rightarrow"), "+-": (.additive, "\\pm"),
		]
		static let superscripts: [Character: Character] = [
			"⁰": "0", "¹": "1", "²": "2", "³": "3", "⁴": "4", "⁵": "5", "⁶": "6", "⁷": "7", "⁸": "8",
			"⁹": "9", "⁺": "+", "⁻": "-", "⁼": "=", "⁽": "(", "⁾": ")", "ⁿ": "n", "ⁱ": "i",
		]
		static let subscripts: [Character: Character] = [
			"₀": "0", "₁": "1", "₂": "2", "₃": "3", "₄": "4", "₅": "5", "₆": "6", "₇": "7", "₈": "8",
			"₉": "9", "₊": "+", "₋": "-", "₌": "=", "₍": "(", "₎": ")", "ₐ": "a", "ₑ": "e", "ₒ": "o",
			"ₓ": "x", "ₙ": "n", "ᵢ": "i", "ⱼ": "j", "ₖ": "k", "ₘ": "m", "ₜ": "t",
		]
		/// Characters LaTeXToOMML would read as syntax, escaped; and typographic marks it lacks.
		static let escapedPunctuation: [Character: String] = [
			"%": "\\%", "&": "\\&", "#": "\\#", "…": "\\ldots", "′": "'", "″": "''",
		]
		/// List bullets and checkbox glyphs that carry no math.
		static let skipped: Set<Character> = ["•", "◦", "▪", "☐", "□", "☑", "✓", "✔"]
		static let latinLookalikes: [Character: Character] = [
			"Α": "A", "Β": "B", "Ε": "E", "Ζ": "Z", "Η": "H", "Ι": "I", "Κ": "K", "Μ": "M",
			"Ν": "N", "Ο": "O", "Ρ": "P", "Τ": "T", "Χ": "X", "ο": "o",
		]
	}
}

// MARK: - Vocabulary

extension EquationDetector {
	/// What a letter run most likely is, for scoring and conversion.
	fileprivate enum WordClass {
		case radical, function, greek, letter, stopword, subscripted, identifier, prose
	}

	/// The word lists the scorer and the converter share.
	fileprivate enum Vocabulary {
		static let functions: Set<String> = [
			"sin", "cos", "tan", "sec", "csc", "cot", "sinh", "cosh", "tanh", "arcsin", "arccos",
			"arctan", "ln", "log", "exp", "lim", "max", "min", "det",
		]
		/// Exactly the Greek names LaTeXToOMML knows.
		static let greekNames: Set<String> = [
			"alpha", "beta", "gamma", "delta", "epsilon", "varepsilon", "zeta", "eta", "theta",
			"vartheta", "iota", "kappa", "lambda", "mu", "nu", "xi", "pi", "rho", "sigma", "tau",
			"upsilon", "phi", "varphi", "chi", "psi", "omega", "Gamma", "Delta", "Theta", "Lambda",
			"Xi", "Pi", "Sigma", "Upsilon", "Phi", "Psi", "Omega",
		]
		/// Lowercase tails a capital letter takes as a subscript (`Vmax`, `Km`, `Keq`).
		static let subscriptSuffixes: Set<String> = ["max", "min", "m", "cat", "eq", "0", "i", "j", "n", "t"]
		/// Short English words, compared lowercased; they also block `In`, `At`… from splitting.
		static let stopwords: Set<String> = [
			"of", "at", "to", "in", "is", "on", "an", "or", "by", "as", "be", "if", "it", "no", "so",
			"up", "we", "do", "my", "me", "he", "am", "us", "hi", "the", "and", "for", "but", "not",
			"are", "was", "per", "via", "has", "had", "its", "our", "you", "all", "any", "with",
			"from", "that", "this", "then", "than", "when", "each", "into", "your",
		]
		static let vowels: Set<Character> = ["a", "e", "i", "o", "u", "y", "A", "E", "I", "O", "U", "Y"]

		static func classify(_ word: String) -> WordClass {
			guard !word.isEmpty else { return .identifier }
			if word == "sqrt" { return .radical }
			if functions.contains(word) { return .function }
			if greekNames.contains(word) { return .greek }
			if word.count == 1 { return .letter }
			if stopwords.contains(word.lowercased()) { return .stopword }
			if subscriptSplit(word) != nil { return .subscripted }
			let hasVowel = word.contains { vowels.contains($0) }
			let allCaps = word.allSatisfy { $0.isUppercase }
			if word.count <= 3, !hasVowel || allCaps { return .identifier }
			return word.count == 2 ? .identifier : .prose
		}

		/// `Vmax` → ("V", "max"): one capital letter and a whitelisted lowercase tail.
		static func subscriptSplit(_ word: String) -> (base: String, script: String)? {
			guard word.count >= 2, let first = word.first, first.isASCII, first.isUppercase else { return nil }
			let rest = String(word.dropFirst())
			guard subscriptSuffixes.contains(rest) else { return nil }
			return (String(first), rest)
		}
	}
}

// MARK: - Scoring

extension EquationDetector {
	/// Math-evidence categories, each capped so one repeated symbol can't dominate.
	fileprivate enum Signal: CaseIterable {
		case relation, operation, fraction, script, symbol, bracket, letter, identifier, number

		var cap: Double {
			switch self {
			case .relation, .operation, .letter: return 4
			case .fraction, .identifier: return 3
			case .script, .symbol: return 4.5
			case .bracket: return 1.5
			case .number: return 1
			}
		}
	}

	/// Running math and prose evidence for one line.
	fileprivate struct Evidence {
		var math: [Signal: Double] = [:]
		var prose = 0.0

		mutating func add(_ signal: Signal, _ weight: Double) {
			math[signal, default: 0] += weight
		}

		var mathTotal: Double {
			Signal.allCases.reduce(0) { $0 + min(math[$1, default: 0], $1.cap) }
		}
	}

	/// Weighs each lexeme as math or prose evidence.
	fileprivate enum Scorer {
		static let dashes: Set<String> = ["-", "–", "—"]
		static let punctuationProse: [String: Double] = ["@": 3, "?": 1, "\"": 0.5, "“": 0.5, "”": 0.5]

		static func evidence(for lexemes: [Lexeme]) -> Evidence {
			var evidence = Evidence()
			guard !lexemes.isEmpty else { return evidence }
			for index in lexemes.indices {
				weigh(lexemes, at: index, into: &evidence)
			}
			evidence.prose += patternWeight(lexemes)
			return evidence
		}

		static func weigh(_ lexemes: [Lexeme], at index: Int, into evidence: inout Evidence) {
			guard lexemes.indices.contains(index) else { return }
			let lexeme = lexemes[index]
			switch lexeme.kind {
			case .relation: evidence.add(.relation, evidence.math[.relation, default: 0] > 0 ? 1 : 2)
			case .arrow: evidence.add(.operation, 0.5)
			case .additive: evidence.add(.operation, additiveWeight(lexemes, at: index))
			case .product: evidence.add(.operation, 1)
			case .slash: evidence.add(.fraction, 1.5)
			case .caret, .underscore, .superscript, .subscriptRun: evidence.add(.script, 1.5)
			case .symbol, .radical, .nary: evidence.add(.symbol, 1.5)
			case .open, .close: evidence.add(.bracket, 0.3)
			case .number: weighNumber(lexeme, into: &evidence)
			case .letterDigits: evidence.add(.identifier, 0.8)
			case .word: weighWord(lexemes, at: index, into: &evidence)
			case .punct: evidence.prose += punctuationProse[lexeme.source] ?? 0
			case .currency: evidence.prose += 2
			case .degree: break
			}
		}

		static func weighNumber(_ lexeme: Lexeme, into evidence: inout Evidence) {
			guard lexeme.kind == .number else { return }
			evidence.add(.number, 0.3)
			// 1.2.3 is a version or a date, not arithmetic.
			if lexeme.source.filter({ $0 == "." }).count >= 2 { evidence.prose += 1.5 }
		}

		static func weighWord(_ lexemes: [Lexeme], at index: Int, into evidence: inout Evidence) {
			guard lexemes.indices.contains(index) else { return }
			let word = lexemes[index].source
			switch Vocabulary.classify(word) {
			case .radical, .greek: evidence.add(.symbol, 1.5)
			case .function: evidence.add(.identifier, 1)
			case .letter: evidence.add(.letter, letterWeight(lexemes, at: index))
			case .subscripted: evidence.add(.identifier, 0.8)
			case .identifier: evidence.add(.identifier, word.contains { Vocabulary.vowels.contains($0) } ? 0.4 : 0.8)
			case .stopword: evidence.prose += 0.8
			case .prose: evidence.prose += word.count >= 6 ? 1.3 : 1
			}
		}

		static func letterWeight(_ lexemes: [Lexeme], at index: Int) -> Double {
			guard lexemes.indices.contains(index) else { return 0 }
			let lexeme = lexemes[index]
			// The C of 37°C is a unit.
			guard index == 0 || lexemes[index - 1].kind != .degree || lexeme.spaced else { return 0 }
			return ["a", "A", "I"].contains(lexeme.source) ? 0.4 : 1
		}

		/// A hyphen only counts as minus when it isn't joining words, a bullet or a number range.
		static func additiveWeight(_ lexemes: [Lexeme], at index: Int) -> Double {
			guard lexemes.indices.contains(index) else { return 0 }
			let lexeme = lexemes[index]
			guard dashes.contains(lexeme.source) else { return 1 }
			guard index > 0 else { return 0 }
			let before = lexemes[index - 1]
			let after: Lexeme? = index + 1 < lexemes.count ? lexemes[index + 1] : nil
			guard !lexeme.spaced, let after, !after.spaced else { return 0.5 }
			if isProse(before), isProse(after) { return 0 }
			if before.kind == .number, after.kind == .number { return 0.25 }
			return 0.5
		}

		static func isProse(_ lexeme: Lexeme) -> Bool {
			guard lexeme.kind == .word else { return false }
			let wordClass = Vocabulary.classify(lexeme.source)
			return wordClass == .prose || wordClass == .stopword
		}

		/// Clock times (9:14) and dates (10/10/2026) read as numbers and slashes.
		static func patternWeight(_ lexemes: [Lexeme]) -> Double {
			guard lexemes.count >= 3 else { return 0 }
			var weight = 0.0
			for index in 0..<(lexemes.count - 2) {
				let middle = lexemes[index + 1]
				let last = lexemes[index + 2]
				guard lexemes[index].kind == .number, last.kind == .number, !middle.spaced, !last.spaced else { continue }
				if middle.source == ":" { weight += 1 }
				guard middle.kind == .slash, index + 4 < lexemes.count else { continue }
				if lexemes[index + 3].kind == .slash, lexemes[index + 4].kind == .number { weight += 3 }
			}
			return weight
		}
	}
}

// MARK: - Shape

extension EquationDetector {
	/// Whether a line has the shape of math at all, before it is weighed. Spec sheets are full of
	/// lines with math's characters but not its shape: model numbers ("INR 18650-35E"), rates and
	/// units ("C/5", "340 Wh/kg", "33.0 A (3C)"), limits ("≤ 8 mΩ") and tolerances whose "±" was
	/// read as "=" ("134.3 =0.8mm"). A missed equation stays readable text; a spec value turned
	/// into an equation doesn't, so a line has to show math plainly.
	fileprivate enum Shape {
		/// Inequalities that open a spec table's limits.
		static let limits: Set<String> = ["<", ">", "≤", "≥", "⩽", "⩾", "≪", "≫", "<=", ">="]
		/// Units written after a number, spaced or not ("0.2 mm", "2g", "33.0 A"), as printed.
		static let units: Set<String> = [
			"nm", "mm", "cm", "m", "km", "in", "ft", "mg", "g", "kg", "lb", "lbs", "oz", "ms", "s", "min", "h",
			"ml", "mL", "l", "L", "mAh", "Ah", "Wh", "kWh", "mV", "V", "kV", "mA", "A", "mW", "W", "kW",
			"Hz", "kHz", "MHz", "GHz", "Pa", "kPa", "MPa", "psi", "PSI", "N", "J", "kJ", "C", "K",
		]

		/// Greek letters printed as units: ohms ("10 Ω", "8 mΩ") and micro ("5 µm").
		static let unitSymbols: Set<String> = ["Ω", "µ", "μ"]
		/// Unit prefixes written against a unit symbol ("mΩ", "kΩ").
		static let unitPrefixes: Set<String> = ["m", "k", "M"]

		/// True for a script, a math symbol or a Greek letter, or a relation or arrow with a
		/// variable to relate; false for a line that opens with an inequality and has no other
		/// relation, which is a limit with nothing on its left.
		static func isMath(_ lexemes: [Lexeme]) -> Bool {
			guard let first = lexemes.first, !isLimit(first, in: lexemes) else { return false }
			if lexemes.indices.contains(where: { isSymbolic(lexemes, at: $0) }) { return true }
			guard lexemes.contains(where: { $0.kind == .relation || $0.kind == .arrow }) else { return false }
			return lexemes.indices.contains { isVariable(lexemes, at: $0) }
		}

		/// True when `first` is an inequality opening `lexemes` and no other relation follows.
		static func isLimit(_ first: Lexeme, in lexemes: [Lexeme]) -> Bool {
			guard first.kind == .relation, limits.contains(first.source) else { return false }
			return !lexemes.dropFirst().contains { $0.kind == .relation }
		}

		/// Scripts, math symbols, radicals, big operators and Greek letters, which only math writes,
		/// unless they are a unit ("30psi", "10 Ω").
		static func isSymbolic(_ lexemes: [Lexeme], at index: Int) -> Bool {
			guard lexemes.indices.contains(index) else { return false }
			let lexeme = lexemes[index]
			switch lexeme.kind {
			case .caret, .underscore, .superscript, .subscriptRun, .radical, .nary: return true
			case .symbol: return !isUnit(lexemes, at: index)
			case .word: return [.greek, .radical].contains(Vocabulary.classify(lexeme.source)) && !isUnit(lexemes, at: index)
			default: return false
			}
		}

		/// True for a letter or name standing for a quantity (`x`, `Km`, `x1`, `sin`), not a unit
		/// (`isUnit`) or a prose word.
		static func isVariable(_ lexemes: [Lexeme], at index: Int) -> Bool {
			guard lexemes.indices.contains(index) else { return false }
			let lexeme = lexemes[index]
			if lexeme.kind == .letterDigits { return true }
			guard lexeme.kind == .word else { return false }
			switch Vocabulary.classify(lexeme.source) {
			case .letter, .identifier, .subscripted, .function: return !isUnit(lexemes, at: index)
			case .radical, .greek, .stopword, .prose: return false
			}
		}

		/// True for a unit after a number ("0.8mm", "2 g", "30psi", "10 Ω", "8 mΩ") or a degree sign
		/// ("37°C"), and for the capital that ends a model number ("35E", "3C").
		static func isUnit(_ lexemes: [Lexeme], at index: Int) -> Bool {
			guard index > 0, lexemes.indices.contains(index) else { return false }
			let lexeme = lexemes[index]
			let before = lexemes[index - 1]
			if before.kind == .degree { return !lexeme.spaced }
			if lexeme.kind == .symbol {
				guard unitSymbols.contains(lexeme.source) else { return false }
				let prefixed = index > 1 && lexemes[index - 2].kind == .number && unitPrefixes.contains(before.source) && !lexeme.spaced
				return before.kind == .number || prefixed
			}
			guard before.kind == .number else { return false }
			let isCode = !lexeme.spaced && lexeme.source.first?.isUppercase == true
			return isCode || units.contains(lexeme.source)
		}
	}
}

// MARK: - Conversion

extension EquationDetector {
	/// One operand or operator at a single bracket level, ready to render.
	fileprivate struct Term {
		/// How the term combines with its neighbours.
		enum Role: Hashable {
			case operand, function, nary, radical, relation, additive, product, punct
			case slash, caret, underscore, superscript, subscriptRun, open, close
		}

		var role: Role
		var latex: String
		/// Whitespace preceded it in the line.
		var spaced: Bool
		/// The interior of a parenthesised group, used where the parentheses are
		/// dropped: fraction parts, script and radical arguments.
		var inner: String?
		var hasSub = false
		var hasSup = false
	}

	/// One open bracket level while assembling.
	fileprivate struct Frame {
		/// LaTeX of the opening bracket; nil for the whole line.
		var opener: String?
		var spaced: Bool
		var terms: [Term] = []
	}

	/// Builds LaTeX from lexemes. Bracket levels live on an explicit stack and are
	/// rendered as they close (innermost first), so nothing recurses.
	fileprivate enum Converter {
		static let roles: [Lexeme.Kind: Term.Role] = [
			.number: .operand, .symbol: .operand, .relation: .relation, .arrow: .relation,
			.additive: .additive, .product: .product, .slash: .slash, .caret: .caret,
			.underscore: .underscore, .superscript: .superscript, .degree: .superscript,
			.subscriptRun: .subscriptRun, .radical: .radical, .nary: .nary, .open: .open, .close: .close,
			.punct: .punct, .currency: .punct,
		]
		static let openers: [String: String] = [")": "(", "]": "[", "\\}": "\\{"]
		static let wideRoles: Set<Term.Role> = [.relation, .product]
		static let scriptable: Set<Term.Role> = [.operand, .function, .nary]
		static let juxtaposable: Set<Term.Role> = [.operand, .function]
		static let closingPunctuation: Set<String> = ["!", "'", "''", "|", ")", "]"]
		/// Longest LaTeX command name `endsWithCommand` looks back over.
		static let commandScanLimit = 32

		static func term(for lexeme: Lexeme) -> Term {
			switch lexeme.kind {
			case .word:
				return wordTerm(lexeme)
			case .letterDigits:
				let latex = lexeme.latex + script("_", lexeme.script, braceSingle: false)
				return Term(role: .operand, latex: latex, spaced: lexeme.spaced, hasSub: true)
			default:
				return Term(role: roles[lexeme.kind] ?? .punct, latex: lexeme.latex, spaced: lexeme.spaced)
			}
		}

		static func wordTerm(_ lexeme: Lexeme) -> Term {
			let word = lexeme.source
			guard !word.isEmpty else { return Term(role: .punct, latex: "", spaced: lexeme.spaced) }
			switch Vocabulary.classify(word) {
			case .radical:
				return Term(role: .radical, latex: "\\sqrt", spaced: lexeme.spaced)
			case .function:
				return Term(role: .function, latex: "\\" + word, spaced: lexeme.spaced)
			case .greek:
				return Term(role: .operand, latex: "\\" + word, spaced: lexeme.spaced)
			case .subscripted:
				guard let split = Vocabulary.subscriptSplit(word) else { break }
				let latex = split.base + script("_", split.script, braceSingle: false)
				return Term(role: .operand, latex: latex, spaced: lexeme.spaced, hasSub: true)
			case .prose where word.count >= 4:
				return Term(role: .operand, latex: "\\text{" + word + "}", spaced: lexeme.spaced)
			default:
				break
			}
			return Term(role: .operand, latex: word, spaced: lexeme.spaced)
		}

		/// `_1`, `_{12}`, `^{2}`: subscripts brace only multi-character content, superscripts always.
		static func script(_ marker: String, _ content: String, braceSingle: Bool) -> String {
			guard content.count > 1 || braceSingle else { return marker + content }
			return marker + "{" + content + "}"
		}

		static func assemble(_ terms: [Term]) -> String? {
			guard !terms.isEmpty, terms.count <= EquationDetector.maxLineLength else { return nil }
			var frames = [Frame(opener: nil, spaced: false)]
			for term in terms {
				switch term.role {
				case .open:
					guard frames.count <= EquationDetector.maxNestingDepth else { return nil }
					frames.append(Frame(opener: term.latex, spaced: term.spaced))
				case .close:
					guard close(&frames, with: term) else { return nil }
				default:
					frames[frames.count - 1].terms.append(term)
				}
			}
			// Brackets OCR never closed close at the end of the line.
			for _ in 0..<EquationDetector.maxNestingDepth where frames.count > 1 {
				guard collapseTop(&frames, closer: "") else { return nil }
			}
			guard frames.count == 1, let root = frames.first else { return nil }
			return renderLevel(root.terms)
		}

		/// Closes the innermost level `closer` matches, implicitly closing any
		/// unclosed levels inside it; a closer nothing matches stays literal.
		static func close(_ frames: inout [Frame], with closer: Term) -> Bool {
			guard !frames.isEmpty else { return false }
			let wanted = openers[closer.latex]
			guard let level = frames.lastIndex(where: { $0.opener != nil && $0.opener == wanted }), level > 0 else {
				frames[frames.count - 1].terms.append(Term(role: .punct, latex: closer.latex, spaced: closer.spaced))
				return true
			}
			for _ in 0..<(frames.count - 1 - level) {
				guard collapseTop(&frames, closer: "") else { return false }
			}
			return collapseTop(&frames, closer: closer.latex)
		}

		/// Renders the innermost level and adds it to its parent as one operand.
		static func collapseTop(_ frames: inout [Frame], closer: String) -> Bool {
			guard frames.count > 1, let top = frames.popLast() else { return false }
			guard let interior = renderLevel(top.terms) else { return false }
			let opener = top.opener ?? ""
			var group = Term(role: .operand, latex: opener + interior + closer, spaced: top.spaced)
			if opener == "(", !interior.isEmpty { group.inner = interior }
			frames[frames.count - 1].terms.append(group)
			return true
		}

		static func renderLevel(_ terms: [Term]) -> String? {
			guard !terms.isEmpty else { return "" }
			guard let scripted = attachingScripts(terms) else { return nil }
			return render(fractions(scripted))
		}

		/// Applies `^`, `_`, Unicode scripts and radicals to their operands.
		static func attachingScripts(_ terms: [Term]) -> [Term]? {
			guard !terms.isEmpty else { return [] }
			var output: [Term] = []
			var index = 0
			// Each pass consumes at least one term.
			for _ in terms.indices {
				guard index < terms.count else { break }
				let term = terms[index]
				switch term.role {
				case .caret, .underscore, .radical:
					guard let operand = argument(of: terms, from: index + 1) else { return nil }
					if term.role == .radical {
						output.append(Term(role: .operand, latex: "\\sqrt{" + operand.content + "}", spaced: term.spaced))
					} else {
						attach(operand.content, superscript: term.role == .caret, to: &output, spaced: term.spaced)
					}
					index += 1 + operand.used
				case .superscript, .subscriptRun:
					attach(term.latex, superscript: term.role == .superscript, to: &output, spaced: term.spaced)
					index += 1
				default:
					output.append(term)
					index += 1
				}
			}
			return output
		}

		/// The operand at `index` (parentheses dropped), optionally signed: `^(n+1)`, `^-1`.
		static func argument(of terms: [Term], from index: Int) -> (content: String, used: Int)? {
			guard terms.indices.contains(index) else { return nil }
			let first = terms[index]
			if first.role == .operand { return (first.inner ?? first.latex, 1) }
			guard first.role == .additive, terms.indices.contains(index + 1), terms[index + 1].role == .operand else {
				return nil
			}
			let operand = terms[index + 1]
			return (first.latex + (operand.inner ?? operand.latex), 2)
		}

		static func attach(_ content: String, superscript: Bool, to output: inout [Term], spaced: Bool) {
			guard !content.isEmpty else { return }
			var base = Term(role: .operand, latex: "{}", spaced: spaced)
			if let last = output.last, scriptable.contains(last.role) {
				base = last
				output.removeLast()
			}
			if superscript ? base.hasSup : base.hasSub {
				base.latex = "{" + base.latex + "}"
				base.hasSub = false
				base.hasSup = false
			}
			base.latex += superscript ? script("^", content, braceSingle: true) : script("_", content, braceSingle: false)
			base.inner = nil
			if superscript { base.hasSup = true } else { base.hasSub = true }
			output.append(base)
		}

		/// `a / b` → `\frac{a}{b}`: the numerator is the juxtaposed run to the left
		/// (`Vmax[S]`), the denominator the operand to the right plus any operands
		/// written tight against it (`2a`, `[A][B]`); a space ends it.
		static func fractions(_ terms: [Term]) -> [Term] {
			guard terms.contains(where: { $0.role == .slash }) else { return terms }
			var output: [Term] = []
			var index = 0
			for _ in terms.indices {
				guard index < terms.count else { break }
				let term = terms[index]
				let run = term.role == .slash ? trailingRunLength(output) : 0
				guard run > 0, let below = denominator(of: terms, from: index + 1) else {
					output.append(term.role == .slash ? Term(role: .punct, latex: "/", spaced: term.spaced) : term)
					index += 1
					continue
				}
				let parts = Array(output.suffix(run))
				output.removeLast(run)
				let numerator = parts.count == 1 ? (parts[0].inner ?? render(parts)) : render(parts)
				let latex = "\\frac{" + numerator + "}{" + below.content + "}"
				output.append(Term(role: .operand, latex: latex, spaced: parts[0].spaced))
				index += 1 + below.used
			}
			return output
		}

		/// The operand at `index` and the unspaced operands after it. Parentheses are
		/// dropped only when the denominator is a single parenthesised group.
		static func denominator(of terms: [Term], from index: Int) -> (content: String, used: Int)? {
			guard let first = argument(of: terms, from: index) else { return nil }
			var tight: [Term] = []
			for next in terms.dropFirst(index + first.used) {
				guard next.role == .operand, !next.spaced else { break }
				tight.append(next)
			}
			guard !tight.isEmpty else { return first }
			let lead = Array(terms[index..<(index + first.used)])
			return (render(lead + tight), first.used + tight.count)
		}

		static func trailingRunLength(_ output: [Term]) -> Int {
			guard !output.isEmpty else { return 0 }
			var length = 0
			for term in output.reversed() {
				guard juxtaposable.contains(term.role) else { break }
				length += 1
			}
			return length
		}

		static func render(_ terms: [Term]) -> String {
			guard !terms.isEmpty else { return "" }
			var output = ""
			for index in terms.indices {
				let separator = gap(terms, before: index)
				let latex = terms[index].latex
				let needsSpace = separator.isEmpty && startsWithLetter(latex) && endsWithCommand(output)
				output += (needsSpace ? " " : separator) + latex
			}
			return output
		}

		/// Relations and products get spaces, as do binary `+`/`-`; unary signs, a
		/// trailing charge sign (`[A-]`) and punctuation stay attached; juxtaposed
		/// operands keep the line's spacing.
		static func gap(_ terms: [Term], before index: Int) -> String {
			guard index > 0, index < terms.count else { return "" }
			let term = terms[index]
			let previous = terms[index - 1]
			if wideRoles.contains(term.role) || wideRoles.contains(previous.role) { return " " }
			if term.role == .additive, index == terms.count - 1 { return "" }
			if term.role == .additive { return isBinary(terms, at: index) || term.spaced ? " " : "" }
			if previous.role == .additive { return isBinary(terms, at: index - 1) ? " " : "" }
			if term.role == .punct { return "" }
			return term.spaced ? " " : ""
		}

		static func isBinary(_ terms: [Term], at index: Int) -> Bool {
			guard index > 0, index < terms.count else { return false }
			let previous = terms[index - 1]
			if previous.role == .operand { return true }
			return previous.role == .punct && closingPunctuation.contains(previous.latex)
		}

		static func startsWithLetter(_ text: String) -> Bool {
			guard let first = text.first else { return false }
			return first.isASCII && first.isLetter
		}

		/// Whether `text` ends in a command name (`\Delta`), which a following letter would extend.
		static func endsWithCommand(_ text: String) -> Bool {
			guard !text.isEmpty else { return false }
			var sawLetter = false
			for character in text.reversed().prefix(commandScanLimit) {
				if character.isASCII && character.isLetter {
					sawLetter = true
					continue
				}
				return sawLetter && character == "\\"
			}
			return false
		}
	}
}

// MARK: - OCR bracket repair

extension EquationDetector {
	/// Fixes the commonest OCR slip in concentration brackets: a closing `]` read
	/// as `|`, `l` or `I` (`d[ES|/dt`, `[Sl)`), only where that `[` would otherwise
	/// never close.
	fileprivate enum BracketRepair {
		static func repaired(_ characters: [Character]) -> [Character] {
			guard characters.contains("["), characters.count <= EquationDetector.maxLineLength else { return characters }
			let closesLater = closingLookahead(characters)
			var result = characters
			var open = false
			for index in result.indices {
				let character = result[index]
				if character == "[" || character == "]" {
					open = character == "["
					continue
				}
				guard open, !closesLater[index], isSlip(result, at: index) else { continue }
				result[index] = "]"
				open = false
			}
			return result
		}

		/// For each index, whether a `]` follows it before the next `[`.
		static func closingLookahead(_ characters: [Character]) -> [Bool] {
			var result = [Bool](repeating: false, count: characters.count)
			guard !characters.isEmpty else { return result }
			var pending = false
			for index in characters.indices.reversed() {
				result[index] = pending
				if characters[index] == "]" { pending = true }
				if characters[index] == "[" { pending = false }
			}
			return result
		}

		static func isSlip(_ characters: [Character], at index: Int) -> Bool {
			guard index > 0, index < characters.count else { return false }
			let character = characters[index]
			let previous = characters[index - 1]
			guard previous.isLetter || previous.isNumber else { return false }
			if character == "|" { return true }
			guard character == "l" || character == "I", previous.isASCII, previous.isLetter else { return false }
			let next: Character? = index + 1 < characters.count ? characters[index + 1] : nil
			return next == nil || next == ")" || next == "/"
		}
	}
}

// MARK: - On-device model

#if canImport(FoundationModels)
/// The on-device language model step behind `EquationDetector.refine`: one
/// short, temperature-0 request raced against a deadline.
@available(iOS 26.0, macOS 26.0, *)
private enum ModelRefiner {
	static let instructions = """
		You correct LaTeX transcriptions of math that was read by OCR from handwritten or printed notes. \
		You get the OCR text and a candidate LaTeX conversion. Fix recognition slips (l or | read for ], \
		O for 0, an exponent read as a plain digit) and the structure. Reply with only the corrected LaTeX \
		on one line: no $ signs, no code fences, no explanation. Use only \\frac{}{}, _{} and ^{}, \\sqrt{}, \
		Greek letters such as \\alpha and \\Delta, \\cdot \\times \\pm \\leq \\geq \\neq \\approx \\infty \\to \
		\\sum \\int \\ln \\log \\sin \\cos \\exp, parentheses and square brackets. If the candidate is already \
		right, repeat it unchanged.
		Example — OCR text: F = Gm1m2 / r2 — Candidate LaTeX: F = \\frac{Gm_1m_2}{r_2} — \
		Corrected LaTeX: F = \\frac{G m_1 m_2}{r^{2}}
		"""
	/// Lines of a model answer that only wrap the LaTeX.
	static let wrapperLines: Set<String> = ["$$", "$", "\\[", "\\]", "\\(", "\\)"]
	/// Labels a model sometimes puts before its answer.
	static let answerLabels = ["corrected latex:", "latex:", "answer:"]
	/// Inline wrappers stripped from around a one-line answer.
	static let wrappers: [(open: String, close: String)] = [("$$", "$$"), ("$", "$"), ("\\[", "\\]"), ("\\(", "\\)"), ("`", "`")]

	/// The model's raw answer, or nil when it fails or misses the deadline.
	static func answer(candidate: String, linear: String) async -> String? {
		guard !candidate.isEmpty, !linear.isEmpty else { return nil }
		return await withTaskGroup(of: String?.self) { group in
			group.addTask { await ask(candidate: candidate, linear: linear) }
			group.addTask {
				do {
					try await Task.sleep(nanoseconds: EquationDetector.refineTimeoutNanoseconds)
				} catch {
					return nil
				}
				return nil
			}
			let first = await group.next() ?? nil
			group.cancelAll()
			return first
		}
	}

	static func ask(candidate: String, linear: String) async -> String? {
		guard !candidate.isEmpty, !linear.isEmpty else { return nil }
		let session = LanguageModelSession(instructions: instructions)
		let prompt = "OCR text: \(linear)\nCandidate LaTeX: \(candidate)\nCorrected LaTeX:"
		do {
			let response = try await session.respond(to: prompt, options: GenerationOptions(temperature: 0))
			return response.content
		} catch {
			return nil
		}
	}

	/// The LaTeX line of an answer with fences, labels and `$` wrappers removed;
	/// nil when it is empty, too long, or brings in words the OCR never read.
	static func cleaned(_ answer: String, candidate: String, linear: String) -> String? {
		guard !answer.isEmpty, answer.count <= EquationDetector.maxModelAnswerLength * 2 else { return nil }
		let lines = answer.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
		guard var latex = lines.first(where: { !$0.isEmpty && !$0.hasPrefix("```") && !wrapperLines.contains($0) }) else {
			return nil
		}
		for label in answerLabels where latex.lowercased().hasPrefix(label) {
			latex = String(latex.dropFirst(label.count)).trimmingCharacters(in: .whitespaces)
		}
		for wrapper in wrappers where latex.count > wrapper.open.count + wrapper.close.count
			&& latex.hasPrefix(wrapper.open) && latex.hasSuffix(wrapper.close) {
			latex = String(latex.dropFirst(wrapper.open.count).dropLast(wrapper.close.count))
				.trimmingCharacters(in: .whitespaces)
		}
		guard !latex.isEmpty, latex.count <= EquationDetector.maxModelAnswerLength else { return nil }
		guard introducesNoWords(latex, source: linear + " " + candidate) else { return nil }
		return latex
	}

	/// Guards against a chatty or invented answer: every plain letter run of three or
	/// more (outside command names) must already appear in the OCR text or candidate.
	static func introducesNoWords(_ latex: String, source: String) -> Bool {
		guard !latex.isEmpty else { return false }
		let known = source.lowercased()
		var word = ""
		var inCommand = false
		for character in latex + " " {
			if character.isLetter {
				if !inCommand { word.append(character) }
				continue
			}
			if word.count >= 3, !known.contains(word.lowercased()) { return false }
			word = ""
			inCommand = character == "\\"
		}
		return true
	}
}
#endif
