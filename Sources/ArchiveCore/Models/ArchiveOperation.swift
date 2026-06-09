public enum ArchiveOperation: String, Codable, CaseIterable, Sendable {
    case listContents
    case metadata
    case testArchive
    case extract
    case create
}
