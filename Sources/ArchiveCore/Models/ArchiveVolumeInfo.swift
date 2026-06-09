public struct ArchiveVolumeInfo: Codable, Equatable, Sendable {
    public var index: Int
    public var count: Int?
    public var size: Int64?
    public var fileName: String?

    public init(index: Int, count: Int? = nil, size: Int64? = nil, fileName: String? = nil) {
        self.index = index
        self.count = count
        self.size = size
        self.fileName = fileName
    }
}
