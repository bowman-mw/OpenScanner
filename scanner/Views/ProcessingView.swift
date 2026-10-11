//
//  ProcessingView.swift
//  Folio (fork of Open Scanner)
//
//  "Rebuilding your notes": a calm, step-by-step view of the on-device
//  rebuild. Each step lingers at least ~¾ s so it reads as care, not a flash.
//

import SwiftUI

struct ProcessingView: View {
	@Environment(FolioRouter.self) private var router
	@ObservedObject var scan: Scan

	@State private var stages: [RebuildStage] = []
	@State private var current = 0
	@State private var finished = false

	private let tier = DeviceTier.current

	var body: some View {
		ZStack {
			Color.parchment.ignoresSafeArea()
			VStack(spacing: 28) {
				paperStack
				VStack(spacing: 6) {
					Text(finished ? "Ready to look over" : "Rebuilding your notes")
						.font(FolioFont.display(28))
						.foregroundStyle(.bark)
						.contentTransition(.opacity)
					Text("Everything stays on this iPhone.")
						.font(FolioFont.bubble(15))
						.foregroundStyle(Color.bark.opacity(0.7))
				}
				.multilineTextAlignment(.center)
				.accessibilityElement(children: .combine)

				VStack(alignment: .leading, spacing: 10) {
					ForEach(Array(stages.enumerated()), id: \.element) { index, stage in
						let done = index < current || finished
						let active = index == current && !finished
						HStack(spacing: 12) {
							ZStack {
								Circle()
									.strokeBorder(Color.fern, lineWidth: 1.5)
									.background(Circle().fill(done ? Color.fern : Color.clear))
								if done {
									Image(systemName: "checkmark")
										.font(.system(size: 11, weight: .bold))
										.foregroundStyle(.cream)
								}
							}
							.frame(width: 22, height: 22)
							Text(stage.label(for: scan.rebuiltDocument))
								.font(FolioFont.ui(14))
								.foregroundStyle(.bark)
						}
						.opacity(done || active ? 1 : 0.4)
						.animation(.easeOut(duration: 0.4), value: current)
						.accessibilityElement(children: .combine)
						.accessibilityValue(done ? Text("Done") : active ? Text("In progress") : Text("Waiting"))
					}
				}
				.frame(maxWidth: .infinity, alignment: .leading)
			}
			.padding(.horizontal, 40)
		}
		.task { await run() }
	}

	/// Two tilted pages with a fern sweep moving down as the steps complete.
	private var paperStack: some View {
		ZStack {
			RoundedRectangle(cornerRadius: 4, style: .continuous)
				.fill(Color.paper)
				.rotationEffect(.degrees(-5))
				.folioShadow(.card)
			ZStack(alignment: .top) {
				Color.paper
				VStack(alignment: .leading, spacing: 8) {
					Capsule().fill(Color.moss).frame(width: 72, height: 8)
					ForEach([0.92, 0.84, 0.88], id: \.self) { fraction in
						Capsule().fill(Color.bark.opacity(0.2)).frame(width: 116 * fraction, height: 3)
					}
					HStack(spacing: 8) {
						RoundedRectangle(cornerRadius: 4).strokeBorder(Color.fern, lineWidth: 1.5).frame(width: 44, height: 22)
						RoundedRectangle(cornerRadius: 4).strokeBorder(Color.fern, lineWidth: 1.5).frame(width: 44, height: 22)
					}
					.padding(.top, 8)
				}
				.padding(.vertical, 18)
				.padding(.horizontal, 16)
				.frame(maxWidth: .infinity, alignment: .leading)

				LinearGradient(colors: [Color.fern.opacity(0), Color.fern.opacity(0.35)], startPoint: .top, endPoint: .bottom)
					.frame(height: 36)
					.overlay(alignment: .bottom) { Rectangle().fill(Color.fern).frame(height: 2) }
					.offset(y: CGFloat(min(finished ? stages.count : current, 4)) * 38 - 20)
					.animation(FolioMotion.load, value: current)
					.animation(FolioMotion.load, value: finished)
			}
			.clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
			.rotationEffect(.degrees(2))
			.folioShadow(.float)
		}
		.frame(width: 150, height: 190)
		.accessibilityHidden(true)
	}

	private func run() async {
		stages = RebuildStage.stages(for: tier, document: scan.rebuiltDocument)
		let progress = RebuildProgress()
		let rebuilder = Rebuilder(tier: tier)
		let stageList = stages
		let work = Task { @MainActor in
			_ = await rebuilder.document(for: scan) { stage in
				if let index = stageList.firstIndex(of: stage) {
					progress.started = max(progress.started, index)
				}
			}
			progress.done = true
		}
		// Each step completes once the work has moved past it, and no sooner
		// than ~750 ms after the previous one.
		var lastStep = ContinuousClock.now
		while !(progress.done && current >= stages.count) {
			try? await Task.sleep(for: .milliseconds(100))
			if Task.isCancelled {
				work.cancel()
				return
			}
			let completed = progress.done ? stages.count : progress.started
			if current < completed, ContinuousClock.now - lastStep >= .milliseconds(750) {
				current += 1
				lastStep = ContinuousClock.now
			}
		}
		finished = true
		try? await Task.sleep(for: .milliseconds(500))
		guard router.top == .processing(scan) else { return }
		router.replaceTop(with: .review(scan))
	}
}

/// Shared between the rebuild task and the step animation.
@MainActor
private final class RebuildProgress {
	var started = 0
	var done = false
}
