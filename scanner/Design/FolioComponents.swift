//
//  FolioComponents.swift
//  Folio (fork of Open Scanner)
//
//  Small reusable pieces of the Fernlet look: pills, chips, toggles, thought
//  bubbles, the toast, paper thumbnails and the frosted bottom bar.
//

import SwiftUI

/// "‹ Scans" — the cream back pill at the top-left of every inner screen.
struct BackPill: View {
	let title: LocalizedStringKey
	let action: () -> Void

	var body: some View {
		Button(action: action) {
			HStack(spacing: 2) {
				Image(systemName: "chevron.left")
					.font(.system(size: 17, weight: .regular))
				Text(title)
					.font(FolioFont.ui(14, weight: .medium))
			}
			.foregroundStyle(.bark)
			.frame(height: 40)
			.padding(.leading, 8)
			.padding(.trailing, 14)
			.background(Color.cream, in: Capsule())
			.folioShadow(.small)
		}
		.buttonStyle(PressScaleStyle(scale: 0.94))
		.accessibilityLabel(Text("Back to \(Text(title))"))
	}
}

/// A 40pt cream circle holding one SF Symbol.
struct CircleIconButton: View {
	let systemName: String
	let label: LocalizedStringKey
	let action: () -> Void

	var body: some View {
		Button(action: action) {
			Image(systemName: systemName)
				.font(.system(size: 17, weight: .regular))
				.foregroundStyle(.bark)
				.frame(width: 40, height: 40)
				.background(Color.cream, in: Circle())
				.folioShadow(.small)
		}
		.buttonStyle(PressScaleStyle())
		.accessibilityLabel(Text(label))
	}
}

/// A selectable chip: bark when chosen, cream otherwise.
struct ChoiceChip: View {
	let label: LocalizedStringKey
	let isSelected: Bool
	var fillsWidth = false
	let action: () -> Void

	var body: some View {
		Button(action: action) {
			Text(label)
				.font(FolioFont.ui(13, weight: .medium))
				.foregroundStyle(isSelected ? Color.cream : Color.bark)
				.padding(.vertical, fillsWidth ? 9 : 7)
				.padding(.horizontal, fillsWidth ? 0 : 14)
				.frame(maxWidth: fillsWidth ? .infinity : nil)
				.background(isSelected ? Color.bark : Color.cream,
							in: RoundedRectangle(cornerRadius: FolioRadius.small, style: .continuous))
				.animation(FolioMotion.ui, value: isSelected)
		}
		.buttonStyle(PressScaleStyle(scale: 0.95))
		.accessibilityAddTraits(isSelected ? .isSelected : [])
	}
}

/// The Fernlet switch: moss track when on, warm grey when off, spring knob.
struct FolioToggleStyle: ToggleStyle {
	func makeBody(configuration: Configuration) -> some View {
		HStack(spacing: 12) {
			configuration.label
			Spacer(minLength: 0)
			ZStack(alignment: configuration.isOn ? .trailing : .leading) {
				Capsule()
					.fill(configuration.isOn ? Color.moss : Color.bark.opacity(0.16))
					.frame(width: 51, height: 31)
				Circle()
					.fill(Color.cream)
					.frame(width: 27, height: 27)
					.shadow(color: Color.bark.opacity(0.25), radius: 2, x: 0, y: 1)
					.padding(2)
			}
			.animation(FolioMotion.spring, value: configuration.isOn)
			.onTapGesture { configuration.isOn.toggle() }
		}
		.contentShape(Rectangle())
		.accessibilityElement(children: .combine)
		.accessibilityAddTraits(.isButton)
		.accessibilityValue(Text(configuration.isOn ? "On" : "Off"))
		.accessibilityAction { configuration.isOn.toggle() }
	}
}

/// The companion's voice: a cream bubble with two trailing dots.
struct ThoughtBubble: View {
	let text: String
	var showsTrail = true

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			Text(text)
				.font(FolioFont.bubble(15))
				.lineSpacing(3)
				.foregroundStyle(.bark)
				.padding(.vertical, 12)
				.padding(.horizontal, 18)
				.background(Color.cream, in: RoundedRectangle(cornerRadius: FolioRadius.extraLarge, style: .continuous))
				.folioShadow(.card)
			if showsTrail {
				HStack(alignment: .top, spacing: 4) {
					Circle().fill(Color.cream).frame(width: 9, height: 9).folioShadow(.small)
					Circle().fill(Color.cream).frame(width: 5, height: 5).folioShadow(.small).padding(.top, 8)
				}
				.padding(.leading, 22)
				.padding(.top, 4)
			}
		}
		.frame(maxWidth: .infinity, alignment: .leading)
		.transition(.floatIn)
	}
}

/// A transient confirmation at the top of the screen.
struct ToastView: View {
	let message: String
	var actionLabel: String?
	var action: (() -> Void)?

	var body: some View {
		HStack(spacing: 10) {
			Image(systemName: "checkmark")
				.font(.system(size: 11, weight: .bold))
				.foregroundStyle(.cream)
				.frame(width: 22, height: 22)
				.background(Color.fern, in: Circle())
			Text(message)
				.font(FolioFont.ui(14))
				.foregroundStyle(.cream)
				.frame(maxWidth: .infinity, alignment: .leading)
			if let actionLabel, let action {
				Button(actionLabel, action: action)
					.font(FolioFont.ui(14, weight: .medium))
					.foregroundStyle(.lichen)
			}
		}
		.padding(.vertical, 12)
		.padding(.horizontal, 16)
		.background(Color.bark, in: RoundedRectangle(cornerRadius: FolioRadius.medium, style: .continuous))
		.folioShadow(.float)
		.padding(.horizontal, 24)
		.accessibilityElement(children: .combine)
		.accessibilityAddTraits(.isStaticText)
	}
}

