import Foundation

public struct SkippedEntry: Equatable, Sendable, Identifiable {
    public let id = UUID()
    public let path: String
    public let reason: String

    public init(path: String, reason: String) {
        self.path = path
        self.reason = reason
    }
}

public struct ArchiveOperationResult: Sendable {
    public var operation: ArchiveOperation
    public var archiveURL: URL?
    public var destinationURL: URL?
    public var entries: [ArchiveEntry]
    public var metadata: ArchiveMetadata?
    public var outputURLs: [URL]
    public var createdVolumes: [ArchiveVolumeInfo]
    public var warnings: [String]
    public var skippedEntries: [SkippedEntry]

    public init(
        operation: ArchiveOperation,
        archiveURL: URL? = nil,
        destinationURL: URL? = nil,
        entries: [ArchiveEntry] = [],
        metadata: ArchiveMetadata? = nil,
        outputURLs: [URL] = [],
        createdVolumes: [ArchiveVolumeInfo] = [],
        warnings: [String] = [],
        skippedEntries: [SkippedEntry] = []
    ) {
        self.operation = operation
        self.archiveURL = archiveURL
        self.destinationURL = destinationURL
        self.entries = entries
        self.metadata = metadata
        self.outputURLs = outputURLs
        self.createdVolumes = createdVolumes
        self.warnings = warnings
        self.skippedEntries = skippedEntries
    }
}
