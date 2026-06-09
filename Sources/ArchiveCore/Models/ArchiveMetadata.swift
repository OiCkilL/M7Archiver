public struct ArchiveMetadata: Codable, Equatable, Sendable {
    public var format: ArchiveFormat
    public var comment: String?
    public var encoding: ArchiveEncoding?
    public var isEncrypted: Bool
    public var isMultiVolume: Bool
    public var volumeInfo: ArchiveVolumeInfo?
    public var entriesCount: Int?
    public var uncompressedSize: Int64?
    public var compressedSize: Int64?

    public init(
        format: ArchiveFormat,
        comment: String? = nil,
        encoding: ArchiveEncoding? = nil,
        isEncrypted: Bool = false,
        isMultiVolume: Bool = false,
        volumeInfo: ArchiveVolumeInfo? = nil,
        entriesCount: Int? = nil,
        uncompressedSize: Int64? = nil,
        compressedSize: Int64? = nil
    ) {
        self.format = format
        self.comment = comment
        self.encoding = encoding
        self.isEncrypted = isEncrypted
        self.isMultiVolume = isMultiVolume
        self.volumeInfo = volumeInfo
        self.entriesCount = entriesCount
        self.uncompressedSize = uncompressedSize
        self.compressedSize = compressedSize
    }
}
