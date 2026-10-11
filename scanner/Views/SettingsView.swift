//
//  SettingsView.swift
//  Folio (fork of Open Scanner)
//
//  Settings — what this iPhone can do, scanning preferences, and About
//  (Open Scanner's AboutView, which this replaces, lives on as the
//  acknowledgement and its MIT licence notice).
//

import SwiftUI

struct SettingsView: View {
	@Environment(FolioRouter.self) private var router

	@AppStorage(FolioPreference.autoCapture) private var autoCapture = true
	@AppStorage(FolioPreference.removeShadows) private var removeShadows = true
	@AppStorage(FolioPreference.keepMarkerColors) private var keepMarkerColors = true
	@AppStorage(FolioPreference.companionTips) private var companionTips = true
	@State private var sheet: InfoSheet?

	private let tier = DeviceTier.current

	var body: some View {
		ZStack {
			GrainBackground()
			ScrollView {
				VStack(alignment: .leading, spacing: 0) {
					HStack {
						BackPill(title: "Scans") { router.pop() }
						Spacer()
					}
					.padding(.horizontal, 12)
					.padding(.vertical, 6)

					Text("Settings")
						.font(FolioFont.header(30))
						.foregroundStyle(.bark)
						.padding(.horizontal, 20)
						.padding(.top, 12)
						.padding(.bottom, 16)
						.accessibilityAddTraits(.isHeader)

					tierCard
					sectionLabel("Scanning")
					toggles
					sectionLabel("About")
					about
				}
				.padding(.bottom, 60)
			}
			.overlay(alignment: .top) { StatusBarScrim() }
		}
		.sheet(item: $sheet) { sheet in
			InfoSheetView(sheet: sheet)
		}
	}

	private func sectionLabel(_ title: LocalizedStringKey) -> some View {
		Text(title)
			.folioSectionLabel()
			.padding(.horizontal, 20)
			.padding(.top, 22)
			.padding(.bottom, 8)
			.accessibilityAddTraits(.isHeader)
	}

	private var tierCard: some View {
		VStack(alignment: .leading, spacing: 10) {
			HStack {
				Text("This iPhone").folioSectionLabel()
				Spacer()
				Text(tier.displayName)
					.font(FolioFont.ui(12, weight: .medium))
					.foregroundStyle(.bark)
					.padding(.vertical, 4)
					.padding(.horizontal, 10)
					.background(tierChipColor, in: RoundedRectangle(cornerRadius: FolioRadius.small, style: .continuous))
			}
			Text(tier.summary)
				.font(FolioFont.body(17))
				.lineSpacing(4)
				.foregroundStyle(.bark)
			VStack(alignment: .leading, spacing: 6) {
				capability("Searchable PDF", on: true)
				capability("Word and Slides from typed pages", on: tier.canRebuild)
				capability("Handwriting, equations and diagrams", on: tier == .smart)
			}
			.padding(.top, 4)
		}
		.frame(maxWidth: .infinity, alignment: .leading)
		.folioCard(padding: 18)
		.padding(.horizontal, 16)
	}

	private var tierChipColor: Color {
		switch tier {
		case .smart: return .lichen
		case .basic: return Color.goldenrod.opacity(0.25)
		case .pdf: return Color.bark.opacity(0.08)
		}
	}

	private func capability(_ label: LocalizedStringKey, on: Bool) -> some View {
		HStack(spacing: 10) {
			Image(systemName: "checkmark")
				.font(.system(size: 9, weight: .bold))
				.foregroundStyle(.cream)
				.frame(width: 18, height: 18)
				.background(on ? Color.fern : Color.bark.opacity(0.25), in: Circle())
			Text(label)
				.font(FolioFont.ui(14))
				.foregroundStyle(.bark)
		}
		.opacity(on ? 1 : 0.45)
		.accessibilityElement(children: .combine)
		.accessibilityValue(on ? Text("Available") : Text("Not on this iPhone"))
	}

