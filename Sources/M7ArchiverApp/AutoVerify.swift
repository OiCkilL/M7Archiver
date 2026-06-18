import Foundation
import AppKit

/// Drives `ArchiveSession.verifyCurrentArchive()`.  The outcome is written to
/// `session.verifyResult`, which the in-window status bar renders inline
/// (icon + label + details popover) — identical to an in-app verify, so there
/// is no modal `NSAlert`.  The Dock controller reports the terminal state for
/// background notification/badge.  Used by `M7ArchiverApp` URL handling to
/// fulfill `m7archiver://testArchive` requests after the archive opens (and
/// unlocks, if needed).
@MainActor
enum AutoVerify {
    static func run(session: ArchiveSession, archiveURL: URL) async {
        let dockToken = DockProgressController.shared.observe { [session] in
            session.progress?.fraction
        }
        let outcome = await session.verifyCurrentArchive()
        _ = dockToken  // held until report clears the source
        let name = archiveURL.lastPathComponent
        switch outcome {
        case .completed:
            // Result already surfaced via session.verifyResult in the status
            // bar; the Dock report only adds a background notification.
            DockProgressController.shared.report(.success, title: "Verification Passed", body: name)
        case .failed(let message, _):
            DockProgressController.shared.report(.failure, title: "Verification Failed", body: "\(name) — \(message)")
        case .cancelled:
            DockProgressController.shared.report(.cancelled, title: "Verification Cancelled", body: name)
        case .missingArchive:
            DockProgressController.shared.report(.failure, title: "Verification Failed", body: "No archive is open.")
        case .locked:
            DockProgressController.shared.report(.failure, title: "Verification Failed", body: "Unlock the archive before verification.")
        }
    }
}
