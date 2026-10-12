//
//  PDFDocumentView.swift
//  Folio (fork of Open Scanner)
//
//  A PDF opened from Files: read it, find in it, fill its form, mark it up and
//  organize its pages, all as a real PDF (nothing is turned into pictures).
//  Changes save to Folio's copy when you leave; the imported original stays
//  as it was. The badges say what the file claims to be (PDF/A, PDF/UA…), and
//  a banner explains anything Folio can't do with it.
//

import PDFKit
import SwiftUI
import UIKit

struct PDFDocumentView: View {
	@Environment(FolioRouter.self) private var router
	@Environment(\.managedObjectContext) private var viewContext
	@Environment(\.scenePhase) private var scenePhase

	private let library = PDFLibrary.shared
	private let itemID: UUID
	private let findQuery: String?

	@State private var session: PDFEditSession?
	/// Opening happens once, in `.task`: a SwiftUI view's init runs on every redraw of its parent.
	@State private var didLoad = false
	@State private var request: PDFViewerRequest?
	/// Spreads pair pages 1–2, 3–4…; a reader can set the first page apart like a book's cover.
	@State private var coverPage = false
	@State private var dismissedBanner = false
	@State private var showsOrganizer = false
	@State private var showsInfo = false
	@State private var showsComparePicker = false
	@State private var textEntry: MarkupTextEntry?
	@State private var confirmingRevert = false
	@State private var isMakingScan = false
	@State private var password = ""
	@State private var passwordFailed = false
	@State private var isFinding = false
	/// Pages sit side by side (a wide window: iPad, the unfolded iPhone Duo).
	@State private var isSpread = false
	/// The screen's width, which decides where the title goes (`titleBesideBack`).
	@State private var screenWidth: CGFloat = 0
	@State private var findText = ""
	@FocusState private var findFocused: Bool

	init(itemID: UUID, findQuery: String? = nil) {
		self.itemID = itemID
		self.findQuery = findQuery
	}

	private var item: PDFItem? { library.item(itemID) }

	/// A wide window (iPad, the unfolded iPhone Duo, a Mac) has room for the title beside the back
	/// button, which keeps the header to one row. Folio runs there as an iPhone app, whose size class
	/// stays compact however wide the window is, so the width decides, as it does for spreads.
	private var titleBesideBack: Bool { screenWidth >= Self.titleBesideBackWidth }

	/// Narrowest screen, in points, that puts the title beside the back button.
	private static let titleBesideBackWidth: CGFloat = 600

	/// "PDF Files" when opened from that list, else the Library's name.
	private var backTitle: LocalizedStringKey {
		router.routeBelow(.pdf(itemID, query: findQuery)) == .pdfFiles ? "PDF Files" : "Folio"
	}

	var body: some View {
		screen
		.task {
			guard !didLoad else { return }
			session = library.item(itemID).flatMap { PDFEditSession.open($0, in: library) }
			didLoad = true
		}
		.fullScreenCover(isPresented: $showsOrganizer) {
			if let session {
				PDFPageOrganizer(session: session) { index in
					request = PDFViewerRequest(page: index)
				} onExtract: { data, count in
					extract(data, pageCount: count)
				}
			}
		}
		.sheet(isPresented: $showsComparePicker) {
			PDFComparePicker(current: .pdf(itemID)) { side in
				showsComparePicker = false
				compare(.pdf(itemID), with: side)
			}
			.presentationDetents([.medium, .large])
		}
		.sheet(isPresented: $showsInfo) {
			if let session, let item {
				PDFInfoSheet(item: item, session: session)
					.presentationDetents([.medium, .large])
			}
		}
		.sheet(item: $textEntry) { entry in
			MarkupTextSheet(entry: entry, isEditable: session?.canMarkUp ?? false) { text in
				finishTextEntry(entry, text: text)
			}
			.presentationDetents([.medium])
		}
		.confirmationDialog("Revert to the original?", isPresented: $confirmingRevert, titleVisibility: .visible) {
			Button("Revert to original", role: .destructive) { revert() }
		} message: {
			Text("Your marks, page changes and form entries in Folio's copy are thrown away.")
		}
		.onChange(of: scenePhase) { _, phase in
			if phase == .background { save() }
		}
		.onDisappear { save() }
	}

