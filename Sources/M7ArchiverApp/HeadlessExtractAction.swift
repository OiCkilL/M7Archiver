import Foundation
import AppKit
import ArchiveCore

/// Headless (no-window) extract runtime for Finder-initiated "Extract Here"
/// and "Extract to Folder" actions. Builds a free-standing `ArchiveSession`,
/// drives extraction to completion, and reports the outcome through the Dock
/// icon. Mirrors `AutoExtract.run` (destination resolution + security scope
/// + outcome reporting) and `QuickCompressAction.run` (free-standing session
/// + Dock observe + `hasWindow: false` reporting).
@MainActor
enum HeadlessExtractAction {
    static func run(
        archiveURL: URL,
        finderTarget: URL?,
        extractToSubfolder: Bool,
        settings: ArchiveSettings,
        savedPasswords: SavedPasswordsStore
    ) async {
        guard let resolution = AutoExtractDestinationResolver.resolve(
            archiveURL: archiveURL,
            finderTarget: finderTarget,
            strategy: settings.autoExtractDestination.strategy,
            bookmark: settings.autoExtractDestination.customFolderBookmark
        ) else { return }

        let scoped = resolution.requiresSecurityScope
            && resolution.folderURL.startAccessingSecurityScopedResource()
        defer {
            if scoped {
                resolution.folderURL.stopAccessingSecurityScopedResource()
            }
        }

        let destination: URL
        if extractToSubfolder {
            let stem = AutoExtractDestinationResolver.archiveStem(for: archiveURL)
            destination = resolution.folderURL.appendingPathComponent(stem, isDirectory: true)
        } else {
            destination = resolution.folderURL
        }

        // Build a free-standing session mirroring the main window's session
        // configuration (`ArchiveWindowModel.init`).
        let session = ArchiveSession(defaultEncoding: settings.defaultEncoding)
        session.applyAutomaticEncodingPriority(settings.automaticEncodingPriority)

        await session.open(url: archiveURL)
        if case .locked = session.lockState,
           let saved = savedPasswords.lookup(for: archiveURL) {
            await session.unlock(password: saved)
            if session.lockState == .locked(reason: .wrongPassword) {
                savedPasswords.delete(for: archiveURL)
            }
        }
        if session.isLocked {
            DockProgressController.shared.report(
                .failure,
                title: "Extraction Failed",
                body: "\(archiveURL.lastPathComponent) needs a password. Open it in M7Archiver to unlock.",
                hasWindow: false
            )
            return
        }

        // extractHere → silent rename ("name 2.ext"); extractToFolder → ask
        // once and apply the answer to every conflict (Archive Utility style).
        let strategy: ArchiveExtractionConflictStrategy = extractToSubfolder ? .ask : .rename
        let decisionBox = ExtractionConflictDecisionBox()
        let onConflict: (@Sendable (ArchiveExtractionConflict) async -> ArchiveExtractionConflictDecision)?
        if extractToSubfolder {
            onConflict = { conflict in await decisionBox.resolve(conflict) }
        } else {
            onConflict = nil
        }

        let dockToken = DockProgressController.shared.observe { [session] in
            session.progress?.fraction
        }
        let outcome = await session.extract(
            to: destination,
            conflictStrategy: strategy,
            onConflict: onConflict
        )
        // `dockToken` is held for the duration of the operation; `report`
        // below clears the source, and the token's deinit is a no-op then.
        _ = dockToken

        switch outcome {
        case .completed:
            if settings.revealInFinderAfterExtract {
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            }
            DockProgressController.shared.report(
                .success,
                title: "Extraction Finished",
                body: destination.lastPathComponent,
                hasWindow: false
            )
        case .cancelled:
            DockProgressController.shared.report(
                .cancelled,
                title: "Extraction Cancelled",
                body: destination.lastPathComponent,
                hasWindow: false
            )
        default:
            DockProgressController.shared.report(
                .failure,
                title: "Extraction Failed",
                body: destination.lastPathComponent,
                hasWindow: false
            )
        }
    }
}
