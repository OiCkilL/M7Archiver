import Foundation
import ArchiveCore

extension ArchiveEncoding {
    /// Display label used in the encoding picker.
    public var displayLabel: String {
        switch self {
        case .automatic: return "Auto"
        case .utf8: return "UTF-8"
        case .gb18030: return "GB18030"
        case .big5: return "Big5"
        case .shiftJIS: return "Shift JIS"
        case .eucKR: return "EUC-KR"
        case .cp437: return "CP437"
        case .windows1252: return "Windows-1252"
        case .cp850: return "CP850"
        }
    }
}

extension ArchiveFormat {
    /// Short, user-facing label for the archive format.
    public var displayLabel: String {
        switch self {
        case .sevenZip: return "7-Zip"
        case .zip: return "ZIP"
        case .rar: return "RAR"
        case .tar: return "TAR"
        case .gzip: return "Gzip"
        case .bzip2: return "Bzip2"
        case .xz: return "XZ"
        case .cab: return "CAB"
        case .iso: return "ISO"
        case .xar: return "XAR"
        case .cpio: return "CPIO"
        case .zstd: return "Zstandard"
        case .tarGzip: return "TAR.GZ"
        case .tarBzip2: return "TAR.BZ2"
        case .tarXz: return "TAR.XZ"
        case .tarZstd: return "TAR.ZST"
        }
    }
}

extension CompressionProfile {
    func withIgnoreRules(_ ignoreRules: [IgnoreRule]) -> CompressionProfile {
        var copy = self
        copy.ignoreRules = ignoreRules
        return copy
    }
}
