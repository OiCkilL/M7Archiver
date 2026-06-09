import Foundation
import ArchiveCore
import ArchivePresentation
import PDFKit

enum ArchiveInspectorPreviewKind: Equatable {
    case text
    case image
    case pdf
}

enum ArchiveInspectorImagePreviewMode: Equatable {
    case fit
    case fill
}

enum ArchiveInspectorPreviewDecision: Equatable {
    case load(ArchiveInspectorPreviewKind)
    case unavailable(String)
    case locked
}

struct ArchiveInspectorPreviewPolicy {
    static let maximumEntrySize: Int64 = 16 * 1_024 * 1_024
    static let maximumArchiveSize: Int64 = 256 * 1_024 * 1_024

    static func decision(
        for row: ArchiveRow,
        metadata: ArchiveMetadata?,
        lockState: ArchiveSession.LockState,
        isBusy: Bool
    ) -> ArchiveInspectorPreviewDecision {
        switch lockState {
        case .locked, .unlocking:
            return .locked
        case .empty, .failed, .unlocked:
            break
        }

        guard !isBusy else {
            return .unavailable("Preview unavailable while another operation is running.")
        }
        guard !row.isDirectory else {
            return .unavailable("Folders don’t have inline preview.")
        }
        if let entrySize = row.size, entrySize > maximumEntrySize {
            return .unavailable("File is too large for inline preview.")
        }
        if let archiveSize = metadata?.uncompressedSize, archiveSize > maximumArchiveSize {
            return .unavailable("Archive is too large for inline preview.")
        }

        let ext = (row.name as NSString).pathExtension.lowercased()
        if textExtensions.contains(ext) {
            return .load(.text)
        }
        if imageExtensions.contains(ext) {
            return .load(.image)
        }
        if pdfExtensions.contains(ext) {
            return .load(.pdf)
        }
        return .unavailable("Preview not available for this file type.")
    }

    private static let textExtensions: Set<String> = [
        "txt", "md", "markdown", "json", "xml", "yaml", "yml", "csv", "tsv", "log", "ini", "cfg", "conf", "html", "htm", "css", "js", "ts", "swift", "py", "rb", "go", "java", "c", "h", "cpp", "hpp", "m", "mm", "sh", "zsh"
    ]

    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "bmp", "tif", "tiff", "webp", "heic", "heif", "icns"
    ]

    private static let pdfExtensions: Set<String> = ["pdf"]
}

struct ArchiveInspectorTextPreview {
    private static let noBOMSampleFallbackLength = 5

    private static let suggestedEncodings: [NSNumber] = [
        NSNumber(value: String.Encoding.utf8.rawValue),
        NSNumber(value: String.Encoding.utf16LittleEndian.rawValue),
        NSNumber(value: String.Encoding.utf16BigEndian.rawValue),
        NSNumber(value: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.shiftJIS.rawValue))),
        NSNumber(value: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5.rawValue))),
        NSNumber(value: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))),
        NSNumber(value: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.EUC_KR.rawValue))),
        NSNumber(value: String.Encoding.isoLatin1.rawValue),
        NSNumber(value: String.Encoding.windowsCP1252.rawValue),
    ]

    static func decodeText(from data: Data) -> String? {
        // BOM — unambiguous, always correct.
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            return String(data: data.dropFirst(3), encoding: .utf8)
        }
        if data.starts(with: [0xFF, 0xFE, 0x00, 0x00]) {
            return String(data: data.dropFirst(4), encoding: .utf32LittleEndian)
        }
        if data.starts(with: [0x00, 0x00, 0xFE, 0xFF]) {
            return String(data: data.dropFirst(4), encoding: .utf32BigEndian)
        }
        if data.starts(with: [0xFF, 0xFE]) {
            return String(data: data.dropFirst(2), encoding: .utf16LittleEndian)
        }
        if data.starts(with: [0xFE, 0xFF]) {
            return String(data: data.dropFirst(2), encoding: .utf16BigEndian)
        }

        // Short no-BOM samples — show raw UTF-8 bytes (product policy).
        // Checks both character count and byte count so 2-byte UTF-16 samples
        // like "test" (4 raw bytes = 8 UTF-8-chars after fallback) still gate.
        let fallbackCount = String(decoding: data, as: UTF8.self).count
        if fallbackCount <= noBOMSampleFallbackLength || data.count <= 8 {
            return String(decoding: data, as: UTF8.self)
        }

        // UTF-16 without BOM — catch what the native API misses for raw UTF-16
        // data where the UTF-8 fallback shows embedded null bytes.
        if let utf16 = preferredNoBOMUTF16Candidate(data) {
            return utf16
        }

        // Use macOS native charset detection for everything else.
        var converted: NSString?
        let detected = NSString.stringEncoding(
            for: data,
            encodingOptions: [
                .suggestedEncodingsKey: suggestedEncodings,
            ],
            convertedString: &converted,
            usedLossyConversion: nil
        )
        if detected != 0, let text = converted {
            return text as String
        }
        return nil
    }

    /// When raw UTF-16 data produces a null-riddled UTF-8 fallback, pick the
    /// UTF-16 endianness that produces better text.
    private static func preferredNoBOMUTF16Candidate(_ data: Data) -> String? {
        guard data.count >= 4, data.count.isMultiple(of: 2) else { return nil }
        guard let little = String(data: data, encoding: .utf16LittleEndian),
              let big = String(data: data, encoding: .utf16BigEndian) else { return nil }

        let littleNulls = little.filter { $0 == "\0" }.count
        let bigNulls = big.filter { $0 == "\0" }.count
        let fallbackNulls = String(decoding: data, as: UTF8.self).filter { $0 == "\0" }.count

        if fallbackNulls > 0 {
            let littleScore = utf16EndiannessQuality(little)
            let bigScore = utf16EndiannessQuality(big)
            if littleNulls < fallbackNulls, littleNulls <= bigNulls, littleScore >= bigScore { return little }
            if bigNulls < fallbackNulls { return big }
        }

        return nil
    }

    /// Penalize obscure CJK Extension A / PUA codepoints that appear when
    /// the wrong endianness is chosen for Arabic or Latin raw UTF-16.
    private static func utf16EndiannessQuality(_ text: String) -> Int {
        var score = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x3400...0x4DBF: score -= 50   // CJK Extension A artifact
            case 0xE000...0xF8FF: score -= 100  // PUA
            case 0x20000...0x2FFFF: score -= 30 // CJK Extension B+
            case 0...0x1F, 0x7F...0x9F: score -= 20
            case 0x0600...0x06FF: score += 5    // Arabic
            case 0x4E00...0x9FFF: score += 3    // CJK Unified
            case 0x3040...0x30FF: score += 5    // Kana
            case 0xAC00...0xD7AF: score += 5    // Hangul
            default: score += 1
            }
        }
        return score
    }

    static func excerpt(from text: String, maximumCharacters: Int = 280, maximumLines: Int = 12) -> String {
        guard maximumCharacters > 0, maximumLines > 0 else { return "" }

        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)
        var collected: [String] = []
        var remaining = maximumCharacters

        for line in lines.prefix(maximumLines) {
            guard remaining > 0 else { break }
            let value = String(line)
            if value.count <= remaining {
                collected.append(value)
                remaining -= value.count
            } else {
                collected.append(String(value.prefix(remaining)))
                remaining = 0
                break
            }
        }

        var result = collected.joined(separator: "\n")
        if result.isEmpty {
            result = String(normalized.prefix(maximumCharacters))
        }
        if normalized.count > result.count || lines.count > maximumLines {
            result += "…"
        }
        return result
    }
}

