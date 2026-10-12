//
//  ProcessingView.swift
//  Rescriva (fork of Open Scanner)
//
//  "Rebuilding your notes": a calm, step-by-step view of the on-device
//  rebuild. Each step lingers at least ~¾ s so it reads as care, not a flash;
//  the step in progress spins and counts its pages or words, so a long PDF
//  never looks stuck. Review opens only once the document is there.
//

import SwiftUI

struct ProcessingView: View {
	@Environment(RescrivaRouter.self) private var router
	@ObservedObject var scan: Scan

	@State private var stages: [RebuildStage] = []
	@State private var current = 0
	@State private var finished = false
	/// The rebuild's latest count, shown under the step in progress.
	@State private var latest: RebuildProgress?

	private let tier = DeviceTier.current

	/// From this many pages, the screen says a rebuild takes a few minutes.
	private static let longDocumentPages = 10

	var body: some View {
		ZStack {
			Color.parchment.ignoresSafeArea()
			VStack(spacing: 28) {
				paperStack
				VStack(spacing: 6) {
					Text(finished ? "Ready to look over" : "Rebuilding your notes")
						.font(RescrivaFont.display(28))
						.foregroundStyle(.bark)
						.contentTransition(.opacity)
					Text("Everything stays on this iPhone.")
						.font(RescrivaFont.bubble(15))
						.foregroundStyle(Color.bark.opacity(0.7))
					if !finished, scan.capturesArray.count >= Self.longDocumentPages {
						Text("Long documents take a few minutes.")
							.font(RescrivaFont.bubble(15))
							.foregroundStyle(Color.bark.opacity(0.7))
					}
				}
				.multilineTextAlignment(.center)
				.accessibilityElement(children: .combine)

				VStack(alignment: .leading, spacing: 10) {
					ForEach(Array(stages.enumerated()), id: \.element) { index, stage in
						let done = index < current || finished
						let active = index == current && !finished
						let count = active && latest?.stage == stage ? latest : nil
						HStack(alignment: .top, spacing: 12) {
							marker(done: done, active: active)
							VStack(alignment: .leading, spacing: 6) {
								Text(stage.label(for: scan.rebuiltDocument))
									.font(RescrivaFont.ui(14))
									.foregroundStyle(.bark)
								if let count, let detail = count.detail {
									Text(detail)
										.font(RescrivaFont.ui(12, weight: .medium))
										.foregroundStyle(Color.bark.opacity(0.7))
										.monospacedDigit()
									ProgressView(value: Double(min(count.done, count.total)), total: Double(max(count.total, 1)))
										.tint(.fern)
										.animation(RescrivaMotion.ui, value: count.done)
								}
							}
							.padding(.top, 2)
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

	/// A filled check once a step is done, a spinner while it runs, an empty ring before.
	private func marker(done: Bool, active: Bool) -> some View {
		ZStack {
			if active {
				ProgressView()
					.controlSize(.small)
					.tint(.fern)
			} else {
				Circle()
					.strokeBorder(Color.fern, lineWidth: 1.5)
					.background { Circle().fill(done ? Color.fern : Color.clear) }
				if done {
					Image(systemName: "checkmark")
						.font(.system(size: 11, weight: .bold))
						.foregroundStyle(.cream)
				}
			}
		}
		.frame(width: 22, height: 22)
	}

	/// How far down the paper the sweep sits, in steps: the steps done plus the counted part of
	/// the one in progress, so it creeps down page by page through a long document.
	private var sweepPosition: Double {
		guard !finished else { return Double(stages.count) }
		guard let latest, latest.total > 0, stages.indices.contains(current), latest.stage == stages[current] else {
			return Double(current)
		}
		return Double(current) + Double(min(latest.done, latest.total)) / Double(latest.total)
	}

	/// Two tilted pages with a fern sweep moving down as the steps complete.
	private var paperStack: some View {
		ZStack {
			RoundedRectangle(cornerRadius: 4, style: .continuous)
				.fill(Color.paper)
				.rotationEffect(.degrees(-5))
				.rescrivaShadow(.card)
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
					.offset(y: CGFloat(min(sweepPosition, 4)) * 38 - 20)
					.animation(RescrivaMotion.load, value: sweepPosition)
			}
			.clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
			.rotationEffect(.degrees(2))
			.rescrivaShadow(.float)
		}
		.frame(width: 150, height: 190)
		.accessibilityHidden(true)
	}

	private func run() async {
		stages = RebuildStage.stages(for: tier, document: scan.rebuiltDocument)
		let tracker = RebuildTracker()
		let rebuilder = Rebuilder(tier: tier)
		let stageList = stages
		let work = Task { @MainActor in
			_ = await rebuilder.document(for: scan) { step in
				tracker.latest = step
				if let index = stageList.firstIndex(of: step.stage) {
					tracker.started = max(tracker.started, index)
				}
			}
			tracker.done = true
		}
		guard await revealSteps(tracker: tracker, work: work) else { return }
		finished = true
		do {
			try await Task.sleep(for: .milliseconds(500))
		} catch {
			return
		}
		guard router.top == .processing(scan) else { return }
		router.replaceTop(with: .review(scan))
	}

	/// Upper bound on 100 ms animation ticks (an hour) for one rebuild. Past it the steps stop
	/// moving, but Review still waits for the document.
	private static let maxTicks = 36_000

	/// Completes each step once the work has moved past it, and no sooner than
	/// ~750 ms after the previous one, showing the latest count as it goes. Returns
	/// once the work is done, or false if cancelled (which cancels the work).
	private func revealSteps(tracker: RebuildTracker, work: Task<Void, Never>) async -> Bool {
		var lastStep = ContinuousClock.now
		for _ in 0..<Self.maxTicks where !(tracker.done && current >= stages.count) {
			do {
				try await Task.sleep(for: .milliseconds(100))
			} catch {
				work.cancel()
				return false
			}
			if latest != tracker.latest {
				latest = tracker.latest
			}
			let completed = tracker.done ? stages.count : tracker.started
			if current < completed, ContinuousClock.now - lastStep >= .milliseconds(750) {
				current += 1
				lastStep = ContinuousClock.now
			}
		}
		// Review shows the scan's document, so never leave before it's there.
		await withTaskCancellationHandler {
			await work.value
		} onCancel: {
			work.cancel()
		}
		return !Task.isCancelled
	}
}

/// Shared between the rebuild task and the step animation.
@MainActor
private final class RebuildTracker {
	var started = 0
	var latest: RebuildProgress?
	var done = false
}
