import Foundation

public enum ArchiveEngineStatus: Sendable {
    case idle
    case processing(progress: Double?, message: String)
    case inputRequired(ArchivePasswordRequest)
    case done
    case cancelled
    case error(String)
}
