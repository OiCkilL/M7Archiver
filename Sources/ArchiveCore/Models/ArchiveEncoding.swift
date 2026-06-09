public enum ArchiveEncoding: String, Codable, CaseIterable, Hashable, Sendable {
    case automatic
    case utf8
    case gb18030
    case big5
    case shiftJIS
    case eucKR
    case cp437
    case windows1252
    case cp850

    public static let defaultAutomaticDetectionPriority: [ArchiveEncoding] = [
        .shiftJIS, .eucKR, .big5, .gb18030, .cp437, .windows1252, .cp850
    ]

    public static func automaticDetectionCandidates(in values: [ArchiveEncoding]) -> [ArchiveEncoding] {
        var seen = Set<ArchiveEncoding>()
        var candidates: [ArchiveEncoding] = []
        for encoding in values where encoding.isAutomaticDetectionCandidate {
            if seen.insert(encoding).inserted {
                candidates.append(encoding)
            }
        }
        return candidates
    }

    public static func normalizedAutomaticDetectionOrder(_ values: [ArchiveEncoding]) -> [ArchiveEncoding] {
        var normalized = automaticDetectionCandidates(in: values)
        var seen = Set(normalized)
        for encoding in defaultAutomaticDetectionPriority where seen.insert(encoding).inserted {
            normalized.append(encoding)
        }
        return normalized
    }

    public var isAutomaticDetectionCandidate: Bool {
        libarchiveCharset != nil
    }

    /// The charset name libarchive expects for ZIP read/extract `hdrcharset`
    /// overrides. `nil` means either automatic detection or normal UTF-8.
    public var libarchiveCharset: String? {
        switch self {
        case .automatic, .utf8: return nil
        case .gb18030:           return "GB18030"
        case .big5:              return "CP950"
        case .shiftJIS:          return "CP932"
        case .eucKR:             return "CP949"
        case .cp437:             return "CP437"
        case .windows1252:       return "CP1252"
        case .cp850:             return "CP850"
        }
    }

    /// The charset name libarchive expects for ZIP create-time `hdrcharset`
    /// overrides. `utf8` is explicit on writes so the archive gets the correct
    /// UTF-8 filename behavior even when the process locale differs.
    public var libarchiveZipWriteCharset: String? {
        switch self {
        case .automatic:         return nil
        case .utf8:              return "UTF-8"
        case .gb18030:           return "GB18030"
        case .big5:              return "CP950"
        case .shiftJIS:          return "CP932"
        case .eucKR:             return "CP949"
        case .cp437:             return "CP437"
        case .windows1252:       return "CP1252"
        case .cp850:             return "CP850"
        }
    }
}
