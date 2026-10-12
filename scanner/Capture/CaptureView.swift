//
//  CaptureView.swift
//  Rescriva (fork of Open Scanner)
//
//  The Capture screen: a calm dark surround, the live camera with the page
//  outlined in fern, auto-capture once the page is steady, document or
//  whiteboard mode, and a stack of captured pages to Save. Replaces Open
//  Scanner's VisionKit document camera (PageScan) with Rescriva's own camera.
//

import CoreImage
import SwiftUI
import UIKit

struct CaptureView: View {
	let appendingTo: Scan?

	@Environment(\.managedObjectContext) private var viewContext
	@Environment(RescrivaRouter.self) private var router
	@Environment(\.openURL) private var openURL

	@State private var camera = CaptureCamera()
	@State private var mode: CaptureKind
	@State private var auto: Bool
	@State private var captured: [CapturedPage] = []
	@State private var flash = false
	@State private var isCapturing = false
	/// Set once Save hands the pages (and their staged originals) to a scan.
	@State private var handedOff = false

	init(kind: CaptureKind, appendingTo: Scan?) {
		self.appendingTo = appendingTo
		_mode = State(initialValue: kind)
		_auto = State(initialValue: UserDefaults.standard.bool(forKey: RescrivaPreference.autoCapture))
	}

	/// No camera here (the Simulator): show the illustrated viewfinder and
	/// capture sample pages so the flow can still be tried.
	private var isDemo: Bool {
		#if targetEnvironment(simulator)
		return true
		#else
		return false
		#endif
	}

	var body: some View {
		ZStack {
			Color.midnight.ignoresSafeArea()
			VStack(spacing: 0) {
				topBar
				viewfinder
				modeChips
				bottomControls
			}
		}
		.task { await startCamera() }
		.onDisappear {
			camera.stop()
			discardUnsaved()
		}
		.onChange(of: mode) { _, newMode in camera.mode = newMode.cameraMode }
		.onChange(of: auto) { _, isOn in
			camera.autoCapture = isOn
			if isOn { scheduleDemoAutoCapture() }
		}
	}

	// MARK: Pieces

	private var topBar: some View {
		HStack {
			Button("Cancel") { router.pop() }
				.font(RescrivaFont.ui(14, weight: .medium))
				.foregroundStyle(.cream)
				.frame(height: 36)
				.padding(.horizontal, 16)
				.background(Color.cream.opacity(0.12), in: Capsule())
			Spacer()
			Button {
				withAnimation(RescrivaMotion.ui) { auto.toggle() }
			} label: {
				HStack(spacing: 6) {
					Image(systemName: "bolt.fill")
						.font(.system(size: 12))
					Text(auto ? "Auto" : "Manual")
						.font(RescrivaFont.ui(13, weight: .medium))
				}
				.foregroundStyle(auto ? Color.bark : Color.cream)
				.frame(height: 36)
				.padding(.horizontal, 14)
				.background(auto ? Color.goldenrod : Color.cream.opacity(0.12), in: Capsule())
			}
			.accessibilityLabel(auto ? "Auto-capture on" : "Auto-capture off")
		}
		.padding(.horizontal, 20)
		.padding(.top, 12)
		.padding(.bottom, 12)
	}

