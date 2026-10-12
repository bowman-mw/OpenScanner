//
//  EquationDetectorTests.swift
//  Rescriva (fork of Open Scanner)
//
//  Equation detection (math vs prose) and linear-reading → LaTeX conversion,
//  including OCR-garbled readings, the input bounds, and the refine fallback.
//

import XCTest
@testable import scanner

/// Covers `EquationDetector`: `mathScore`, `latex(fromLinear:)` and `refine`.
final class EquationDetectorTests: XCTestCase {

	// MARK: Detection

	func testEquationsScoreAtOrAboveTheThreshold() {
		let equations = [
			"v = Vmax[S] / (Km + [S])",
			"d[ES]/dt = 0",
			"E = mc²",
			"x² + y² = r²",
			"Δ G = −RT ln K",
			"y = mx + b",
			"A = πr²",
			"sin²θ + cos²θ = 1",
			"k = A e^(-Ea/RT)",
			"H₂O ⇌ H⁺ + OH⁻",
		]
		for line in equations {
			XCTAssertGreaterThanOrEqual(EquationDetector.mathScore(line), EquationDetector.threshold, line)
		}
	}

	func testOCRGarbledEquationsAreStillDetected() {
		let garbled = [
			"v = Vmax[S] / (Km + [Sl)",
			"v = Vmax[S] / (Km + [S]",
			"x2 + y2 = r2",
			"d[ES|/dt = 0",
			"d[ES]/dt = O",
			"E = mc2",
		]
		for line in garbled {
			XCTAssertGreaterThanOrEqual(EquationDetector.mathScore(line), EquationDetector.threshold, line)
		}
	}

	func testProseScoresBelowTheThreshold() {
		let prose = [
			"Plot Lineweaver–Burk.",
			"Repeat trial 3 at 37°C",
			"Questions → lab@uni.edu",
			"Total 28.73",
			"Page 1 of 7",
			"3 pages · Today at 9:14",
			"Q3 product review",
			"saturuted. Past that, more substrate = litle effect.",
			"Week 6 - Enzyme kinetics",
			"substrate → ES complex → product, enzyme released",
			"- steady-state assumption",
			"Michaelis-Menten derivation",
			"2 × $4.99 = $9.98",
			"10/10/2026",
			"Call 1-800-555-0199",
			"where k = 0.5 is the rate",
			"In the beginning",
		]
		for line in prose {
			XCTAssertLessThan(EquationDetector.mathScore(line), EquationDetector.threshold, line)
		}
	}

	func testSpecSheetValuesAreNotEquations() {
		let values = [
			"INR18650-35E", "INR 18650-35E", "INR 18650 - 35E", "AMP-TDS-SA30-2",
			"C/5", "-C/5 -C/2 -1C -2C", "340 Wh/kg", "770 Wh/L", "33.0 A (3C)", "2.20 A (C/5)",
			"≤ 8 mΩ", "≤ 20 mR", "< 5%", "134.3 =0.8mm", "21.70 =0.2 mm", "111.2 = 2g", "106.5 + 2g",
			"+1C/-1C, 100% DOD to 80% SOH", "60°C -50°C-40°C", "= +0.5C/-1C, 4.2-2.75V, 0.1C taper",
			"+0.5C/-0.5C and +0.2C/-0.2C, 100% DoD at Room Temp, 30psi", "5 µm", "10 Ω", "Resistance 8 mΩ",
		]
		for line in values {
			XCTAssertEqual(EquationDetector.mathScore(line), 0, line)
		}
	}

	func testCoefficientsUnitsContinuationsAndReactionsStillScoreAsMath() {
		for line in ["2x + 3 = 7", "F = 9.8 N", "T = 37°C", "a ≤ b + 1", "= 2x + 1", "2H2 + O2 → 2H2O", "μ = 5", "R = 10 Ω"] {
			XCTAssertGreaterThanOrEqual(EquationDetector.mathScore(line), EquationDetector.threshold, line)
		}
	}

	func testModelNumbersAndSpecValuesStayParagraphs() async {
		let lines = ["INR 18650-35E", "340 Wh/kg", "134.3 =0.8mm"]
		let page = RescrivaPage(blocks: lines.map { RescrivaBlock(content: .paragraph(runs: [RescrivaRun(text: $0)], alignment: .leading)) })
		let detected = await Rebuilder.detectEquations(in: [page], lines: [[]])
		XCTAssertEqual(detected, [page])
	}

	func testScoreStaysInRangeAndIgnoresEmptyOrOverlongLines() {
		XCTAssertEqual(EquationDetector.mathScore(""), 0)
		XCTAssertEqual(EquationDetector.mathScore("   \n"), 0)
		XCTAssertEqual(EquationDetector.mathScore(String(repeating: "x+", count: 200)), 0)
		for line in ["v = Vmax[S] / (Km + [S])", "∑∫√∞ = = = ^^^", "Total 28.73", "x"] {
			let score = EquationDetector.mathScore(line)
			XCTAssertTrue((0...1).contains(score), line)
		}
	}

