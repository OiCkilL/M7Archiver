import Foundation

public struct ArchiveOperationRequest: Sendable {
    public var operation: ArchiveOperation
    public var archiveURL: URL?
    public var sourceURLs: [URL]
    public var destinationURL: URL?
    public var format: ArchiveFormat?
    public var profile: CompressionProfile?
    public var requestedCapabilities: Set<ArchiveCapability>

    public init(
        operation: ArchiveOperation,
        archiveURL: URL? = nil,
        sourceURLs: [URL] = [],
        destinationURL: URL? = nil,
        format: ArchiveFormat? = nil,
        profile: CompressionProfile? = nil,
        requestedCapabilities: Set<ArchiveCapability> = []
    ) {
        self.operation = operation
        self.archiveURL = archiveURL
        self.sourceURLs = sourceURLs
        self.destinationURL = destinationURL
        self.format = format
        self.profile = profile
        self.requestedCapabilities = requestedCapabilities
    }
}
