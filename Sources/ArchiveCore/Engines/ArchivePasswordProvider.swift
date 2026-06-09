import Foundation

public enum ArchivePasswordReason: String, Codable, Sendable {
    case required
    case wrongPassword
}

public struct ArchivePasswordRequest: Codable, Equatable, Sendable {
    public var archiveURL: URL
    public var operation: ArchiveOperation
    public var attempt: Int
    public var reason: ArchivePasswordReason

    public init(archiveURL: URL, operation: ArchiveOperation, attempt: Int, reason: ArchivePasswordReason) {
        self.archiveURL = archiveURL
        self.operation = operation
        self.attempt = attempt
        self.reason = reason
    }
}

public typealias ArchivePasswordProvider = @Sendable (ArchivePasswordRequest) async -> String?
