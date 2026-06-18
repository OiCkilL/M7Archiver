import AppKit
import ArchiveCore

/// Resolves extraction conflicts via a single Archive Utility-style modal
/// alert. The first call shows the alert and caches the user's choice; every
/// subsequent conflict in the same operation reuses the cached decision so
/// the user is only ever asked once. Shared by the prompted-extract flow
/// (`ArchiveWindowModel`) and the headless extract action
/// (`HeadlessExtractAction`).
@MainActor
final class ExtractionConflictDecisionBox {
    /// Cached decision from the first conflict. Returned for every subsequent
    /// conflict in the same operation.
    private(set) var cached: ArchiveExtractionConflictDecision?

    /// Shows the conflict alert on the first call and caches the decision.
    /// Subsequent calls return the cached decision without showing the alert.
    func resolve(_ conflict: ArchiveExtractionConflict) async -> ArchiveExtractionConflictDecision {
        if let cached {
            return cached
        }
        let decision = Self.presentConflictAlert(for: conflict)
        cached = decision
        return decision
    }

    private static func presentConflictAlert(for conflict: ArchiveExtractionConflict) -> ArchiveExtractionConflictDecision {
        let existing = conflict.existingURL.lastPathComponent
        let folder = conflict.existingURL.deletingLastPathComponent().lastPathComponent
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "An item with the name “\(existing)” already exists in “\(folder)”."
        alert.informativeText = "Do you want to replace it with the one being extracted\u{2026}?"
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Keep Both")
        alert.addButton(withTitle: "Stop")
        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            return .overwrite
        case .alertSecondButtonReturn:
            return .keepBoth
        case .alertThirdButtonReturn:
            return .stop
        default:
            // Cancel / escape defaults to "Stop" so we don't pick a
            // destructive option silently.
            return .stop
        }
    }
}
