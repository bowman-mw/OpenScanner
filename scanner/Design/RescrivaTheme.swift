//
//  RescrivaTheme.swift
//  Rescriva (fork of Open Scanner)
//
//  Fernlet design-system tokens (colors_and_type.css) for SwiftUI: palette,
//  type roles, radii, shadows, motion and the parchment grain.
//
//  Serif is the document's voice; sans is the controls. Flags use goldenrod,
//  never red. Nothing shakes, nothing flashes.
//

import SwiftUI
import UIKit

// MARK: - Palette

extension Color {
	/// Primary background.
	static let parchment = Color(hex: 0xF5EFE0)
	/// Elevated surfaces, cards, sheets.
	static let cream = Color(hex: 0xFBF7EE)
	/// Primary text — dark brown, never black.
	static let bark = Color(hex: 0x3D2E1E)
	/// Secondary text, disabled states.
	static let slate = Color(hex: 0x7B8B99)
	/// Brand accent, primary actions.
	static let moss = Color(hex: 0x5A7A52)
	/// Secondary accent, progress, detection outline.
	static let fern = Color(hex: 0x8AAD7E)
	/// Muted fills and tinted backgrounds.
	static let lichen = Color(hex: 0xC8DBC2)
	/// Destructive actions only (delete), never errors.
	static let terracotta = Color(hex: 0xC0674A)
	/// Flags, highlights, warmth.
	static let goldenrod = Color(hex: 0xD4A843)
	/// The camera's dark surround.
	static let midnight = Color(hex: 0x1A1F2E)
	/// Paper white for scanned pages and thumbnails.
	static let paper = Color(hex: 0xFFFDF8)
	/// Ballpoint ink for handwriting renderings.
	static let ink = Color(hex: 0x2E3A4A)
	/// The warm backdrop behind original scans in review.
	static let scanBackdrop = Color(hex: 0xE9E4D8)
}

extension ShapeStyle where Self == Color {
	static var parchment: Color { Color.parchment }
	static var cream: Color { Color.cream }
	static var bark: Color { Color.bark }
	static var slate: Color { Color.slate }
	static var moss: Color { Color.moss }
	static var fern: Color { Color.fern }
	static var lichen: Color { Color.lichen }
	static var terracotta: Color { Color.terracotta }
	static var goldenrod: Color { Color.goldenrod }
}

// MARK: - Type

/// The Fernlet type roles. Each role prefers the design system's typeface when
/// it is bundled with the app and otherwise falls back to the closest system
/// face (New York for the serif roles, SF Pro for the interface). Sizes follow
/// Dynamic Type, capped so the layouts stay calm.
enum RescrivaFont {
	/// Logo only — Playfair Display Italic.
	static func wordmark(_ size: CGFloat) -> Font {
		font(names: ["PlayfairDisplay-Italic"], size: size, weight: .regular, italic: true, design: .serif, style: .largeTitle)
	}

	/// Hero and state — Fraunces 600.
	static func display(_ size: CGFloat) -> Font {
		font(names: ["Fraunces-SemiBold", "Fraunces9pt-SemiBold"], size: size, weight: .semibold, italic: false, design: .serif, style: .title1)
	}

	/// Section and document headers — DM Serif Display.
	static func header(_ size: CGFloat) -> Font {
		font(names: ["DMSerifDisplay-Regular"], size: size, weight: .regular, italic: false, design: .serif, style: .title2)
	}

	/// Document body — Instrument Serif.
	static func body(_ size: CGFloat, italic: Bool = false) -> Font {
		font(names: [italic ? "InstrumentSerif-Italic" : "InstrumentSerif-Regular"], size: size, weight: .regular, italic: italic, design: .serif, style: .body)
	}

	/// The companion's voice: thought bubbles, hints, gentle empty states.
	static func bubble(_ size: CGFloat) -> Font {
		body(size, italic: true)
	}

	/// Interface labels, buttons, settings — DM Sans.
	static func ui(_ size: CGFloat, weight: UIFont.Weight = .regular) -> Font {
		let name = weight >= .medium ? "DMSans-Medium" : "DMSans-Regular"
		return font(names: [name], size: size, weight: weight, italic: false, design: .default, style: .subheadline)
	}

	private static func font(names: [String], size: CGFloat, weight: UIFont.Weight, italic: Bool, design: UIFontDescriptor.SystemDesign, style: UIFont.TextStyle) -> Font {
		let metrics = UIFontMetrics(forTextStyle: style)
		let maximum = size * 1.6
		for name in names {
			if let custom = UIFont(name: name, size: size) {
				return Font(metrics.scaledFont(for: custom, maximumPointSize: maximum))
			}
		}
		var descriptor = UIFont.systemFont(ofSize: size, weight: weight).fontDescriptor
		if let serif = descriptor.withDesign(design) {
			descriptor = serif
		}
		if italic, let slanted = descriptor.withSymbolicTraits(descriptor.symbolicTraits.union(.traitItalic)) {
			descriptor = slanted
		}
		let base = UIFont(descriptor: descriptor, size: size)
		return Font(metrics.scaledFont(for: base, maximumPointSize: maximum))
	}
}

