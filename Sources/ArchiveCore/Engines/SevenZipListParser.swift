import Foundation

/// Pure parser for `7zz l -slt` (and `-slt -ba`) machine-readable output.
///
/// Format:
/// - Header banner (skipped)
/// - Optional archive metadata block delimited by a leading `--` line
/// - `----------` separator
/// - Per-entry blocks, each `Key = Value` lines, separated by blank lines
public enum SevenZipListParser {
    /// Parse archive metadata + entries from a full `7zz l -slt` listing.
    public static func parse(_ output: String) -> Parsed {
        let lines = output
            .split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" })
            .map(String.init)

        enum Mode {
            case scanning       // before any block markers
            case archiveBlock   // saw `--`, gathering archive metadata
            case entries        // saw `----------` or `Path = ...` (entry-only output)
        }

        var archiveBlock: [String: String] = [:]
        var entries: [[String: String]] = []
        var current: [String: String] = [:]
        var mode: Mode = .scanning

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("----------") {
                if !current.isEmpty {
                    entries.append(current)
                    current = [:]
                }
                mode = .entries
                continue
            }

            if trimmed == "--" {
                mode = .archiveBlock
                continue
            }

            switch mode {
            case .scanning:
                // `7zz l -slt -ba` skips the banner + archive block, so the
                // first thing we see is a `Path = ...` line. Switch to
                // entry-only mode the moment we recognise that shape.
                if let kv = parseKeyValue(line), kv.0 == "Path" {
                    mode = .entries
                    current[kv.0] = kv.1
                }

            case .archiveBlock:
                if let kv = parseKeyValue(line) {
                    archiveBlock[kv.0] = kv.1
                }

            case .entries:
                if trimmed.isEmpty {
                    if !current.isEmpty {
                        entries.append(current)
                        current = [:]
                    }
                    continue
                }
                if let kv = parseKeyValue(line) {
                    current[kv.0] = kv.1
                }
            }
        }

        if !current.isEmpty {
            entries.append(current)
        }

        return Parsed(
            archive: archiveBlock,
            entries: entries.map(makeEntry)
        )
    }

    public struct Parsed: Equatable, Sendable {
        public var archive: [String: String]
        public var entries: [ArchiveEntry]
    }

    // MARK: - Internals

    private static func parseKeyValue(_ line: String) -> (String, String)? {
        guard let equalsRange = line.range(of: " = ") else { return nil }
        let key = String(line[line.startIndex..<equalsRange.lowerBound])
            .trimmingCharacters(in: .whitespaces)
        let value = String(line[equalsRange.upperBound...])
            .trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        return (key, value)
    }

    private static func makeEntry(_ fields: [String: String]) -> ArchiveEntry {
        let path = fields["Path"] ?? ""
        let size = fields["Size"].flatMap(Int64.init)
        let packedSize = fields["Packed Size"].flatMap(Int64.init)
        let modifiedAt = fields["Modified"].flatMap(parse7zDate)
        let attributes = fields["Attributes"] ?? ""
        let isDirectory = fields["Folder"] == "+" || attributes.hasPrefix("D")
        let method = fields["Method"]
        let isEncrypted = fields["Encrypted"] == "+"

        return ArchiveEntry(
            path: path,
            size: size,
            packedSize: packedSize,
            modifiedAt: modifiedAt,
            isDirectory: isDirectory,
            method: (method?.isEmpty == false) ? method : nil,
            isEncrypted: isEncrypted
        )
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    private static func parse7zDate(_ raw: String) -> Date? {
        // 7zz emits "2024-01-01 12:00:00" or "2024-01-01 12:00:00.0000000".
        // Trim any sub-second suffix; the formatter only accepts whole seconds.
        let trimmed = raw.split(separator: ".", maxSplits: 1).first.map(String.init) ?? raw
        return dateFormatter.date(from: trimmed)
    }
}
