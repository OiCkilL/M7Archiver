public enum ArchiveEngineType: String, Codable, CaseIterable, Hashable, Sendable {
    case libarchive
    case sevenZip
    case externalRar
}
