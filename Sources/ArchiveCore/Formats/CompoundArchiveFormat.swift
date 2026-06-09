public struct CompoundArchiveFormat: Decodable, Equatable, Sendable {
    public var id: ArchiveFormat
    public var extensions: [String]
    public var container: ArchiveFormat
    public var payload: ArchiveFormat

    public init(id: ArchiveFormat, extensions: [String], container: ArchiveFormat, payload: ArchiveFormat) {
        self.id = id
        self.extensions = extensions
        self.container = container
        self.payload = payload
    }
}
