import Foundation

public struct ArchiveEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var path: String
    public var name: String
    public var size: Int64?
    public var packedSize: Int64?
    public var modifiedAt: Date?
    public var isDirectory: Bool
    public var method: String?
    public var isEncrypted: Bool

    public init(
        id: UUID = UUID(),
        path: String,
        name: String? = nil,
        size: Int64? = nil,
        packedSize: Int64? = nil,
        modifiedAt: Date? = nil,
        isDirectory: Bool = false,
        method: String? = nil,
        isEncrypted: Bool = false
    ) {
        self.id = id
        self.path = path
        self.name = name ?? path.split(separator: "/").last.map(String.init) ?? path
        self.size = size
        self.packedSize = packedSize
        self.modifiedAt = modifiedAt
        self.isDirectory = isDirectory
        self.method = method
        self.isEncrypted = isEncrypted
    }
}
