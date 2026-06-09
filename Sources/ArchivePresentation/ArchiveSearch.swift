import Foundation
import ArchiveCore

/// Recursive search + breadcrumb resolution over a flat archive entry list.
public struct ArchiveSearch: Sendable {
    public init() {}

    /// Filters entries across the entire archive, ignoring `currentPath`.
    public func search(_ entries: [ArchiveEntry], query: String) -> [ArchiveRow] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return entries.map(ArchiveRow.init(entry:)) }
        return entries
            .filter { entry in
                entry.name.lowercased().contains(needle)
                    || entry.path.lowercased().contains(needle)
                    || (entry.method?.lowercased().contains(needle) ?? false)
            }
            .map(ArchiveRow.init(entry:))
    }

    /// Resolves the immediate children of `path` over a flat entry list.
    /// Synthesizes folder rows for paths that exist only as a prefix.
    public func rows(at path: [String], in entries: [ArchiveEntry]) -> [ArchiveRow] {
        let prefix = path.isEmpty ? "" : path.joined(separator: "/") + "/"
        var rows: [ArchiveRow] = []
        if !path.isEmpty {
            rows.append(.parentDirectory)
        }
        var seenDirectories = Set<String>()
        var seenPaths = Set<String>()
        for entry in entries {
            guard entry.path.hasPrefix(prefix) else { continue }
            let remainder: String
            if entry.path.utf8.count >= prefix.utf8.count {
                let bytes = entry.path.utf8.dropFirst(prefix.utf8.count)
                remainder = String(bytes) ?? ""
            } else {
                remainder = ""
            }
            if remainder.isEmpty { continue }
            if let slashIndex = remainder.firstIndex(of: "/") {
                let dirName = String(remainder[..<slashIndex])
                if seenDirectories.insert(dirName).inserted {
                    rows.append(.directory(name: dirName, path: prefix + dirName))
                }
            } else if seenPaths.insert(entry.path).inserted {
                if entry.isDirectory {
                    if seenDirectories.insert(entry.name).inserted {
                        rows.append(ArchiveRow(entry: entry))
                    }
                } else {
                    rows.append(ArchiveRow(entry: entry))
                }
            }
        }
        return rows
    }
}
