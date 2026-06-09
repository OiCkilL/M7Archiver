import Foundation
import ArchiveCore

/// Display row used by archive list views and selection state.
///
/// Wraps `ArchiveEntry` so we can give every row a stable, path-derived id
/// (libarchive returns flat lists; we synthesize directory rows for the
/// breadcrumb view, and those need stable ids that survive recomputation).
public struct ArchiveRow: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public var path: String
    public var name: String
    public var fileType: String
    public var size: Int64?
    public var packedSize: Int64?
    public var modifiedAt: Date?
    public var isDirectory: Bool
    public var isEncrypted: Bool

    public init(entry: ArchiveEntry) {
        self.id = entry.path
        self.path = entry.path
        self.name = entry.name
        self.size = entry.size
        self.packedSize = entry.packedSize
        self.modifiedAt = entry.modifiedAt
        self.isDirectory = entry.isDirectory
        self.isEncrypted = entry.isEncrypted
        self.fileType = ArchiveRow.fileType(for: entry)
    }

    public static let parentDirectoryID = "__parent__"

    public static let parentDirectory = ArchiveRow(
        id: parentDirectoryID,
        path: "..",
        name: "..",
        fileType: "Folder",
        size: nil,
        packedSize: nil,
        modifiedAt: nil,
        isDirectory: true,
        isEncrypted: false
    )

    public static func directory(name: String, path: String) -> ArchiveRow {
        ArchiveRow(
            id: path,
            path: path,
            name: name,
            fileType: "Folder",
            size: nil,
            packedSize: nil,
            modifiedAt: nil,
            isDirectory: true,
            isEncrypted: false
        )
    }

    private init(
        id: String,
        path: String,
        name: String,
        fileType: String,
        size: Int64?,
        packedSize: Int64?,
        modifiedAt: Date?,
        isDirectory: Bool,
        isEncrypted: Bool
    ) {
        self.id = id
        self.path = path
        self.name = name
        self.fileType = fileType
        self.size = size
        self.packedSize = packedSize
        self.modifiedAt = modifiedAt
        self.isDirectory = isDirectory
        self.isEncrypted = isEncrypted
    }

    private static func fileType(for entry: ArchiveEntry) -> String {
        if entry.isDirectory { return "Folder" }
        let ext = (entry.name as NSString).pathExtension
        return ext.isEmpty ? "File" : ext.uppercased()
    }

    // MARK: - Sortable accessors

    public var sizeOrZero: Int64 { size ?? 0 }
    public var modifiedAtSortKey: Date { modifiedAt ?? .distantPast }
}
