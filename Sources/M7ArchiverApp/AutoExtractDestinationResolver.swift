import Foundation

/// Resolved auto-extract destination, with a hint about whether the caller
/// must keep a security-scoped resource open while extracting.
struct AutoExtractDestinationResolution: Equatable, Sendable {
    var folderURL: URL
    var requiresSecurityScope: Bool
}

/// Pure resolution helpers for the auto-extract destination. A Finder-supplied
/// `target` always wins (it represents the explicit folder the user was looking
/// at), otherwise we follow `ArchiveSettings.AutoExtractDestinationStrategy`.
enum AutoExtractDestinationResolver {
    static func resolve(
        archiveURL: URL,
        finderTarget: URL?,
        strategy: ArchiveSettings.AutoExtractDestinationStrategy,
        bookmark: Data?,
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> AutoExtractDestinationResolution? {
        if let finderTarget {
            return AutoExtractDestinationResolution(
                folderURL: finderTarget,
                requiresSecurityScope: false
            )
        }

        switch strategy {
        case .sameFolder:
            return AutoExtractDestinationResolution(
                folderURL: archiveURL.deletingLastPathComponent(),
                requiresSecurityScope: false
            )
        case .downloads:
            let downloads = homeDirectoryURL.appendingPathComponent("Downloads", isDirectory: true)
            return AutoExtractDestinationResolution(
                folderURL: downloads,
                requiresSecurityScope: false
            )
        case .customBookmark:
            guard let bookmark else { return nil }
            var isStale = false
            guard let url = try? URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) else { return nil }
            return AutoExtractDestinationResolution(
                folderURL: url,
                requiresSecurityScope: true
            )
        }
    }

    /// Strip known archive extensions (single + paired like `.tar.gz`) so a
    /// per-archive output folder gets a clean name.
    static func archiveStem(for archiveURL: URL) -> String {
        let name = archiveURL.lastPathComponent
        let lowered = name.lowercased()
        let pairedExtensions = [".tar.gz", ".tar.bz2", ".tar.xz", ".tar.zst", ".tar.lz4"]
        for ext in pairedExtensions where lowered.hasSuffix(ext) {
            let stem = String(name.dropLast(ext.count))
            return stem.isEmpty ? "Archive" : stem
        }
        let stripped = (name as NSString).deletingPathExtension
        return stripped.isEmpty ? "Archive" : stripped
    }
}