	/// The screen itself: header, banner, then the viewer (or the password card).
	private var screen: some View {
		ZStack {
			GrainBackground(base: .scanBackdrop)
			if let session, let item {
				VStack(spacing: 0) {
					topBar(session, item: item)
					if isFinding {
						findBar(session)
							.transition(.floatIn)
					} else if !titleBesideBack {
						titleRow(session, item: item)
					}
					if let banner = banner(session, item: item), !dismissedBanner {
						BannerView(text: banner.text, tone: banner.tone) { withAnimation(FolioMotion.ui) { dismissedBanner = true } }
							.padding(.horizontal, 16)
							.padding(.bottom, 8)
							.transition(.floatIn)
					}
					if session.isLocked {
						passwordCard(session)
						Spacer()
					} else {
						viewer(session)
					}
				}
			} else if didLoad {
				unavailable
			} else {
				ProgressView()
					.tint(.moss)
			}
		}
		.background {
			GeometryReader { proxy in
				Color.clear.onChange(of: proxy.size.width, initial: true) { _, width in screenWidth = width }
			}
		}
	}

	// MARK: Top

	private func topBar(_ session: PDFEditSession, item: PDFItem) -> some View {
		HStack(spacing: 8) {
			if session.mode == .markup {
				CircleIconButton(systemName: "arrow.uturn.backward", label: "Undo") { session.undo() }
					.disabled(!session.canUndo)
					.opacity(session.canUndo ? 1 : 0.4)
				CircleIconButton(systemName: "arrow.uturn.forward", label: "Redo") { session.redo() }
					.disabled(!session.canRedo)
					.opacity(session.canRedo ? 1 : 0.4)
			} else {
				BackPill(title: backTitle) { router.pop() }
			}
			if titleBesideBack {
				// The title takes what the buttons leave, and truncates; the buttons never wrap.
				titleStack(session, item: item, size: 20)
					.padding(.leading, 8)
					.frame(maxWidth: .infinity, alignment: .leading)
					.layoutPriority(-1)
			} else {
				Spacer(minLength: 4)
			}
			if session.mode == .read && !session.isLocked {
				CircleIconButton(systemName: "magnifyingglass", label: "Find in document") { startFind("") }
					.keyboardShortcut("f", modifiers: .command)
				CircleIconButton(systemName: "square.grid.2x2", label: "Pages") { showsOrganizer = true }
				moreMenu(session)
			}
			if session.canMarkUp && !session.isLocked {
				Button {
					endFind()
					withAnimation(FolioMotion.ui) { session.mode = session.mode == .markup ? .read : .markup }
				} label: {
					Text(session.mode == .markup ? "Done" : "Mark up")
						.font(FolioFont.ui(14, weight: .medium))
						.foregroundStyle(session.mode == .markup ? Color.cream : Color.bark)
						.frame(height: 40)
						.padding(.horizontal, 16)
						.background(session.mode == .markup ? Color.moss : Color.cream, in: Capsule())
						.folioShadow(.small)
				}
				.buttonStyle(PressScaleStyle(scale: 0.94))
			}
		}
		.padding(.horizontal, 12)
		.padding(.top, 6)
		.padding(.bottom, 4)
	}

	private func moreMenu(_ session: PDFEditSession) -> some View {
		Menu {
			Button { share(original: false) } label: { Label("Share PDF", systemImage: "square.and.arrow.up") }
			if item?.isEdited == true {
				Button { share(original: true) } label: { Label("Share the original", systemImage: "doc") }
			}
			Button { makeScanCopy() } label: {
				Label(DeviceTier.current.canRebuild ? "Rebuild into Word or Slides" : "Make a scan copy", systemImage: "doc.viewfinder")
			}
			.disabled(isMakingScan)
			Divider()
			Button { showsInfo = true } label: { Label("About this PDF", systemImage: "info.circle") }
			Button { showsComparePicker = true } label: { Label("Compare with another PDF", systemImage: "rectangle.split.2x1") }
			if item?.isEdited == true {
				Button { compare(.pdf(itemID, original: true), with: .pdf(itemID)) } label: {
					Label("Compare with the original", systemImage: "doc.on.doc")
				}
			}
			if isSpread {
				Toggle(isOn: $coverPage) { Label("First page alone in spreads", systemImage: "book") }
			}
			if item?.isEdited == true {
				Divider()
				Button(role: .destructive) { confirmingRevert = true } label: { Label("Revert to original", systemImage: "arrow.counterclockwise") }
			}
		} label: {
			Image(systemName: "ellipsis")
				.font(.system(size: 17, weight: .regular))
				.foregroundStyle(.bark)
				.frame(width: 40, height: 40)
				.background(Color.cream, in: Circle())
				.folioShadow(.small)
		}
		.accessibilityLabel("More")
	}

