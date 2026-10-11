//
//  RecognizedItemView.swift
//  Open Scanner → Folio
//
//  Created by Slaven Radic on 2024-09-01.
//  Folio: one recognized line — goldenrod rule (moss when selected), inline
//  editing, and chips for the links, emails, phone numbers and addresses
//  Open Scanner detects.
//

import SwiftUI

struct RecognizedItemView: View {
	@ObservedObject var item: ScanRecognizedItem
	let isSelected: Bool
	let isEditing: Bool
	let onTap: () -> Void
	let onEndEditing: () -> Void

	@State private var transcript = ""
	@FocusState private var focused: Bool

	var body: some View {
		VStack(alignment: .leading, spacing: 6) {
			HStack(alignment: .top, spacing: 12) {
				Capsule()
					.fill(isSelected ? Color.moss : Color.goldenrod)
					.frame(width: 4)
				if isEditing {
					TextField("Line text", text: $transcript, axis: .vertical)
						.font(FolioFont.body(16))
						.foregroundStyle(.bark)
						.lineLimit(1...12)
						.focused($focused)
						.onChange(of: transcript) { _, changed in
							item.transcript = changed
							item.parent?.parent?.lastUpdate = Date()
						}
						.onSubmit(onEndEditing)
						.onChange(of: focused) { _, isFocused in
							if !isFocused { onEndEditing() }
						}
				} else {
					Text(item.transcript ?? "")
						.font(FolioFont.body(16))
						.lineSpacing(3)
						.foregroundStyle(.bark)
						.frame(maxWidth: .infinity, alignment: .leading)
				}
			}
			.padding(.vertical, 10)
			.padding(.leading, 8)
			.padding(.trailing, 12)
			.background(isSelected ? Color.moss.opacity(0.10) : Color.clear,
						in: RoundedRectangle(cornerRadius: 14, style: .continuous))
			.contentShape(Rectangle())
			.onTapGesture(perform: onTap)
			.animation(FolioMotion.ui, value: isSelected)
			.accessibilityElement(children: .combine)
			.accessibilityAddTraits(.isButton)
			.accessibilityAddTraits(isSelected ? .isSelected : [])

			ForEach(tags, id: \.text) { tag in
				DataTagChip(tag: tag)
					.padding(.leading, 24)
			}
		}
		.onAppear { transcript = item.transcript ?? "" }
		.onChange(of: isEditing) { _, editing in
			transcript = item.transcript ?? ""
			focused = editing
		}
	}

	/// Links, emails, phone numbers and addresses found in the line.
	private var tags: [DataTag] {
		var result: [DataTag] = []
		if let email = item.emailAddress {
			result.append(DataTag(kind: .email, text: email))
		}
		if let url = item.urlAddress {
			result.append(DataTag(kind: .link, text: url))
		}
		if let phone = item.phoneNumber {
			result.append(DataTag(kind: .phone, text: phone))
		}
		if let address = item.mailingAddress {
			result.append(DataTag(kind: .address, text: address))
		}
		return result
	}
}

/// Something actionable Open Scanner's data detector found in a line.
struct DataTag {
	enum Kind {
		case email, link, phone, address
	}

	let kind: Kind
	let text: String

	var systemImage: String {
		switch kind {
		case .email: return "envelope"
		case .link: return "link"
		case .phone: return "phone"
		case .address: return "map"
		}
	}

	var url: URL? {
		let encoded = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? text
		switch kind {
		case .email: return URL(string: "mailto:\(encoded)")
		case .link: return URL(string: text.hasPrefix("http") ? text : "https://\(text)")
		case .phone: return URL(string: "tel:\(text.filter { $0.isNumber || $0 == "+" })")
		case .address: return URL(string: "maps://?address=\(encoded)")
		}
	}
}

/// A lichen chip that opens the detected item.
struct DataTagChip: View {
	let tag: DataTag
	@Environment(\.openURL) private var openURL

	var body: some View {
		Button {
			if let url = tag.url { openURL(url) }
		} label: {
			HStack(spacing: 6) {
				Image(systemName: tag.systemImage)
					.font(.system(size: 13, weight: .regular))
				Text(tag.text)
					.font(FolioFont.ui(13, weight: .medium))
					.lineLimit(1)
			}
			.foregroundStyle(.moss)
			.padding(.vertical, 6)
			.padding(.horizontal, 10)
			.background(Color.lichen, in: RoundedRectangle(cornerRadius: FolioRadius.small, style: .continuous))
		}
		.buttonStyle(PressScaleStyle(scale: 0.95))
	}
}