	// MARK: Conversion

	func testMichaelisMentenRespectsPrecedenceAndStripsDenominatorParentheses() {
		XCTAssertEqual(EquationDetector.latex(fromLinear: "v = Vmax[S] / (Km + [S])"), "v = \\frac{V_{max}[S]}{K_m + [S]}")
		XCTAssertEqual(EquationDetector.latex(fromLinear: "d[ES]/dt = 0"), "\\frac{d[ES]}{dt} = 0")
		XCTAssertEqual(EquationDetector.latex(fromLinear: "y = x + 1/2"), "y = x + \\frac{1}{2}")
	}

	func testDenominatorTakesOperandsWrittenTightAgainstIt() {
		XCTAssertEqual(EquationDetector.latex(fromLinear: "x = (-b ± √(b² - 4ac)) / 2a"),
					   "x = \\frac{-b \\pm \\sqrt{b^{2} - 4ac}}{2a}")
		XCTAssertEqual(EquationDetector.latex(fromLinear: "Keq = [C][D] / [A][B]"), "K_{eq} = \\frac{[C][D]}{[A][B]}")
		XCTAssertEqual(EquationDetector.latex(fromLinear: "KE = 1/2 mv²"), "KE = \\frac{1}{2} mv^{2}")
		XCTAssertEqual(EquationDetector.latex(fromLinear: "x = 1/(a+b)c"), "x = \\frac{1}{(a + b)c}")
	}

	func testSuperscripts() {
		XCTAssertEqual(EquationDetector.latex(fromLinear: "E = mc²"), "E = mc^{2}")
		XCTAssertEqual(EquationDetector.latex(fromLinear: "x² + y² = r²"), "x^{2} + y^{2} = r^{2}")
		XCTAssertEqual(EquationDetector.latex(fromLinear: "x^2 = 4"), "x^{2} = 4")
		XCTAssertEqual(EquationDetector.latex(fromLinear: "a^(n+1)"), "a^{n + 1}")
		XCTAssertEqual(EquationDetector.latex(fromLinear: "e^(-kt) = 0.5"), "e^{-kt} = 0.5")
		XCTAssertEqual(EquationDetector.latex(fromLinear: "k = s⁻¹"), "k = s^{-1}")
		XCTAssertEqual(EquationDetector.latex(fromLinear: "T = 37°C"), "T = 37^{\\circ}C")
	}

	func testSubscriptsOnlyForSafePatterns() {
		XCTAssertEqual(EquationDetector.latex(fromLinear: "x1 + x2 = 1"), "x_1 + x_2 = 1")
		XCTAssertEqual(EquationDetector.latex(fromLinear: "x12 = 0"), "x_{12} = 0")
		XCTAssertEqual(EquationDetector.latex(fromLinear: "Vmax = Kcat"), "V_{max} = K_{cat}")
		XCTAssertEqual(EquationDetector.latex(fromLinear: "Km = Keq"), "K_m = K_{eq}")
		XCTAssertEqual(EquationDetector.latex(fromLinear: "x₁ + x₂ = 1"), "x_1 + x_2 = 1")
		// Real words and unlisted tails are never split.
		XCTAssertEqual(EquationDetector.latex(fromLinear: "In = At"), "In = At")
		XCTAssertEqual(EquationDetector.latex(fromLinear: "Kd = 5"), "Kd = 5")
		XCTAssertEqual(EquationDetector.latex(fromLinear: "PV = nRT"), "PV = nRT")
	}

	func testGreekFunctionsAndOperators() {
		XCTAssertEqual(EquationDetector.latex(fromLinear: "Δ G = −RT ln K"), "\\Delta G = -RT \\ln K")
		XCTAssertEqual(EquationDetector.latex(fromLinear: "alpha + beta = gamma"), "\\alpha + \\beta = \\gamma")
		XCTAssertEqual(EquationDetector.latex(fromLinear: "A = πr²"), "A = \\pi r^{2}")
		XCTAssertEqual(EquationDetector.latex(fromLinear: "a × b · c ≤ d"), "a \\times b \\cdot c \\leq d")
		XCTAssertEqual(EquationDetector.latex(fromLinear: "x ± 1 ≠ ∞"), "x \\pm 1 \\neq \\infty")
		XCTAssertEqual(EquationDetector.latex(fromLinear: "x ≥ 0 → y ≈ 1"), "x \\geq 0 \\to y \\approx 1")
		XCTAssertEqual(EquationDetector.latex(fromLinear: "x <= 1"), "x \\leq 1")
		XCTAssertEqual(EquationDetector.latex(fromLinear: "y = exp(-x) + sin(x)"), "y = \\exp(-x) + \\sin(x)")
		XCTAssertEqual(EquationDetector.latex(fromLinear: "sin²θ + cos²θ = 1"), "\\sin^{2}\\theta + \\cos^{2}\\theta = 1")
	}