extension View {
	/// Sentence-case interface label: 12pt DM Sans medium, slate, slightly tracked.
	func rescrivaSectionLabel() -> some View {
		self.font(RescrivaFont.ui(12, weight: .medium))
			.tracking(0.24)
			.foregroundStyle(.slate)
	}
}

// MARK: - Shape & elevation

/// Corner radii — generous throughout, nothing sharp or punishing.
enum RescrivaRadius {
	/// Chips and tags.
	static let small: CGFloat = 10
	/// Cards and modals.
	static let medium: CGFloat = 18
	/// Bottom sheets and floating panels.
	static let large: CGFloat = 28
	/// Thought bubbles and full-bleed cards.
	static let extraLarge: CGFloat = 40
}

/// Warm-tinted shadows (never cold grey). CSS blur radii are halved for SwiftUI.
enum RescrivaShadow {
	case small, card, float, sheet
}

extension View {
	/// Applies one of the Fernlet shadow tokens.
	@ViewBuilder
	func rescrivaShadow(_ shadow: RescrivaShadow) -> some View {
		switch shadow {
		case .small:
			self.shadow(color: Color.bark.opacity(0.10), radius: 2, x: 0, y: 1)
		case .card:
			self.shadow(color: Color.bark.opacity(0.08), radius: 4, x: 0, y: 2)
				.shadow(color: Color.bark.opacity(0.05), radius: 12, x: 0, y: 6)
		case .float:
			self.shadow(color: Color.bark.opacity(0.12), radius: 16, x: 0, y: 8)
				.shadow(color: Color.bark.opacity(0.08), radius: 4, x: 0, y: 2)
		case .sheet:
			self.shadow(color: Color.bark.opacity(0.10), radius: 12, x: 0, y: -4)
		}
	}

	/// Cream card with the card radius and shadow.
	func rescrivaCard(padding: CGFloat = 16, radius: CGFloat = RescrivaRadius.medium) -> some View {
		self.padding(padding)
			.background(Color.cream, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
			.rescrivaShadow(.card)
	}
}

// MARK: - Motion

/// Motion tokens: ease-out or spring only, never linear.
enum RescrivaMotion {
	/// UI transitions (250 ms).
	static let ui = Animation.timingCurve(0.22, 0.61, 0.36, 1, duration: 0.25)
	/// Quick feedback (150 ms).
	static let fast = Animation.timingCurve(0.22, 0.61, 0.36, 1, duration: 0.15)
	/// Gentle spring for toggles and celebrations.
	static let spring = Animation.spring(response: 0.32, dampingFraction: 0.68)
	/// Loading transitions (700 ms).
	static let load = Animation.timingCurve(0.25, 0.46, 0.45, 0.94, duration: 0.7)
}

extension AnyTransition {
	/// Entry: float in (rise 10pt and fade). Exit: dissolve. No slides.
	static var floatIn: AnyTransition {
		.asymmetric(
			insertion: .opacity.combined(with: .offset(y: 10)),
			removal: .opacity
		)
	}
}

/// Physical press feedback: scale to 0.92–0.97 with a quick ease-out.
struct PressScaleStyle: ButtonStyle {
	var scale: CGFloat = 0.92

	func makeBody(configuration: Configuration) -> some View {
		configuration.label
			.scaleEffect(configuration.isPressed ? scale : 1)
			.animation(RescrivaMotion.fast, value: configuration.isPressed)
	}
}

// MARK: - Texture

/// Parchment grain: a tiled noise texture at ~6% over parchment, so no surface
/// is a flat digital rectangle.
struct GrainBackground: View {
	var base: Color = .parchment

	var body: some View {
		ZStack {
			base
			Image(uiImage: GrainTexture.tile)
				.resizable(resizingMode: .tile)
				.opacity(0.06)
				.blendMode(.multiply)
		}
		.ignoresSafeArea()
		.accessibilityHidden(true)
	}
}

/// Generates the 160×160 noise tile once per launch with a fixed seed, so the
/// grain never shimmers between renders.
enum GrainTexture {
	static let tile: UIImage = {
		let side = 160
		var generator = SeededGenerator(seed: 0x5EED)
		var pixels = [UInt8](repeating: 0, count: side * side * 4)
		for index in stride(from: 0, to: pixels.count, by: 4) {
			let value = UInt8.random(in: 0...255, using: &generator)
			pixels[index] = value
			pixels[index + 1] = value
			pixels[index + 2] = value
			pixels[index + 3] = 255
		}
		let provider = CGDataProvider(data: Data(pixels) as CFData)
		guard let provider,
			  let image = CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
								  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
								  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
		else { return UIImage() }
		return UIImage(cgImage: image)
	}()
}

/// SplitMix64 — deterministic, so textures and sample content are stable.
struct SeededGenerator: RandomNumberGenerator {
	private var state: UInt64

	init(seed: UInt64) {
		state = seed
	}

	mutating func next() -> UInt64 {
		state &+= 0x9E3779B97F4A7C15
		var z = state
		z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
		z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
		return z ^ (z >> 31)
	}
}
