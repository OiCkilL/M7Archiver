struct ArchiveFormatCatalogDTO: Decodable {
    var formats: [ArchiveFormatDefinition]
    var compounds: [CompoundArchiveFormat]
}

public struct ArchiveFormatDefinition: Decodable, Equatable, Sendable {
    public var id: ArchiveFormat
    public var name: String
    public var utis: [String]
    public var extensions: [String]
    public var magicSignatures: [MagicSignature]
    public var engines: [ArchiveEngineDefinition]
}

public struct MagicSignature: Decodable, Equatable, Sendable {
    public var bytes: [UInt8]
    public var offset: Int

    enum CodingKeys: String, CodingKey {
        case hex
        case offset
    }

    public init(bytes: [UInt8], offset: Int = 0) {
        self.bytes = bytes
        self.offset = offset
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let hex = try container.decode(String.self, forKey: .hex)
        self.bytes = hex.split(separator: " ").compactMap { UInt8($0, radix: 16) }
        self.offset = try container.decodeIfPresent(Int.self, forKey: .offset) ?? 0
    }
}

public struct ArchiveEngineDefinition: Decodable, Equatable, Sendable {
    public var type: ArchiveEngineType
    public var capabilities: Set<ArchiveCapability>
    public var isDefault: Bool

    enum CodingKeys: String, CodingKey {
        case type
        case capabilities
        case isDefault = "default"
    }

    public init(type: ArchiveEngineType, capabilities: Set<ArchiveCapability>, isDefault: Bool = false) {
        self.type = type
        self.capabilities = capabilities
        self.isDefault = isDefault
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try container.decode(ArchiveEngineType.self, forKey: .type)
        let capabilities = try container.decode([ArchiveCapability].self, forKey: .capabilities)
        self.capabilities = Set(capabilities)
        self.isDefault = try container.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
    }
}
