import Foundation

public enum ArchiveCreationServiceError: Error, Equatable, Sendable {
    case missingSources
}

public struct ArchiveCreationService: Sendable {
    private let selector: ArchiveEngineSelector

    public init(selector: ArchiveEngineSelector = ArchiveEngineSelector()) {
        self.selector = selector
    }

    public func createArchive(from sourceURLs: [URL], to archiveURL: URL, profile: CompressionProfile, password: String? = nil, encryptionMethod: String? = nil) async throws -> ArchiveOperationResult {
        let matcher = IgnoreRuleMatcher(rules: profile.ignoreRules)
        let filteredSources = sourceURLs.filter { !matcher.shouldIgnore($0) }
        guard !filteredSources.isEmpty else { throw ArchiveCreationServiceError.missingSources }
        let requested = requestedCapabilities(for: profile)
        let engine = try selector.makeEngine(for: profile.format, requestedCapabilities: requested)
        return try await engine.createArchive(
            from: filteredSources,
            to: archiveURL,
            profile: profile,
            password: password,
            encryptionMethod: encryptionMethod
        )
    }

    private func requestedCapabilities(for profile: CompressionProfile) -> Set<ArchiveCapability> {
        Self.requestedCapabilities(for: profile)
    }

    /// Single authoritative mapping from `CompressionProfile` to the
    /// capability set required of the engine. ArchiveSession also calls this
    /// so the dialog and the service use the same gate.
    public static func requestedCapabilities(for profile: CompressionProfile) -> Set<ArchiveCapability> {
        var capabilities: Set<ArchiveCapability> = [.create]
        if profile.encryptFileNames { capabilities.insert(.encryptFileNames) }
        if profile.volumeSize != nil { capabilities.insert(.createVolumes) }
        // Only escalate to advanced7z for real 7z-only advanced features.
        // ZIP levels are handled by libarchive and must never request
        // advanced7z routing.
        if profile.format == .sevenZip,
           profile.level == .ultra || profile.dictionarySize != nil {
            capabilities.insert(.advanced7z)
        }
        return capabilities
    }
}