	private var viewfinder: some View {
		ZStack(alignment: .bottom) {
			Color(hex: 0x2A2F3C)
			if isDemo {
				DemoViewfinder(whiteboard: mode == .whiteboard)
			} else {
				switch camera.status {
				case .denied:
					cameraMessage(String(localized: "Rescriva needs the camera to scan. You can allow it in Settings."), showsSettings: true)
				case .unavailable:
					cameraMessage(String(localized: "This device has no camera Rescriva can use. Import photos or a PDF instead."), showsSettings: false)
				case .failed(let reason):
					cameraMessage(reason, showsSettings: false)
				default:
					CameraPreviewView(session: camera.session, quad: camera.quad, isSteady: camera.isSteady)
				}
			}
			Text(hint)
				.font(RescrivaFont.bubble(15))
				.foregroundStyle(.cream)
				.padding(.vertical, 8)
				.padding(.horizontal, 14)
				.background(.ultraThinMaterial.opacity(0.6), in: Capsule())
				.background(Color.midnight.opacity(0.6), in: Capsule())
				.padding(.bottom, 18)
				.animation(RescrivaMotion.ui, value: hint)
				.accessibilityAddTraits(.updatesFrequently)
			Color.cream
				.opacity(flash ? 0.85 : 0)
				.allowsHitTesting(false)
				.animation(.easeOut(duration: 0.28), value: flash)
		}
		.clipShape(RoundedRectangle(cornerRadius: RescrivaRadius.large, style: .continuous))
		.padding(.horizontal, 14)
	}

	private func cameraMessage(_ text: String, showsSettings: Bool) -> some View {
		VStack(spacing: 14) {
			Text(text)
				.font(RescrivaFont.bubble(16))
				.foregroundStyle(.cream)
				.multilineTextAlignment(.center)
			if showsSettings, let url = URL(string: UIApplication.openSettingsURLString) {
				Button("Open Settings") { openURL(url) }
					.font(RescrivaFont.ui(14, weight: .medium))
					.foregroundStyle(.bark)
					.padding(.vertical, 10)
					.padding(.horizontal, 18)
					.background(Color.cream, in: Capsule())
			}
		}
		.padding(32)
		.frame(maxWidth: .infinity, maxHeight: .infinity)
	}

	private var modeChips: some View {
		HStack(spacing: 6) {
			ForEach([CaptureKind.document, .whiteboard], id: \.self) { option in
				Button {
					withAnimation(RescrivaMotion.ui) { mode = option }
				} label: {
					Text(option == .document ? "Document" : "Whiteboard")
						.font(RescrivaFont.ui(13, weight: .medium))
						.foregroundStyle(mode == option ? Color.bark : Color.cream)
						.padding(.vertical, 7)
						.padding(.horizontal, 14)
						.background(mode == option ? Color.cream : Color.cream.opacity(0.10), in: Capsule())
				}
				.accessibilityAddTraits(mode == option ? .isSelected : [])
			}
		}
		.padding(.top, 16)
		.padding(.bottom, 4)
	}

	private var bottomControls: some View {
		HStack {
			capturedStack
				.frame(width: 64, height: 64)
			Spacer()
			Button(action: { Task { await capture() } }) {
				ZStack {
					Circle().strokeBorder(Color.cream, lineWidth: 4)
					Circle().fill(Color.cream).padding(8)
				}
				.frame(width: 78, height: 78)
			}
			.buttonStyle(PressScaleStyle())
			.disabled(isCapturing || !canCapture)
			.accessibilityLabel("Take picture")
			Spacer()
			Button(action: save) {
				Text("Save")
					.font(RescrivaFont.ui(14, weight: .medium))
					.foregroundStyle(captured.isEmpty ? Color.cream.opacity(0.4) : Color.bark)
					.frame(width: 64, height: 40)
					.background(captured.isEmpty ? Color.cream.opacity(0.12) : Color.cream, in: Capsule())
					.animation(RescrivaMotion.ui, value: captured.isEmpty)
			}
			.disabled(captured.isEmpty)
			.accessibilityLabel(captured.isEmpty ? "Save" : "Save \(captured.count) pages")
		}
		.padding(.horizontal, 28)
		.padding(.top, 14)
		.padding(.bottom, 12)
	}

