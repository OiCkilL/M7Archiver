import Foundation
import AppKit

/// Orchestrates the auto-extract runtime flow: resolve destination, manage
/// security scope, drive `ArchiveSession.extract(to:)`, and (optionally)
/// reveal the result in Finder. Used both by `M7ArchiverApp` URL handling
/// and by `ArchiveWindowView`'s "Extract All" toolbar action.
@MainActor
enum AutoExtract {
    static func run(
        session: ArchiveSession,
        settings: ArchiveSettings,
        archiveURL: URL,
        finderTarget: URL? = nil,
        extractToSubfolder: Bool = true
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

        let outcome = await session.extract(to: destination)
        guard case .completed = outcome else {
            // 如果已经捕获了权限错误，状态栏会处理，这里不再弹窗
            if session.permissionError == nil {
                presentFailure(outcome)
            }
            return
        }

        if settings.revealInFinderAfterExtract {
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        }
    }

    private static func presentFailure(_ outcome: ArchiveSession.ExtractionOutcome) {
        let message: String
        switch outcome {
        case .completed:
            return
        case .unsupportedBackend(let format):
            message = "\(format.displayLabel) extraction is not available with the current backend."
        case .locked:
            message = "Unlock the archive before extracting files."
        case .missingArchive:
            message = "No archive is open."
        case .missingSelection:
            message = "Select at least one item to extract."
        case .cancelled:
            return
        case .failed(let details):
            message = details
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Extraction Failed"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