struct ArchiveInspectorPreviewSupport {
    static let previewAspectRatio: CGFloat = 4.0 / 3.0

    static func imagePreviewMode(for size: CGSize) -> ArchiveInspectorImagePreviewMode {
        guard size.width > 0, size.height > 0 else { return .fit }
        let ratio = size.width / size.height
        return ratio > 3.0 || ratio < 1.0 / 3.0 ? .fill : .fit
    }

    static func shouldLoadPreview(selectedTab: InspectorTab) -> Bool {
        selectedTab == .info
    }

    static func previewIdentity(
        archivePath: String,
        previewPath: String?,
        selectedTab: InspectorTab,
        isUnlocked: Bool,
        isBusy: Bool
    ) -> String {
        [
            archivePath,
            previewPath ?? "",
            selectedTab.rawValue,
            isUnlocked ? "unlocked" : "other",
            isBusy ? "busy" : "idle"
        ].joined(separator: "||")
    }

    static func renderPDFFirstPage(from url: URL) -> NSImage? {
        guard let document = PDFDocument(url: url),
              let page = document.page(at: 0) else { return nil }
        let pageRect = page.bounds(for: .mediaBox)
        guard pageRect.width > 0, pageRect.height > 0 else { return nil }
        let width = Int(pageRect.width)
        let height = Int(pageRect.height)
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        page.draw(with: .mediaBox, to: context)
        guard let cgImage = context.makeImage() else { return nil }
        return NSImage(cgImage: cgImage, size: pageRect.size)
    }
}

struct ArchiveRowVisibility {
    static func includes(_ row: ArchiveRow, showHiddenFiles: Bool) -> Bool {
        row.id == ArchiveRow.parentDirectoryID || showHiddenFiles || !row.name.hasPrefix(".")
    }
}

struct ArchiveInspectorSelectionResolver {
    static func singleSelectedRow(
        selection: Set<ArchiveRow.ID>,
        currentPath: [String],
        searchQuery: String,
        entries: [ArchiveEntry],
        showHiddenFiles: Bool
    ) -> ArchiveRow? {
        guard selection.count == 1, let id = selection.first else { return nil }
        let search = ArchiveSearch()
        let rows: [ArchiveRow]
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            rows = search.rows(at: currentPath, in: entries)
        } else {
            rows = search.search(entries, query: trimmed)
        }
        return rows
            .filter { ArchiveRowVisibility.includes($0, showHiddenFiles: showHiddenFiles) }
            .first(where: { $0.id == id })
    }
}

private extension ArchiveEncoding {
    var cfStringEncoding: CFStringEncoding? {
        switch self {
        case .automatic:
            return nil
        case .utf8:
            return CFStringBuiltInEncodings.UTF8.rawValue
        case .gb18030:
            return CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        case .big5:
            return CFStringEncoding(CFStringEncodings.big5.rawValue)
        case .shiftJIS:
            return CFStringEncoding(CFStringEncodings.shiftJIS.rawValue)
        case .eucKR:
            return CFStringEncoding(CFStringEncodings.EUC_KR.rawValue)
        case .cp437:
            return CFStringEncoding(CFStringEncodings.dosLatinUS.rawValue)
        case .windows1252:
            return CFStringConvertWindowsCodepageToEncoding(1252)
        case .cp850:
            return CFStringEncoding(CFStringEncodings.dosLatin1.rawValue)
        }
    }
}