	/// The title on a row of its own, under the top bar, where the window is narrow.
	private func titleRow(_ session: PDFEditSession, item: PDFItem) -> some View {
		titleStack(session, item: item, size: 22)
			.frame(maxWidth: .infinity, alignment: .leading)
			.padding(.horizontal, 20)
			.padding(.bottom, 10)
	}

	/// The title over its pages, age and format chips.
	private func titleStack(_ session: PDFEditSession, item: PDFItem, size: CGFloat) -> some View {
		VStack(alignment: .leading, spacing: titleBesideBack ? 2 : 6) {
			Text(item.title)
				.font(FolioFont.header(size))
				.foregroundStyle(.bark)
				.lineLimit(1)
				.accessibilityAddTraits(.isHeader)
			ScrollView(.horizontal, showsIndicators: false) {
				HStack(spacing: 6) {
					Text(item.libraryMeta)
						.font(FolioFont.ui(12))
						.foregroundStyle(.slate)
					ForEach(badges(session, item: item), id: \.self) { badge in
						FormatBadge(text: badge)
					}
				}
			}
		}
	}

	/// What the file claims and contains, as short chips.
	private func badges(_ session: PDFEditSession, item: PDFItem) -> [String] {
		let report = session.currentReport
		var badges = report.claims.map(\.label)
		if item.isEdited {
			let kept = Set(report.claims.map(\.standard))
			badges += session.originalReport.strippableClaims.filter { !kept.contains($0.standard) }
				.map { String(localized: "Was \($0.label)") }
		}
		if report.isTagged { badges.append(String(localized: "Tagged")) }
		if let xfa = report.xfa {
			badges.append(xfa == .dynamic ? String(localized: "Dynamic XFA form") : String(localized: "XFA form"))
		} else if report.formFieldCount > 0 {
			badges.append(String(localized: "Form"))
		}
		if report.isEncrypted { badges.append(String(localized: "Password")) }
		if report.hasLayers { badges.append(String(localized: "Layers")) }
		if report.has3D { badges.append(String(localized: "3D")) }
		return badges
	}

	/// The one thing worth saying about this file, if any.
	private func banner(_ session: PDFEditSession, item: PDFItem) -> (text: String, tone: BannerView.Tone)? {
		if let reason = session.readOnlyReason { return (reason, .warning) }
		let original = session.originalReport
		switch original.xfa {
		case .hybrid where !item.isEdited:
			return (String(localized: "This form also carries XFA data. Folio fills its standard fields, and saving keeps a standard fillable PDF without the XFA part."), .info)
		case .staticOnly:
			return (String(localized: "This XFA form shows as a page, but its fields can only be filled in Adobe's apps."), .info)
		default:
			break
		}
		let claims = original.strippableClaims.map(\.label)
		if !claims.isEmpty && !item.isEdited {
			let list = ListFormatter.localizedString(byJoining: claims)
			return (String(localized: "This file says it's \(list). Your changes go to Folio's copy, which won't claim that; the original stays as it was."), .info)
		}
		if original.has3D {
			return (String(localized: "This PDF has 3D content Folio can't show. You'll see its still image, if it has one."), .info)
		}
		return nil
	}

	// MARK: Viewer

	private func viewer(_ session: PDFEditSession) -> some View {
		GeometryReader { proxy in
			let spread = proxy.size.width >= 700 && proxy.size.width >= proxy.size.height * 1.2
			ZStack(alignment: .bottom) {
				PDFKitView(session: session, spread: spread, coverPage: coverPage, request: request) { tool, point, page in
					textEntry = MarkupTextEntry(kind: tool == .note ? .newNote : .newTextBox, point: point, page: page, annotation: nil, text: "")
				} onOpenAnnotation: { annotation in
					textEntry = MarkupTextEntry(kind: annotation.type == "Text" ? .note : .textBox, point: .zero, page: annotation.page,
												annotation: annotation, text: annotation.contents ?? "")
				}
				.ignoresSafeArea(edges: session.mode == .markup ? [] : .bottom)
				.onChange(of: spread, initial: true) { _, wide in isSpread = wide }

				if session.mode == .markup {
					MarkupToolbar(session: session)
						.transition(.move(edge: .bottom).combined(with: .opacity))
				} else {
					PageIndicator(current: min(session.currentPageIndex + 1, session.pageCount), total: session.pageCount)
						.padding(.bottom, 14)
				}
			}
		}
		.task {
			if let findQuery, !findQuery.isEmpty, !session.isLocked { startFind(findQuery) }
		}
	}

