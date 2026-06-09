import Foundation

public protocol ArchiveEngine: Sendable {
    var type: ArchiveEngineType { get }

    func listContents(of archiveURL: URL, options: ArchiveOperationOptions) async throws -> [ArchiveEntry]
    func metadata(of archiveURL: URL, options: ArchiveOperationOptions) async throws -> ArchiveMetadata
    func testArchive(_ archiveURL: URL, options: ArchiveOperationOptions) async throws -> ArchiveOperationResult
    func extract(_ archiveURL: URL, to destinationURL: URL, options: ArchiveOperationOptions) async throws -> ArchiveOperationResult
    func createArchive(from sourceURLs: [URL], to archiveURL: URL, profile: CompressionProfile, password: String?, encryptionMethod: String?, options: ArchiveOperationOptions) async throws -> ArchiveOperationResult
    func statusStream() async -> AsyncStream<ArchiveEngineStatus>
    func cancel() async
}

public extension ArchiveEngine {
    /// Convenience for callers that never need encryption.
    func createArchive(from sourceURLs: [URL], to archiveURL: URL, profile: CompressionProfile) async throws -> ArchiveOperationResult {
        try await createArchive(from: sourceURLs, to: archiveURL, profile: profile, password: nil, encryptionMethod: nil, options: ArchiveOperationOptions())
    }

    /// Convenience for callers that need a password but don't care about
    /// a format-specific encryption variant.
    func createArchive(from sourceURLs: [URL], to archiveURL: URL, profile: CompressionProfile, password: String?) async throws -> ArchiveOperationResult {
        try await createArchive(from: sourceURLs, to: archiveURL, profile: profile, password: password, encryptionMethod: nil, options: ArchiveOperationOptions())
    }

    func createArchive(from sourceURLs: [URL], to archiveURL: URL, profile: CompressionProfile, password: String?, encryptionMethod: String?) async throws -> ArchiveOperationResult {
        try await createArchive(from: sourceURLs, to: archiveURL, profile: profile, password: password, encryptionMethod: encryptionMethod, options: ArchiveOperationOptions())
    }
}