	@ViewBuilder
	private var capturedStack: some View {
		if let last = captured.last {
			ZStack(alignment: .topTrailing) {
				ZStack {
					RoundedRectangle(cornerRadius: 4)
						.fill(Color.paper.opacity(0.7))
						.padding(EdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 10))
						.rotationEffect(.degrees(-6))
					Image(uiImage: last.image)
						.resizable()
						.scaledToFill()
						.frame(width: 48, height: 52)
						.clipShape(RoundedRectangle(cornerRadius: 4))
						.shadow(color: .black.opacity(0.3), radius: 3, x: 0, y: 2)
						.rotationEffect(.degrees(3))
				}
				Text("\(captured.count)")
					.font(RescrivaFont.ui(12, weight: .medium))
					.foregroundStyle(.bark)
					.frame(minWidth: 22, minHeight: 22)
					.background(Color.goldenrod, in: Capsule())
					.offset(x: 4, y: -4)
			}
			.transition(.floatIn)
			.accessibilityElement(children: .ignore)
			.accessibilityLabel("\(captured.count) pages captured")
		}
	}

	private var hint: String {
		if captured.isEmpty {
			if !isDemo, camera.status == .running, camera.quad == nil {
				return String(localized: "Looking for the page…")
			}
			return auto ? String(localized: "Hold still — I’ll take it when it’s steady") : String(localized: "Tap the shutter when ready")
		}
		return String(localized: "Got page \(captured.count). Next one whenever you are.")
	}

	private var canCapture: Bool {
		isDemo || camera.status == .running
	}

	// MARK: Camera

	private func startCamera() async {
		camera.mode = mode.cameraMode
		camera.autoCapture = auto
		camera.removeShadows = UserDefaults.standard.bool(forKey: RescrivaPreference.removeShadows)
		camera.keepMarkerColors = UserDefaults.standard.bool(forKey: RescrivaPreference.keepMarkerColors)
		camera.keepsOriginal = UserDefaults.standard.bool(forKey: RescrivaPreference.keepOriginals)
		camera.onAutoCapture = {
			Task { await capture() }
		}
		if isDemo {
			scheduleDemoAutoCapture()
		} else {
			await camera.start()
		}
	}

	/// Mirrors auto-capture in the Simulator: the first page "steadies" after a moment.
	private func scheduleDemoAutoCapture() {
		guard isDemo, auto, captured.isEmpty else { return }
		Task {
			do {
				try await Task.sleep(for: .milliseconds(1600))
			} catch {
				return
			}
			if auto, captured.isEmpty, router.isCameraVisible {
				await capture()
			}
		}
	}

	private func capture() async {
		guard !isCapturing else { return }
		isCapturing = true
		defer { isCapturing = false }
		flash = true
		UIImpactFeedbackGenerator(style: .soft).impactOccurred()
		Task {
			do {
				try await Task.sleep(for: .milliseconds(160))
			} catch {
				// Cancelled: clear the flash anyway.
			}
			flash = false
		}
		if isDemo {
			let page = await Self.demoPage(SampleLibrary.demoCapture(whiteboard: mode == .whiteboard, index: captured.count))
			// The screen may have closed while the page was made; then nobody will save it.
			guard router.isCameraVisible, !handedOff else {
				OriginalStore.shared.discardLater([page.original].compactMap { $0 })
				return
			}
			withAnimation(RescrivaMotion.ui) { captured.append(page) }
			return
		}
		do {
			let page = try await camera.capturePage()
			withAnimation(RescrivaMotion.ui) { captured.append(page) }
		} catch is CancellationError {
			// The camera stopped while the shot was processed: the screen is closing.
		} catch {
			router.showToast(String(localized: "That shot didn’t take — try again."))
		}
	}

	/// A Simulator page: the sample image is its own original (whole frame, no cleanup), so
	/// "Adjust page" can be tried without a camera.
	private static func demoPage(_ image: UIImage) async -> CapturedPage {
		guard UserDefaults.standard.bool(forKey: RescrivaPreference.keepOriginals), let cgImage = image.cgImage else {
			return CapturedPage(image: image)
		}
		let original = await Task.detached(priority: .userInitiated) {
			OriginalStore.shared.stage(CIImage(cgImage: cgImage))
		}.value
		let recipe = PageRecipe(quad: .fullFrame, mode: nil, rotation: 0, removeShadows: true, keepMarkerColors: true)
		return CapturedPage(image: image, original: original, recipe: recipe)
	}

	private func save() {
		guard !captured.isEmpty else { return }
		camera.stop()
		// The scan moves each page's staged original into place from here on.
		handedOff = true
		if let scan = appendingTo {
			scan.append(captured, in: viewContext)
			router.pop()
		} else {
			let scan = Scan.create(from: captured, title: RescrivaDates.defaultTitle(for: mode),
								   source: mode == .whiteboard ? .whiteboard : nil, in: viewContext)
			router.replaceTop(with: .scan(scan))
		}
	}

	/// Deletes the staged originals of pages that were never saved (Cancel, or the screen closed
	/// some other way), off the main thread. Leftovers a crash strands go at the next launch.
	private func discardUnsaved() {
		guard !handedOff else { return }
		OriginalStore.shared.discardLater(captured.compactMap(\.original))
	}
}

