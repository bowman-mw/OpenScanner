//
//  ScanStartPicker.swift
//  Open Scanner → Folio
//
//  Created by Slaven Radic on 2024-09-01.
//  Folio: the moss Scan button and the menu of ways to start a scan.
//

import SwiftUI

/// Ways to start a scan from the Library.
enum ScanStart: CaseIterable {
	case document, whiteboard, photos, pdf

	var label: LocalizedStringKey {
		switch self {
		case .document: return "Scan a document"
		case .whiteboard: return "Whiteboard"
		case .photos: return "Import photos"
		case .pdf: return "Import a PDF"
		}
	}

	var detail: LocalizedStringKey {
		switch self {
		case .document: return "Pages, receipts, books"
		case .whiteboard: return "Flattens glare, keeps marker colors"
		case .photos: return "From your library"
		case .pdf: return "Rebuild or add text"
		}
	}

	var systemImage: String {
		switch self {
		case .document: return "doc.viewfinder"
		case .whiteboard: return "rectangle.and.pencil.and.ellipsis"
		case .photos: return "photo"
		case .pdf: return "doc.badge.plus"
		}
	}
}

struct ScanStartPicker: View {
	@Binding var isOpen: Bool
	var isBusy = false
	/// What the button says while busy, e.g. "Opening page 3 of 12".
	var busyTitle: String?
	let onChoose: (ScanStart) -> Void

	var body: some View {
		VStack(alignment: .trailing, spacing: 10) {
			if isOpen {
				menu
					.transition(.floatIn)
			}
			Button {
				withAnimation(FolioMotion.ui) { isOpen.toggle() }
			} label: {
				HStack(spacing: 10) {
					if isBusy {
						ProgressView().tint(.cream)
					} else {
						Image(systemName: isOpen ? "xmark" : "plus.viewfinder")
							.font(.system(size: isOpen ? 18 : 24, weight: .light))
							.frame(width: 26, height: 26)
					}
					Group {
						if isBusy, let busyTitle {
							Text(busyTitle).monospacedDigit()
						} else {
							Text(isOpen ? "Close" : "Scan")
						}
					}
					.font(FolioFont.ui(16, weight: .medium))
				}
				.foregroundStyle(.cream)
				.frame(height: 60)
				.padding(.leading, 18)
				.padding(.trailing, 24)
				.background(Color.moss, in: Capsule())
				.shadow(color: Color.bark.opacity(0.22), radius: 12, x: 0, y: 8)
			}
			.buttonStyle(PressScaleStyle(scale: 0.93))
			.disabled(isBusy)
			.accessibilityLabel(buttonLabel)
		}
	}

	private var buttonLabel: Text {
		if isBusy, let busyTitle { return Text(busyTitle) }
		return Text(isOpen ? "Close scan options" : "Start a scan")
	}

	private var menu: some View {
		VStack(spacing: 0) {
			ForEach(ScanStart.allCases, id: \.self) { start in
				Button {
					onChoose(start)
				} label: {
					HStack(spacing: 12) {
						Image(systemName: start.systemImage)
							.font(.system(size: 18, weight: .light))
							.foregroundStyle(.moss)
							.frame(width: 36, height: 36)
							.background(Color.lichen, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
						VStack(alignment: .leading, spacing: 1) {
							Text(start.label)
								.font(FolioFont.ui(14, weight: .medium))
								.foregroundStyle(.bark)
							Text(start.detail)
								.font(FolioFont.ui(12))
								.foregroundStyle(.slate)
						}
						Spacer(minLength: 0)
					}
					.padding(.vertical, 11)
					.padding(.horizontal, 12)
					.contentShape(Rectangle())
				}
				.buttonStyle(PickerRowStyle())
			}
		}
		.padding(8)
		.frame(minWidth: 236, maxWidth: 280)
		.background(Color.cream, in: RoundedRectangle(cornerRadius: FolioRadius.large, style: .continuous))
		.folioShadow(.float)
	}
}

/// Picker rows tint softly with moss while pressed.
private struct PickerRowStyle: ButtonStyle {
	func makeBody(configuration: Configuration) -> some View {
		configuration.label
			.background(Color.moss.opacity(configuration.isPressed ? 0.08 : 0), in: RoundedRectangle(cornerRadius: FolioRadius.medium, style: .continuous))
			.animation(FolioMotion.fast, value: configuration.isPressed)
	}
}

struct ScanStartPicker_Previews: PreviewProvider {
	static var previews: some View {
		ScanStartPicker(isOpen: .constant(true)) { _ in }
			.padding()
			.background(Color.parchment)
	}
}