	// MARK: Find

	private func findBar(_ session: PDFEditSession) -> some View {
		HStack(spacing: 8) {
			HStack(spacing: 8) {
				Image(systemName: "magnifyingglass")
					.font(.system(size: 15))
					.foregroundStyle(.slate)
				TextField("Find in this PDF", text: $findText)
					.font(FolioFont.ui(15))
					.foregroundStyle(.bark)
					.submitLabel(.search)
					.autocorrectionDisabled()
					.textInputAutocapitalization(.never)
					.focused($findFocused)
					.onSubmit { session.showNextResult() }
				Text(findStatus(session))
					.font(FolioFont.ui(12, weight: .medium))
					.foregroundStyle(.slate)
					.monospacedDigit()
					.fixedSize()
			}
			.padding(.horizontal, 12)
			.frame(height: 40)
			.background(Color.cream, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
			.overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.bark.opacity(0.08)) }
			findStep("chevron.up", label: "Previous match") { session.showPreviousResult() }
			findStep("chevron.down", label: "Next match") { session.showNextResult() }
			Button("Done") { endFind() }
				.font(FolioFont.ui(14, weight: .medium))
				.foregroundStyle(.moss)
		}
		.padding(.horizontal, 16)
		.padding(.bottom, 10)
		.task(id: findText) {
			// Search as you type, once typing pauses (a new keystroke cancels the wait).
			do {
				try await Task.sleep(for: .milliseconds(250))
			} catch {
				return
			}
			session.find(findText)
		}
	}

	private func findStep(_ systemName: String, label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
		let enabled = !(session?.findResults.isEmpty ?? true)
		return Button(action: action) {
			Image(systemName: systemName)
				.font(.system(size: 15, weight: .medium))
				.foregroundStyle(.bark)
				.frame(width: 34, height: 40)
				.contentShape(Rectangle())
		}
		.buttonStyle(PressScaleStyle())
		.disabled(!enabled)
		.opacity(enabled ? 1 : 0.35)
		.accessibilityLabel(Text(label))
	}

	/// "3 of 12", "Searching…", "No matches".
	private func findStatus(_ session: PDFEditSession) -> String {
		let count = session.findResults.count
		if findText.trimmingCharacters(in: .whitespaces).isEmpty { return "" }
		if count == 0 { return session.isFinding ? String(localized: "Searching…") : String(localized: "No matches") }
		let position = (session.findIndex ?? 0) + 1
		return session.isFinding ? String(localized: "\(position) of \(count)+") : String(localized: "\(position) of \(count)")
	}

	private func startFind(_ query: String) {
		findText = query
		withAnimation(FolioMotion.ui) { isFinding = true }
		findFocused = query.isEmpty
	}

	private func endFind() {
		session?.endFind()
		findFocused = false
		withAnimation(FolioMotion.ui) { isFinding = false }
	}

	private func passwordCard(_ session: PDFEditSession) -> some View {
		VStack(alignment: .leading, spacing: 12) {
			Text("This PDF is locked")
				.font(FolioFont.header(20))
				.foregroundStyle(.bark)
			Text("Enter its password to open it. Folio keeps the password on the file when it saves.")
				.font(FolioFont.ui(14))
				.foregroundStyle(.slate)
			SecureField("Password", text: $password)
				.font(FolioFont.ui(16))
				.textContentType(.password)
				.submitLabel(.go)
				.padding(.horizontal, 14)
				.frame(height: 44)
				.background(Color.paper, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
				.onSubmit { unlock(session) }
			if passwordFailed {
				Text("That password didn't work.")
					.font(FolioFont.ui(13))
					.foregroundStyle(.terracotta)
			}
			PrimaryButton(title: "Unlock", systemImage: "lock.open", height: 48) { unlock(session) }
		}
		.folioCard(padding: 18)
		.padding(.horizontal, 20)
		.padding(.top, 20)
	}

	private var unavailable: some View {
		VStack(spacing: 16) {
			HStack {
				BackPill(title: backTitle) { router.pop() }
				Spacer()
			}
			.padding(.horizontal, 12)
			.padding(.top, 6)
			Spacer()
			Text("This PDF couldn't be opened. It may be damaged, or it was removed.")
				.font(FolioFont.bubble(16))
				.foregroundStyle(.slate)
				.multilineTextAlignment(.center)
				.padding(.horizontal, 40)
			Spacer()
		}
	}

	// MARK: Actions

	private func unlock(_ session: PDFEditSession) {
		if session.unlock(with: password) {
			passwordFailed = false
			password = ""
		} else {
			passwordFailed = true
		}
	}

	private func save() {
		guard let session, session.needsSave else { return }
		do {
			try session.save(in: library)
		} catch {
			router.showToast(error.localizedDescription)
		}
	}

	/// Saves this PDF's changes, so the comparison sees them, then shows the two side by side.
	private func compare(_ left: PDFCompareSide, with right: PDFCompareSide) {
		endFind()
		save()
		router.push(.pdfCompare(left, right))
	}

	private func finishTextEntry(_ entry: MarkupTextEntry, text: String) {
		guard let session else { return }
		if let annotation = entry.annotation {
			session.setContents(of: annotation, to: text)
			return
		}
		let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty, let page = entry.page else { return }
		let color = session.currentColor
		switch entry.kind {
		case .newNote:
			session.add([PDFMarkupFactory.note(at: entry.point, text: trimmed, color: color)], on: page)
		case .newTextBox:
			session.add([PDFMarkupFactory.textBox(at: entry.point, text: trimmed, color: color, fontSize: session.currentSize,
												  pageBounds: page.bounds(for: .cropBox))], on: page)
		case .note, .textBox:
			break
		}
	}

	private func share(original: Bool) {
		save()
		guard let item else { return }
		let source = original ? library.originalURL(for: item) : library.currentURL(for: item)
		let name = (item.title.isEmpty ? "Document" : item.title) + (original ? String(localized: " (original)") : "") + ".pdf"
		let destination = FileManager.default.temporaryDirectory.appendingPathComponent(name.replacingOccurrences(of: "/", with: "-"))
		do {
			if FileManager.default.fileExists(atPath: destination.path) {
				try FileManager.default.removeItem(at: destination)
			}
			try FileManager.default.copyItem(at: source, to: destination)
			SharePresenter.share([destination])
		} catch {
			router.showToast(String(localized: "Folio couldn't prepare the PDF to share."))
		}
	}

	private func revert() {
		guard let item else { return }
		do {
			try library.revertToOriginal(item)
			session = library.item(item.id).flatMap { PDFEditSession.open($0, in: library) }
			dismissedBanner = false
			router.showToast(String(localized: "Back to the original"))
		} catch {
			router.showToast(error.localizedDescription)
		}
	}

	private func extract(_ data: Data, pageCount: Int) {
		guard let item else { return }
		do {
			let extracted = try library.add(data, title: String(localized: "\(item.title) (pages)"))
			let message = pageCount == 1 ? String(localized: "Saved 1 page as a new PDF") : String(localized: "Saved \(pageCount) pages as a new PDF")
			router.showToast(message, actionLabel: String(localized: "Open")) {
				router.push(.pdf(extracted.id, query: nil))
			}
		} catch {
			router.showToast(error.localizedDescription)
		}
	}

	private func makeScanCopy() {
		guard let item, !isMakingScan else { return }
		save()
		isMakingScan = true
		router.showToast(String(localized: "Making a scan copy…"))
		let source = library.currentURL(for: item)
		let password = session?.unlockPassword
		Task {
			// The same path as PR #1's import: pages drawn one at a time, the PDF kept as the scan's original.
			let images = await PDFImport.pages(of: source, password: password) { _, _ in }
			let staged = images.isEmpty ? nil : await PDFImport.stageOriginal(source)
			isMakingScan = false
			guard !images.isEmpty else {
				router.showToast(String(localized: "Folio couldn't make a scan copy of this PDF."))
				return
			}
			let output: OutputKind = DeviceTier.current.canRebuild ? .docx : .pdf
			let scan = Scan.create(from: images, title: item.title, source: .typed, in: viewContext, output: output, suggestsTitle: false)
			if let staged, let id = scan.id {
				PDFImport.keepOriginal(staged, named: item.sourceName, for: id)
			}
			router.push(.scan(scan))
		}
	}
}