/// A soft parchment fade behind the status bar, so scrolled content doesn't
/// collide with the clock.
struct StatusBarScrim: View {
	var body: some View {
		LinearGradient(stops: [.init(color: .parchment, location: 0), .init(color: .parchment.opacity(0.92), location: 0.55), .init(color: .parchment.opacity(0), location: 1)],
					   startPoint: .top, endPoint: .bottom)
			.frame(height: 14)
			.ignoresSafeArea(edges: .top)
			.allowsHitTesting(false)
			.accessibilityHidden(true)
	}
}

/// A segmented choice: a warm track with the chosen option on a cream pill.
struct FolioSegmentedPicker<Option: Hashable>: View {
	let options: [Option]
	@Binding var selection: Option
	let label: (Option) -> LocalizedStringKey

	var body: some View {
		HStack(spacing: 0) {
			ForEach(options, id: \.self) { option in
				Button {
					withAnimation(FolioMotion.ui) { selection = option }
				} label: {
					Text(label(option))
						.font(FolioFont.ui(13, weight: .medium))
						.foregroundStyle(.bark)
						.frame(maxWidth: .infinity)
						.padding(.vertical, 7)
						.background {
							if selection == option {
								RoundedRectangle(cornerRadius: 9, style: .continuous)
									.fill(Color.cream)
									.folioShadow(.small)
							}
						}
						.contentShape(Rectangle())
				}
				.buttonStyle(.plain)
				.accessibilityAddTraits(selection == option ? .isSelected : [])
			}
		}
		.padding(3)
		.background(Color.bark.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
	}
}

/// The moss primary action.
struct PrimaryButton: View {
	let title: LocalizedStringKey
	var systemImage: String?
	var height: CGFloat = 54
	var isBusy = false
	let action: () -> Void

	var body: some View {
		Button(action: action) {
			HStack(spacing: 8) {
				if isBusy {
					ProgressView().tint(.cream)
				} else if let systemImage {
					Image(systemName: systemImage)
						.font(.system(size: 17, weight: .regular))
				}
				Text(title)
					.font(FolioFont.ui(16, weight: .medium))
			}
			.foregroundStyle(.cream)
			.frame(maxWidth: .infinity)
			.frame(height: height)
			.background(Color.moss, in: RoundedRectangle(cornerRadius: FolioRadius.medium, style: .continuous))
		}
		.buttonStyle(PressScaleStyle(scale: 0.96))
		.disabled(isBusy)
	}
}

/// Frosted parchment bar pinned to the bottom with the sheet radius.
struct FrostedBottomBar<Content: View>: View {
	@ViewBuilder var content: Content

	var body: some View {
		VStack(spacing: 12) {
			content
		}
		.padding(.horizontal, 20)
		.padding(.top, 14)
		.padding(.bottom, 12)
		.frame(maxWidth: .infinity)
		.background {
			UnevenRoundedRectangle(topLeadingRadius: FolioRadius.large, topTrailingRadius: FolioRadius.large, style: .continuous)
				.fill(.ultraThinMaterial)
				.overlay {
					UnevenRoundedRectangle(topLeadingRadius: FolioRadius.large, topTrailingRadius: FolioRadius.large, style: .continuous)
						.fill(Color.parchment.opacity(0.78))
				}
				.folioShadow(.sheet)
				.ignoresSafeArea(edges: .bottom)
		}
	}
}

/// A page thumbnail on paper: the scanned image when there is one, otherwise
/// a few ink bars standing in for lines of text.
struct PaperThumbnail: View {
	var image: UIImage?
	var width: CGFloat
	var height: CGFloat
	var ink: Color = .moss
	var grayscale = 0.0
	var contrast = 1.0
	var saturation = 1.0

	var body: some View {
		ZStack {
			Color.paper
			if let image {
				Image(uiImage: image)
					.resizable()
					.scaledToFill()
					.frame(width: width, height: height)
					.clipped()
					.grayscale(grayscale)
					.contrast(contrast)
					.saturation(saturation)
			} else {
				PlaceholderLines(ink: ink)
					.padding(.vertical, height * 0.12)
					.padding(.horizontal, width * 0.13)
			}
		}
		.frame(width: width, height: height)
		.clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
		.shadow(color: Color.bark.opacity(0.16), radius: 1.5, x: 0, y: 1)
		.accessibilityHidden(true)
	}
}

/// Ink bars: a title bar and four lines.
struct PlaceholderLines: View {
	var ink: Color = .moss

	var body: some View {
		GeometryReader { proxy in
			let w = proxy.size.width
			VStack(alignment: .leading, spacing: max(2, proxy.size.height * 0.08)) {
				Capsule().fill(ink).frame(width: w * 0.6, height: max(3, proxy.size.height * 0.08))
				ForEach([0.9, 0.8, 0.86, 0.5], id: \.self) { fraction in
					Capsule().fill(Color.bark.opacity(0.18)).frame(width: w * fraction, height: 2)
				}
			}
		}
	}
}

/// Sheet title row used by the export and flag sheets.
struct SheetHeader: View {
	let title: String
	var subtitle: String?
	var trailing: (label: String, action: () -> Void)?

	var body: some View {
		HStack(alignment: .firstTextBaseline) {
			VStack(alignment: .leading, spacing: 2) {
				Text(title)
					.font(FolioFont.header(22))
					.foregroundStyle(.bark)
				if let subtitle {
					Text(subtitle)
						.font(FolioFont.ui(13))
						.foregroundStyle(.slate)
				}
			}
			Spacer()
			if let trailing {
				Button(trailing.label, action: trailing.action)
					.font(FolioFont.ui(14, weight: .medium))
					.foregroundStyle(.moss)
			}
		}
	}
}
