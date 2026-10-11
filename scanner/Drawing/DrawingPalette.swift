//
//  DrawingPalette.swift
//  Folio (fork of Open Scanner)
//
//  The colours and shape names the drawing editor offers: marker-like
//  border colours and pale fills from the Fernlet palette, so a recreated
//  whiteboard keeps its colours without clashing with the rest of Folio.
//

import SwiftUI

/// The border and fill swatches the drawing editor offers.
enum DrawingPalette {
	/// One swatch; a nil colour means "none" (fills only).
	struct Swatch: Identifiable, Hashable {
		let id: String
		let name: String
		let color: RGBColor?
	}

	static let borders: [Swatch] = [
		Swatch(id: "ink", name: String(localized: "Ink"), color: RGBColor(hex: 0x2E3A4A)),
		Swatch(id: "moss", name: String(localized: "Moss"), color: RGBColor(hex: 0x5A7A52)),
		Swatch(id: "terracotta", name: String(localized: "Terracotta"), color: RGBColor(hex: 0xC0674A)),
		Swatch(id: "goldenrod", name: String(localized: "Goldenrod"), color: RGBColor(hex: 0xB8902F)),
		Swatch(id: "slate", name: String(localized: "Slate"), color: RGBColor(hex: 0x5F7384)),
		Swatch(id: "bark", name: String(localized: "Bark"), color: RGBColor(hex: 0x3D2E1E)),
	]

	static let fills: [Swatch] = [
		Swatch(id: "none", name: String(localized: "No fill"), color: nil),
		Swatch(id: "paper", name: String(localized: "Paper"), color: RGBColor(hex: 0xFFFDF8)),
		Swatch(id: "lichen", name: String(localized: "Lichen"), color: RGBColor(hex: 0xE3EDDE)),
		Swatch(id: "blush", name: String(localized: "Blush"), color: RGBColor(hex: 0xF5E3DB)),
		Swatch(id: "wheat", name: String(localized: "Wheat"), color: RGBColor(hex: 0xF6EBCB)),
		Swatch(id: "mist", name: String(localized: "Mist"), color: RGBColor(hex: 0xDFE5EA)),
	]

	/// The border a new shape starts with.
	static var defaultBorder: RGBColor { borders[0].color ?? RGBColor(hex: 0x2E3A4A) }
	/// The fill a new shape starts with.
	static var defaultFill: RGBColor? { fills[1].color }
}

extension RGBColor {
	/// The colour for SwiftUI.
	var swiftUI: Color { Color(red: red, green: green, blue: blue) }
}

extension Diagram.Shape {
	/// Every shape, in the order the editor's palette shows them.
	static let paletteOrder: [Diagram.Shape] = [.rectangle, .roundedRectangle, .ellipse, .diamond, .parallelogram]

	/// The shape's name on screen (the raw value is a stored token).
	var displayName: String {
		switch self {
		case .rectangle: return String(localized: "Rectangle")
		case .roundedRectangle: return String(localized: "Rounded rectangle")
		case .ellipse: return String(localized: "Ellipse")
		case .diamond: return String(localized: "Diamond")
		case .parallelogram: return String(localized: "Parallelogram")
		}
	}
}

extension Diagram.Direction {
	/// The connector kind's name on screen.
	var displayName: String {
		switch self {
		case .forward: return String(localized: "Arrow")
		case .none: return String(localized: "Line")
		case .both: return String(localized: "Double arrow")
		}
	}
}