// MARK: - Pieces

/// A note or text box being written or edited.
struct MarkupTextEntry: Identifiable {
	enum Kind { case newNote, newTextBox, note, textBox }

	let id = UUID()
	let kind: Kind
	/// Where a new one goes, in page space.
	let point: CGPoint
	let page: PDFPage?
	/// The existing one being edited.
	let annotation: PDFAnnotation?
	let text: String

	var title: LocalizedStringKey {
		switch kind {
		case .newNote: return "New note"
		case .newTextBox: return "New text box"
		case .note: return "Note"
		case .textBox: return "Text box"
		}
	}
}

/// Writes or edits a note's or text box's text.
private struct MarkupTextSheet: View {
	@Environment(\.dismiss) private var dismiss
	let entry: MarkupTextEntry
	let isEditable: Bool
	let onDone: (String) -> Void
	@State private var text: String
	@FocusState private var focused: Bool

	init(entry: MarkupTextEntry, isEditable: Bool, onDone: @escaping (String) -> Void) {
		self.entry = entry
		self.isEditable = isEditable
		self.onDone = onDone
		_text = State(initialValue: entry.text)
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 14) {
			HStack {
				Text(entry.title)
					.font(FolioFont.header(22))
					.foregroundStyle(.bark)
				Spacer()
				Button(isEditable ? "Done" : "Close") {
					if isEditable { onDone(text) }
					dismiss()
				}
				.font(FolioFont.ui(15, weight: .medium))
				.foregroundStyle(.moss)
			}
			if isEditable {
				TextEditor(text: $text)
					.font(FolioFont.ui(16))
					.scrollContentBackground(.hidden)
					.padding(10)
					.background(Color.paper, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
					.focused($focused)
				if entry.annotation != nil {
					Text("Clear the text to delete it.")
						.font(FolioFont.ui(12))
						.foregroundStyle(.slate)
				}
			} else {
				ScrollView {
					Text(text)
						.font(FolioFont.ui(16))
						.foregroundStyle(.bark)
						.frame(maxWidth: .infinity, alignment: .leading)
						.textSelection(.enabled)
				}
			}
		}
		.padding(20)
		.background(Color.parchment)
		.onAppear { focused = isEditable }
	}
}

