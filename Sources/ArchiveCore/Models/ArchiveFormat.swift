public enum ArchiveFormat: String, Codable, CaseIterable, Hashable, Sendable {
    case sevenZip = "7z"
    case zip
    case rar
    case tar
    case gzip
    case bzip2
    case xz
    case cab
    case iso
    case xar
    case cpio
    case zstd
    case tarGzip = "tar.gz"
    case tarBzip2 = "tar.bz2"
    case tarXz = "tar.xz"
    case tarZstd = "tar.zst"
}
