//
//  ExportSheet.swift
//  Folio (fork of Open Scanner)
//
//  Export: pick a format (Word, PowerPoint, searchable PDF, plain text),
//  decide about notes, and share — which includes Save to Files.
//

import SwiftUI
import UIKit

struct ExportSheet: View {
	@ObservedObject var scan: Scan
	let initialFormat: ExportFormat
	var onFinished: ((String) -> Void)?

	@Environment(\.dismiss) private var dismiss
	@State private var format: ExportFormat = .pdf
	@State private var includeNotes = true
	@State private var isWorking = false
	@State private var failure: String?

	private let tier = DeviceTier.current

	var body: some View {
		VStack(alignment: .leading, spacing: 14) {
			SheetHeader(title: String(localized: "Export"), trailing: (String(localized: "Cancel"), { dismiss() }))

			HStack(spacing: 6) {
				Text(scan.displayTitle)
					.font(FolioFont.ui(15))
					.foregroundStyle(.bark)
					.lineLimit(1)
					.truncationMode(.tail)
				Spacer(minLength: 0)
				Text(format.fileExtension)
					.font(FolioFont.ui(14, weight: .medium))
					.foregroundStyle(.slate)
			}
			.padding(.horizontal, 14)
			.frame(height: 44)
			.background(Color.parchment, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
			.accessibilityElement(children: .combine)

			VStack(spacing: 6) {
				ForEach(ExportFormat.allCases) { option in
					formatRow(option)
				}
			}

			Toggle(isOn: $includeNotes) {
				Text(format.notesLabel)
					.font(FolioFont.ui(14))
					.foregroundStyle(.bark)
			}
			.toggleStyle(FolioToggleStyle())
			.padding(.horizontal, 4)

			if let failure {
				Text(failure)
					.font(FolioFont.ui(12))
					.foregroundStyle(.slate)
			}

			PrimaryButton(title: "Share", systemImage: "square.and.arrow.up", isBusy: isWorking, action: share)
		}
		.padding(.horizontal, 20)
		.padding(.top, 8)
		.padding(.bottom, 12)
		.onAppear {
			format = initialFormat.needsRebuild && !tier.canRebuild ? .pdf : initialFormat
		}
		.presentationDetents([.height(510)])
		.presentationDragIndicator(.visible)
		.presentationCornerRadius(FolioRadius.large)
		.presentationBackground(Color.cream)
	}

	private func formatRow(_ option: ExportFormat) -> some View {
		let locked = option.needsRebuild && !tier.canRebuild
		let selected = format == option
		return Button {
			if !locked {
				withAnimation(FolioMotion.ui) { format = option }
			}
		} label: {
			HStack(spacing: 12) {
				ZStack {
					Circle().strokeBorder(selected ? Color.moss : Color.bark.opacity(0.3), lineWidth: 1.5)
					Circle().fill(selected ? Color.moss : Color.clear).frame(width: 10, height: 10)
				}
				.frame(width: 20, height: 20)
				VStack(alignment: .leading, spacing: 1) {
					Text(option.label)
						.font(FolioFont.ui(15, weight: .medium))
						.foregroundStyle(.bark)
					Text(option.detail)
						.font(FolioFont.ui(12))
						.foregroundStyle(.slate)
				}
				Spacer(minLength: 0)
			}
			.padding(.vertical, 12)
			.padding(.horizontal, 14)
			.background(selected ? Color.lichen.opacity(0.5) : Color.parchment,
						in: RoundedRectangle(cornerRadius: 14, style: .continuous))
			.opacity(locked ? 0.4 : 1)
		}
		.buttonStyle(.plain)
		.disabled(locked)
		.accessibilityAddTraits(selected ? .isSelected : [])
		.accessibilityHint(locked ? Text("Needs a newer iPhone") : Text(""))
	}

	private func share() {
		isWorking = true
		failure = nil
		Task {
			do {
				let url = try await ExportService.makeFile(for: scan, format: format, includeNotes: includeNotes)
				isWorking = false
				let name = url.lastPathComponent
				SharePresenter.share([url]) { activity, completed in
					guard completed else { return }
					let savedToFiles = activity?.rawValue.contains("SaveToFiles") ?? false
					onFinished?(savedToFiles ? String(localized: "Saved “\(name)” to Files") : String(localized: "Shared “\(name)”"))
					dismiss()
				}
			} catch {
				isWorking = false
				failure = String(localized: "That didn't work — the file couldn't be written. Try again, or pick another format.")
			}
		}
	}
}
