import Foundation
import AppKit

/// Drives `ArchiveSession.verifyCurrentArchive()` and reports the outcome via
/// a native `NSAlert`. Used by `M7ArchiverApp` URL handling to fulfill
/// `m7archiver://testArchive` requests after the archive opens (and unlocks,
/// if needed).
@MainActor
enum AutoVerify {
    static func run(session: ArchiveSession, archiveURL: URL) async {
        let outcome = await session.verifyCurrentArchive()
        present(outcome, archiveURL: archiveURL)
    }

    private static func present(_ outcome: ArchiveSession.VerificationOutcome, archiveURL: URL) {
        let alert = NSAlert()
        alert.addButton(withTitle: "OK")

        switch outcome {
        case .completed(let details):
            alert.alertStyle = .informational
            alert.messageText = "\(archiveURL.lastPathComponent) passed verification"
            alert.informativeText = details.joined(separator: "\n")
        case .failed(let message, let details):
            alert.alertStyle = .warning
            alert.messageText = message
            alert.informativeText = details.joined(separator: "\n")
        case .missingArchive:
            alert.alertStyle = .warning
            alert.messageText = "Cannot verify archive"
            alert.informativeText = "No archive is open."
        case .locked:
            alert.alertStyle = .warning
            alert.messageText = "Cannot verify archive"
            alert.informativeText = "Unlock the archive before verification."
        case .cancelled:
            break // silently ignore
        }

        alert.runModal()
    }
}