	private var toggles: some View {
		VStack(spacing: 0) {
			settingRow("Auto-capture", detail: "Takes the shot once the page is steady", isOn: $autoCapture)
			Divider().overlay(Color.bark.opacity(0.06))
			settingRow("Remove shadows", detail: "Evens out lighting on paper", isOn: $removeShadows)
			Divider().overlay(Color.bark.opacity(0.06))
			settingRow("Keep marker colors", detail: "Whiteboard diagrams keep their ink", isOn: $keepMarkerColors)
			Divider().overlay(Color.bark.opacity(0.06))
			settingRow("Companion tips", detail: "Little notes about what I see on the page", isOn: $companionTips)
		}
		.background(Color.cream, in: RoundedRectangle(cornerRadius: FolioRadius.medium, style: .continuous))
		.folioShadow(.card)
		.padding(.horizontal, 16)
	}

	private func settingRow(_ title: LocalizedStringKey, detail: LocalizedStringKey, isOn: Binding<Bool>) -> some View {
		Toggle(isOn: isOn) {
			VStack(alignment: .leading, spacing: 2) {
				Text(title)
					.font(FolioFont.ui(15, weight: .medium))
					.foregroundStyle(.bark)
				Text(detail)
					.font(FolioFont.ui(12))
					.foregroundStyle(.slate)
			}
		}
		.toggleStyle(FolioToggleStyle())
		.padding(.vertical, 14)
		.padding(.horizontal, 16)
	}

	private var about: some View {
		VStack(alignment: .leading, spacing: 10) {
			Text("Everything you scan is read and rebuilt on this iPhone. No accounts, no uploads, no per-page fees.")
				.font(FolioFont.body(16))
				.lineSpacing(4)
				.foregroundStyle(.bark)
			Text("Built on Open Scanner by Pencil Research (MIT).")
				.font(FolioFont.ui(13))
				.lineSpacing(3)
				.foregroundStyle(.slate)
			HStack(spacing: 16) {
				Button("Need help?") { sheet = .help }
				Button("Acknowledgements") { sheet = .acknowledgements }
				Button("Privacy") { sheet = .privacy }
			}
			.font(FolioFont.ui(14, weight: .medium))
			.foregroundStyle(.moss)
			Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "•.•") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "•"))")
				.font(FolioFont.ui(12))
				.foregroundStyle(.slate)
		}
		.frame(maxWidth: .infinity, alignment: .leading)
		.folioCard()
		.padding(.horizontal, 16)
	}
}

/// The three About pages.
enum InfoSheet: String, Identifiable {
	case help, acknowledgements, privacy

	var id: String { rawValue }
}

private struct InfoSheetView: View {
	let sheet: InfoSheet
	@Environment(\.dismiss) private var dismiss

	var body: some View {
		VStack(alignment: .leading, spacing: 14) {
			SheetHeader(title: title, trailing: (String(localized: "Done"), { dismiss() }))
			ScrollView {
				Text(text)
					.font(sheet == .acknowledgements ? FolioFont.ui(13) : FolioFont.body(16))
					.lineSpacing(4)
					.foregroundStyle(.bark)
					.frame(maxWidth: .infinity, alignment: .leading)
					.textSelection(.enabled)
			}
		}
		.padding(20)
		.presentationDetents([.medium, .large])
		.presentationDragIndicator(.visible)
		.presentationCornerRadius(FolioRadius.large)
		.presentationBackground(Color.cream)
	}

	private var title: String {
		switch sheet {
		case .help: return String(localized: "Need help?")
		case .acknowledgements: return String(localized: "Acknowledgements")
		case .privacy: return String(localized: "Privacy")
		}
	}

	private var text: String {
		switch sheet {
		case .help:
			return String(localized: """
				Scan: tap Scan, hold the page in the frame, and Folio takes the shot once it's steady (or tap the shutter). Keep adding pages, then tap Save.

				Whiteboards: choose Whiteboard so glare is flattened and marker colors are kept.

				Rebuild: on a scan, pick Word or Slides under "Make it into", then rebuild. Dotted words are ones Folio wasn't sure about — tap them to fix.

				Search: the Library searches every word in every scan.
				""")
		case .privacy:
			return String(localized: """
				Folio reads, rebuilds and exports your scans on this iPhone. It has no account, no analytics and no advertising, and it never uploads your pages to us or anyone else.

				If iCloud is on for this app, your scans sync through your own private iCloud database so they appear on your other devices — Apple stores them, we can't see them.

				Camera access is used only while you're scanning.
				""")
		case .acknowledgements:
			return """
				Folio is a fork of Open Scanner.

				MIT License

				Copyright (c) 2024 Pencil Research

				Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

				The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

				THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
				"""
		}
	}
}