	func testRadicalsSumsAndIntegrals() {
		XCTAssertEqual(EquationDetector.latex(fromLinear: "√x = 2"), "\\sqrt{x} = 2")
		XCTAssertEqual(EquationDetector.latex(fromLinear: "sqrt(x+1) = 3"), "\\sqrt{x + 1} = 3")
		XCTAssertEqual(EquationDetector.latex(fromLinear: "Σ x = ∑ y"), "\\sum x = \\sum y")
		XCTAssertEqual(EquationDetector.latex(fromLinear: "∫ f(x) dx"), "\\int f(x) dx")
	}

	func testOCRBracketSlipsAreRepaired() {
		XCTAssertEqual(EquationDetector.latex(fromLinear: "v = Vmax[S] / (Km + [Sl)"), "v = \\frac{V_{max}[S]}{K_m + [S]}")
		XCTAssertEqual(EquationDetector.latex(fromLinear: "d[ES|/dt = 0"), "\\frac{d[ES]}{dt} = 0")
		// A bracket that does close is left alone.
		XCTAssertEqual(EquationDetector.latex(fromLinear: "[|x|] = 1"), "[|x|] = 1")
	}

	func testUnclosedParenthesisClosesAtTheEndOfTheLine() {
		XCTAssertEqual(EquationDetector.latex(fromLinear: "v = Vmax[S] / (Km + [S]"), "v = \\frac{V_{max}[S]}{K_m + [S]}")
	}

	func testEveryConversionIsAcceptedByLaTeXToOMML() throws {
		let lines = [
			"v = Vmax[S] / (Km + [S])", "1/v = (Km/Vmax)(1/[S]) + 1/Vmax", "pH = pKa + log([A-]/[HA])",
			"50% of x = y", "{a} = b & c #1", "H₂O ⇌ H⁺ + OH⁻", "f'(x) = 2x", "n! = n(n-1)!",
			"a//b", ")x(", "x²³", "x^2^3",
		]
		for line in lines {
			let latex = try XCTUnwrap(EquationDetector.latex(fromLinear: line), line)
			XCTAssertNotNil(LaTeXToOMML.convert(latex), "\(line) → \(latex)")
		}
	}

	func testUnconvertibleOrUnboundedInputReturnsNil() {
		XCTAssertNil(EquationDetector.latex(fromLinear: ""))
		XCTAssertNil(EquationDetector.latex(fromLinear: "  "))
		XCTAssertNil(EquationDetector.latex(fromLinear: "x^"))
		XCTAssertNil(EquationDetector.latex(fromLinear: "√"))
		XCTAssertNil(EquationDetector.latex(fromLinear: "a \\frac b"))
		XCTAssertNil(EquationDetector.latex(fromLinear: String(repeating: "x+", count: 200)))
		let deep = String(repeating: "(", count: EquationDetector.maxNestingDepth + 2) + "x"
			+ String(repeating: ")", count: EquationDetector.maxNestingDepth + 2)
		XCTAssertNil(EquationDetector.latex(fromLinear: deep))
		let allowed = String(repeating: "(", count: EquationDetector.maxNestingDepth) + "x"
			+ String(repeating: ")", count: EquationDetector.maxNestingDepth)
		XCTAssertNotNil(EquationDetector.latex(fromLinear: allowed))
	}

	// MARK: Refine

	func testRefineKeepsTheCandidateForEmptyOrOverlongInput() async {
		let empty = await EquationDetector.refine("x^{2}", linear: "")
		XCTAssertEqual(empty, "x^{2}")
		let overlong = await EquationDetector.refine("x^{2}", linear: String(repeating: "x", count: 400))
		XCTAssertEqual(overlong, "x^{2}")
		let noCandidate = await EquationDetector.refine("", linear: "x2")
		XCTAssertEqual(noCandidate, "")
	}

	func testRefineAlwaysReturnsLaTeXThatConverts() async throws {
		// Where the on-device model is unavailable this is the candidate; where it
		// runs, whatever comes back must still be accepted by LaTeXToOMML.
		let linear = "x2 + y2 = r2"
		let candidate = try XCTUnwrap(EquationDetector.latex(fromLinear: linear))
		let refined = await EquationDetector.refine(candidate, linear: linear)
		XCTAssertNotNil(LaTeXToOMML.convert(refined), refined)
	}
}
