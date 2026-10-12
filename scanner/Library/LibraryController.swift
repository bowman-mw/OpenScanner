//
//  LibraryController.swift
//  Rescriva (fork of Open Scanner)
//
//  The sheets and confirmations every library screen shares — move to a
//  folder, tags, new/edit folder, move a folder, smart folders, delete for
//  good, delete a folder, rename a tag — and the actions a gallery's long-
//  press menu and select-mode bar send. Each screen owns one controller and
//  attaches `.libraryPresentations(_:)`.
//

import CoreData
import SwiftUI

/// What a gallery asks for, on one scan (long-press) or several (select mode).
enum GalleryAction {
	case open, pin(Bool), favorite(Bool), move, tags, delete, recover, purge
}

/// A library sheet.
enum LibrarySheet: Identifiable {
	case move([Scan])
	case tags([Scan])
	case newFolder(parent: ScanFolder?)
	case editFolder(ScanFolder)
	case moveFolder(ScanFolder)
	case newSmartFolder
	case editSmartFolder(SmartFolder)

	var id: String {
		switch self {
		case .move(let scans): return "move-\(scans.map { $0.objectID.uriRepresentation().absoluteString }.joined())"
		case .tags(let scans): return "tags-\(scans.map { $0.objectID.uriRepresentation().absoluteString }.joined())"
		case .newFolder(let parent): return "new-\(parent?.objectID.uriRepresentation().absoluteString ?? "top")"
		case .editFolder(let folder): return "edit-\(folder.objectID.uriRepresentation().absoluteString)"
		case .moveFolder(let folder): return "move-folder-\(folder.objectID.uriRepresentation().absoluteString)"
		case .newSmartFolder: return "new-smart"
		case .editSmartFolder(let smart): return "edit-smart-\(smart.objectID.uriRepresentation().absoluteString)"
		}
	}
}

/// One library screen's sheets, confirmations and gallery actions.
@MainActor
@Observable
final class LibraryController {
	var sheet: LibrarySheet?
	/// Scans waiting on "Delete for good?".
	var purgeCandidates: [Scan] = []
	var folderToDelete: ScanFolder?
	/// A scan in Recently Deleted that was tapped: recover it or delete it for good?
	var deletedPrompt: Scan?
	var tagToRename: ScanTag?
	var tagDraft = ""
	/// Called after an action that should end select mode.
	@ObservationIgnored var onFinished: () -> Void = {}

	/// Carries out a gallery action on `scans`.
	func perform(_ action: GalleryAction, on scans: [Scan], context: NSManagedObjectContext, router: RescrivaRouter) {
		guard !scans.isEmpty else { return }
		switch action {
		case .open:
			guard let scan = scans.first else { return }
			if scan.deletedAt != nil { deletedPrompt = scan } else { router.push(.preview(scan)) }
		case .pin(let pinned):
			withAnimation(RescrivaMotion.ui) { Library.setPinned(scans, to: pinned, in: context) }
			onFinished()
		case .favorite(let fave):
			withAnimation(RescrivaMotion.ui) { Library.setFavorite(scans, to: fave, in: context) }
			onFinished()
		case .move:
			sheet = .move(scans)
		case .tags:
			sheet = .tags(scans)
		case .delete:
			delete(scans, context: context, router: router)
		case .recover:
			withAnimation(RescrivaMotion.ui) { Library.recover(scans, in: context) }
			router.showToast(scans.count == 1 ? String(localized: "Recovered") : String(localized: "Recovered \(scans.count) scans"))
			onFinished()
		case .purge:
			purgeCandidates = scans
		}
	}

	/// Moves scans to Recently Deleted, with an Undo on the toast.
	private func delete(_ scans: [Scan], context: NSManagedObjectContext, router: RescrivaRouter) {
		for scan in scans { router.forget(scan) }
		withAnimation(RescrivaMotion.ui) { Library.moveToRecentlyDeleted(scans, in: context) }
		let message = scans.count == 1 ? String(localized: "Moved to Recently Deleted")
			: String(localized: "Moved \(scans.count) scans to Recently Deleted")
		router.showToast(message, actionLabel: String(localized: "Undo")) {
			withAnimation(RescrivaMotion.ui) { Library.recover(scans, in: context) }
		}
		onFinished()
	}

