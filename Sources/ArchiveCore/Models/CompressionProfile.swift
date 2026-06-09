public enum CompressionLevel: Int, Codable, CaseIterable, Sendable {
    case store = 0
    case fastest = 1
    case fast = 3
    case normal = 5
    case maximum = 7
    case ultra = 9
}

public struct CompressionProfile: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var format: ArchiveFormat
    public var level: CompressionLevel
    public var method: String?
    public var solid: Bool?
    public var dictionarySize: Int64?
    public var volumeSize: Int64?
    public var encryptFileNames: Bool
    public var ignoreRules: [IgnoreRule]
    public var filenameEncoding: ArchiveEncoding?

    public init(
        id: String? = nil,
        name: String,
        format: ArchiveFormat,
        level: CompressionLevel = .normal,
        method: String? = nil,
        solid: Bool? = nil,
        dictionarySize: Int64? = nil,
        volumeSize: Int64? = nil,
        encryptFileNames: Bool = false,
        ignoreRules: [IgnoreRule] = [],
        filenameEncoding: ArchiveEncoding? = nil
    ) {
        self.id = id ?? name
        self.name = name
        self.format = format
        self.level = level
        self.method = method
        self.solid = solid
        self.dictionarySize = dictionarySize
        self.volumeSize = volumeSize
        self.encryptFileNames = encryptFileNames
        self.ignoreRules = ignoreRules
        self.filenameEncoding = filenameEncoding
    }
}