/// The markup bar: tools, then the chosen tool's colors and sizes.
private struct MarkupToolbar: View {
	@Bindable var session: PDFEditSession

	var body: some View {
		FrostedBottomBar {
			ScrollView(.horizontal, showsIndicators: false) {
				HStack(spacing: 4) {
					ForEach(PDFMarkupTool.allCases) { tool in
						MarkupToolButton(tool: tool, isSelected: session.tool == tool) {
							withAnimation(FolioMotion.fast) { session.tool = tool }
						}
					}
				}
			}
			optionsRow
		}
	}

	@ViewBuilder
	private var optionsRow: some View {
		if let group = session.currentStyleGroup, let style = session.currentStyle {
			HStack(spacing: 0) {
				ForEach(Array(group.swatches.enumerated()), id: \.element.id) { index, swatch in
					MarkupSwatchButton(swatch: swatch, isSelected: style.colorIndex == index) { session.selectColor(index) }
						.frame(maxWidth: .infinity)
				}
				if session.tool != .note {
					Rectangle()
						.fill(Color.bark.opacity(0.14))
						.frame(width: 1, height: 24)
						.padding(.horizontal, 6)
						.accessibilityHidden(true)
					ForEach(Array(MarkPalette.sizeNames.enumerated()), id: \.offset) { index, name in
						MarkupSizeButton(index: index, name: name, color: session.currentColor, isSelected: style.sizeIndex == index) {
							session.selectSize(index)
						}
					}
				}
			}
			.frame(height: 36)
		}
		Text(session.tool.hint)
			.font(FolioFont.bubble(14))
			.foregroundStyle(.slate)
			.frame(maxWidth: .infinity, alignment: .leading)
	}
}

