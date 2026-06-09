import Foundation

public enum ExternalRarEngineError: Error, Equatable, Sendable {
    case notConfigured
}

public struct ExternalRarEngine: ArchiveEngine {
    public let type: ArchiveEngineType = .externalRar
    public var isConfigured: Bool

    public init(isConfigured: Bool = false) {
        self.isConfigured = isConfigured
    }

    public func listContents(of archiveURL: URL, options: ArchiveOperationOptions = ArchiveOperationOptions()) async throws -> [ArchiveEntry] {
        throw ExternalRarEngineError.notConfigured
    }

    public func metadata(of archiveURL: URL, options: ArchiveOperationOptions = ArchiveOperationOptions()) async throws -> ArchiveMetadata {
        throw ExternalRarEngineError.notConfigured
    }

    public func testArchive(_ archiveURL: URL, options: ArchiveOperationOptions = ArchiveOperationOptions()) async throws -> ArchiveOperationResult {
        throw ExternalRarEngineError.notConfigured
    }

    public func extract(_ archiveURL: URL, to destinationURL: URL, options: ArchiveOperationOptions = ArchiveOperationOptions()) async throws -> ArchiveOperationResult {
        throw ExternalRarEngineError.notConfigured
    }

    public func createArchive(from sourceURLs: [URL], to archiveURL: URL, profile: CompressionProfile, password: String?, encryptionMethod: String?, options: ArchiveOperationOptions = ArchiveOperationOptions()) async throws -> ArchiveOperationResult {
        throw ExternalRarEngineError.notConfigured
    }

    public func statusStream() async -> AsyncStream<ArchiveEngineStatus> {
        AsyncStream { continuation in
            continuation.yield(.idle)
            continuation.finish()
        }
    }

    public func cancel() async {}
}