	func confirmPurge(context: NSManagedObjectContext) {
		let scans = purgeCandidates
		purgeCandidates = []
		withAnimation(RescrivaMotion.ui) { Library.purge(scans, in: context) }
		onFinished()
	}

	func confirmFolderDeletion(context: NSManagedObjectContext, router: RescrivaRouter) {
		guard let folder = folderToDelete else { return }
		folderToDelete = nil
		let ids = Set(([folder] + Library.descendants(of: folder)).compactMap(\.id))
		for entry in router.stack {
			if case .collection(.folder(let id)) = entry.route, ids.contains(id) { router.popToRoot() }
		}
		withAnimation(RescrivaMotion.ui) { Library.delete(folder, in: context) }
	}

	func beginRename(_ tag: ScanTag) {
		tagDraft = tag.name ?? ""
		tagToRename = tag
	}

	func finishRename(context: NSManagedObjectContext) {
		guard let tag = tagToRename else { return }
		tagToRename = nil
		Library.rename(tag, to: tagDraft, in: context)
	}
}

extension View {
	/// The sheets and confirmations a `LibraryController` drives.
	func libraryPresentations(_ controller: LibraryController) -> some View {
		modifier(LibraryPresentations(controller: controller))
	}
}

private struct LibraryPresentations: ViewModifier {
	@Bindable var controller: LibraryController
	@Environment(\.managedObjectContext) private var context
	@Environment(RescrivaRouter.self) private var router

	func body(content: Content) -> some View {
		content
			.sheet(item: $controller.sheet) { sheet in
				LibrarySheetView(sheet: sheet) { controller.onFinished() }
			}
			.confirmationDialog(purgeTitle, isPresented: purging, titleVisibility: .visible) {
				Button("Delete for Good", role: .destructive) { controller.confirmPurge(context: context) }
			} message: {
				Text("The pages and their text are removed from this iPhone and your other devices. This can't be undone.")
			}
			.confirmationDialog(controller.deletedPrompt?.displayTitle ?? "", isPresented: prompting, titleVisibility: .visible,
								presenting: controller.deletedPrompt) { scan in
				Button("Recover") { controller.perform(.recover, on: [scan], context: context, router: router) }
				Button("Delete for Good", role: .destructive) { controller.perform(.purge, on: [scan], context: context, router: router) }
			} message: { scan in
				Text(Library.daysLeft(for: scan) == 1 ? "Deleted for good tomorrow." : "Deleted for good in \(Library.daysLeft(for: scan)) days.")
			}
			.confirmationDialog("Delete this folder?", isPresented: deletingFolder, titleVisibility: .visible) {
				Button("Delete Folder", role: .destructive) { controller.confirmFolderDeletion(context: context, router: router) }
			} message: {
				Text("Its scans, and the scans in the folders inside it, move to Recently Deleted.")
			}
			.alert("Rename tag", isPresented: renamingTag) {
				TextField("Tag", text: $controller.tagDraft)
					.textInputAutocapitalization(.never)
				Button("Rename") { controller.finishRename(context: context) }
				Button("Cancel", role: .cancel) {}
			}
	}

	private var purgeTitle: String {
		controller.purgeCandidates.count == 1 ? String(localized: "Delete this scan for good?")
			: String(localized: "Delete \(controller.purgeCandidates.count) scans for good?")
	}

	private var purging: Binding<Bool> {
		Binding(get: { !controller.purgeCandidates.isEmpty }, set: { if !$0 { controller.purgeCandidates = [] } })
	}

	private var prompting: Binding<Bool> {
		Binding(get: { controller.deletedPrompt != nil }, set: { if !$0 { controller.deletedPrompt = nil } })
	}

	private var deletingFolder: Binding<Bool> {
		Binding(get: { controller.folderToDelete != nil }, set: { if !$0 { controller.folderToDelete = nil } })
	}

	private var renamingTag: Binding<Bool> {
		Binding(get: { controller.tagToRename != nil }, set: { if !$0 { controller.tagToRename = nil } })
	}
}