private struct MarkupToolButton: View {
	let tool: PDFMarkupTool
	let isSelected: Bool
	let action: () -> Void

	var body: some View {
		Button(action: action) {
			Image(systemName: tool.systemImage)
				.font(.system(size: 18, weight: .regular))
				.foregroundStyle(isSelected ? Color.cream : Color.bark)
				.frame(width: 42, height: 42)
				.background {
					if isSelected { Circle().fill(Color.bark) }
				}
				.contentShape(Circle())
		}
		.buttonStyle(PressScaleStyle())
		.accessibilityLabel(Text(tool.label))
		.accessibilityAddTraits(isSelected ? .isSelected : [])
	}
}

private struct MarkupSwatchButton: View {
	let swatch: MarkSwatch
	let isSelected: Bool
	let action: () -> Void

	var body: some View {
		Button(action: action) {
			Circle()
				.fill(Color(uiColor: swatch.uiColor))
				.overlay(Circle().strokeBorder(Color.bark.opacity(0.18), lineWidth: 1))
				.frame(width: 24, height: 24)
				.padding(4)
				.overlay {
					if isSelected { Circle().strokeBorder(Color.bark, lineWidth: 2) }
				}
				.frame(width: 36, height: 36)
				.contentShape(Circle())
		}
		.buttonStyle(PressScaleStyle())
		.accessibilityLabel(Text(swatch.name))
		.accessibilityAddTraits(isSelected ? .isSelected : [])
	}
}

private struct MarkupSizeButton: View {
	let index: Int
	let name: LocalizedStringKey
	let color: UIColor
	let isSelected: Bool
	let action: () -> Void

	var body: some View {
		Button(action: action) {
			Circle()
				.fill(Color(uiColor: color))
				.overlay(Circle().strokeBorder(Color.bark.opacity(0.18), lineWidth: 1))
				.frame(width: CGFloat(6 + index * 5), height: CGFloat(6 + index * 5))
				.frame(width: 34, height: 34)
				.background {
					if isSelected { Circle().fill(Color.bark.opacity(0.1)) }
				}
				.contentShape(Circle())
		}
		.buttonStyle(PressScaleStyle())
		.accessibilityLabel(Text(name))
		.accessibilityAddTraits(isSelected ? .isSelected : [])
	}
}

/// "3 of 12" over the page.
private struct PageIndicator: View {
	let current: Int
	let total: Int

	var body: some View {
		Text("\(current) of \(total)")
			.font(FolioFont.ui(13, weight: .medium))
			.foregroundStyle(.bark)
			.monospacedDigit()
			.padding(.vertical, 7)
			.padding(.horizontal, 14)
			.background(Color.cream.opacity(0.94), in: Capsule())
			.folioShadow(.small)
			.accessibilityLabel(Text("Page \(current) of \(total)"))
	}
}

/// A short chip naming a standard or feature: "PDF/A-2b", "Tagged".
struct FormatBadge: View {
	let text: String

	var body: some View {
		Text(text)
			.font(FolioFont.ui(11, weight: .medium))
			.foregroundStyle(.bark)
			.padding(.vertical, 4)
			.padding(.horizontal, 9)
			.background(Color.lichen.opacity(0.7), in: RoundedRectangle(cornerRadius: FolioRadius.small, style: .continuous))
	}
}

/// One line of explanation above the page, dismissible.
struct BannerView: View {
	enum Tone { case info, warning }

	let text: String
	let tone: Tone
	let onDismiss: () -> Void

	var body: some View {
		HStack(alignment: .top, spacing: 10) {
			Image(systemName: tone == .warning ? "exclamationmark.triangle" : "info.circle")
				.font(.system(size: 15, weight: .medium))
				.foregroundStyle(tone == .warning ? Color.terracotta : Color.moss)
				.padding(.top, 1)
			Text(text)
				.font(FolioFont.ui(13))
				.foregroundStyle(.bark)
				.frame(maxWidth: .infinity, alignment: .leading)
				.fixedSize(horizontal: false, vertical: true)
			Button(action: onDismiss) {
				Image(systemName: "xmark")
					.font(.system(size: 12, weight: .semibold))
					.foregroundStyle(.slate)
					.frame(width: 24, height: 24)
			}
			.accessibilityLabel("Dismiss")
		}
		.padding(12)
		.background(Color.cream, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
		.folioShadow(.small)
	}
}
