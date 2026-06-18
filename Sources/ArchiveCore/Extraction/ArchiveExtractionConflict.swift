import Foundation

/// How the extraction finalizer should handle an entry whose destination path
/// is already occupied by an existing file.
public enum ArchiveExtractionConflictStrategy: Sendable, Equatable {
    /// Overwrite the existing file (back it up to the rollback directory first,
    /// restored on failure).  Current default behavior.
    case overwrite
    /// Write the incoming entry to a Finder-style unique name
    /// (`name 2.ext`, `name 3.ext`, …) and leave the existing file untouched.
    /// Used for quick "Extract Here" so the operation never interrupts.
    case rename
    /// Ask the caller how to resolve each conflict via `onConflict`.
    case ask
}

/// Describes a single conflict encountered during finalization.
public struct ArchiveExtractionConflict: Sendable, Equatable {
    public let existingURL: URL
    public let incomingStagedURL: URL
    public let proposedFinalURL: URL
    public let entryPath: String

    public init(existingURL: URL, incomingStagedURL: URL, proposedFinalURL: URL, entryPath: String) {
        self.existingURL = existingURL
        self.incomingStagedURL = incomingStagedURL
        self.proposedFinalURL = proposedFinalURL
        self.entryPath = entryPath
    }
}

/// Caller's resolution for a conflict.  When the strategy is `.ask`, the first
/// conflict is reported via `onConflict` and the returned decision is applied
/// to all subsequent conflicts in the same operation (single-dialog behavior,
/// matching macOS Archive Utility).
public enum ArchiveExtractionConflictDecision: Sendable, Equatable {
    /// Overwrite the existing file (backed up for rollback).
    case overwrite
    /// Keep the existing file; write the incoming one to a unique name.
    case keepBoth
    /// Stop the operation; roll back everything already written.
    case stop
}
