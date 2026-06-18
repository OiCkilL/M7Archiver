import Foundation

public struct ArchiveOperationOptions: Sendable {
    public var passwordProvider: ArchivePasswordProvider?
    public var requestedCapabilities: Set<ArchiveCapability>
    public var encoding: ArchiveEncoding?
    public var automaticEncodingPriority: [ArchiveEncoding]?
    public var isCancelled: (@Sendable () -> Bool)?
    /// Called periodically during extraction with (current_entries, total_entries).
    /// current_entries is the count of entries that have been processed
    /// (both successful and skipped).  Not guaranteed to be called on any
    /// particular thread/actor.
    public var onExtractProgress: (@Sendable (Int64, Int64) -> Void)?

    /// Called periodically during archive creation with the completion
    /// fraction in `0.0...1.0`.  Only the 7-Zip CLI backend currently
    /// reports real percentages (parsed from `-bsp1` stdout); other engines
    /// leave it nil.  Not guaranteed to be called on any particular
    /// thread/actor.
    public var onCreateProgress: (@Sendable (Double) -> Void)?

    public init(
        passwordProvider: ArchivePasswordProvider? = nil,
        requestedCapabilities: Set<ArchiveCapability> = [],
        encoding: ArchiveEncoding? = nil,
        automaticEncodingPriority: [ArchiveEncoding]? = nil,
        isCancelled: (@Sendable () -> Bool)? = nil,
        onExtractProgress: (@Sendable (Int64, Int64) -> Void)? = nil,
        onCreateProgress: (@Sendable (Double) -> Void)? = nil
    ) {
        self.passwordProvider = passwordProvider
        self.requestedCapabilities = requestedCapabilities
        self.encoding = encoding
        self.automaticEncodingPriority = automaticEncodingPriority
        self.isCancelled = isCancelled
        self.onExtractProgress = onExtractProgress
        self.onCreateProgress = onCreateProgress
    }
}