extension CaptureKind {
	var cameraMode: CaptureCamera.Mode {
		switch self {
		case .document: return .document
		case .whiteboard: return .whiteboard
		}
	}
}

/// The design's illustrated viewfinder: a page in perspective with the fern
/// detection outline. Shown where there's no camera.
private struct DemoViewfinder: View {
	let whiteboard: Bool

	var body: some View {
		ZStack {
			if whiteboard {
				Color(hex: 0x8E9AA6)
			} else {
				RadialGradient(colors: [Color(hex: 0x5B4A3A), Color(hex: 0x3A2E24)], center: UnitPoint(x: 0.4, y: 0.3), startRadius: 10, endRadius: 420)
			}
			page
				.frame(width: whiteboard ? 300 : 220, height: whiteboard ? 210 : 300)
				.rotation3DEffect(.degrees(12), axis: (x: 1, y: 0, z: 0), perspective: 0.6)
				.rotationEffect(.degrees(-4))
		}
		.accessibilityHidden(true)
	}

	private var page: some View {
		ZStack {
			RoundedRectangle(cornerRadius: 3)
				.fill(whiteboard ? Color(hex: 0xF4F6F6) : Color.paper)
				.shadow(color: .black.opacity(0.4), radius: 20, x: 0, y: 20)
			VStack(alignment: .leading, spacing: 9) {
				Capsule().fill(Color.bark.opacity(0.55)).frame(width: 110, height: 9)
				ForEach([0.92, 0.84, 0.88], id: \.self) { fraction in
					Capsule().fill(Color.bark.opacity(0.22)).frame(width: 180 * fraction, height: 4)
				}
				HStack(spacing: 12) {
					RoundedRectangle(cornerRadius: 6).strokeBorder(whiteboard ? Color.moss : Color.bark.opacity(0.35), lineWidth: 2).frame(width: 70, height: 36)
					RoundedRectangle(cornerRadius: 18).strokeBorder(whiteboard ? Color.terracotta : Color.bark.opacity(0.35), lineWidth: 2).frame(width: 70, height: 36)
				}
				.padding(.top, 10)
				Capsule().fill(Color.bark.opacity(0.22)).frame(width: 126, height: 4).padding(.top, 8)
				Capsule().fill(Color.bark.opacity(0.22)).frame(width: 144, height: 4)
			}
			.padding(.vertical, 22)
			.padding(.horizontal, 20)
			.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
			RoundedRectangle(cornerRadius: 4)
				.fill(Color.fern.opacity(0.10))
				.overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(Color.fern, lineWidth: 2.5) }
				.padding(-4)
			GeometryReader { proxy in
				ForEach(0..<4, id: \.self) { corner in
					Circle()
						.fill(Color.cream)
						.overlay { Circle().strokeBorder(Color.fern, lineWidth: 2.5) }
						.frame(width: 14, height: 14)
						.position(x: corner % 2 == 0 ? -2 : proxy.size.width + 2, y: corner < 2 ? -2 : proxy.size.height + 2)
				}
			}
		}
	}
}
