public struct ArchiveCapability: RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: StringLiteralType) {
        self.rawValue = value
    }

    public static let listContents: ArchiveCapability = "listContents"
    public static let extractFiles: ArchiveCapability = "extractFiles"
    public static let create: ArchiveCapability = "create"
    public static let readComment: ArchiveCapability = "readComment"
    public static let writeComment: ArchiveCapability = "writeComment"
    public static let detectEncoding: ArchiveCapability = "detectEncoding"
    public static let overrideEncoding: ArchiveCapability = "overrideEncoding"
    public static let encrypt: ArchiveCapability = "encrypt"
    public static let encryptFileNames: ArchiveCapability = "encryptFileNames"
    public static let createVolumes: ArchiveCapability = "createVolumes"
    public static let extractVolumes: ArchiveCapability = "extractVolumes"
    public static let externalCreate: ArchiveCapability = "externalCreate"
    public static let advanced7z: ArchiveCapability = "advanced7z"
}

public struct ArchiveCapabilities: Codable, Equatable, Sendable {
    public var values: Set<ArchiveCapability>

    public init(_ values: Set<ArchiveCapability> = []) {
        self.values = values
    }

    public func contains(_ capability: ArchiveCapability) -> Bool {
        values.contains(capability)
    }

    public func isSuperset(of requested: Set<ArchiveCapability>) -> Bool {
        values.isSuperset(of: requested)
    }
}
