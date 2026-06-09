import Foundation

/// Pure helpers shared by Add to Archive and quick-compress flows.
@MainActor
enum AddToArchive {
    /// File stem to use when suggesting the new archive name:
    ///   - one source → that file's stem (foo.txt → "foo")
    ///   - one source folder → the full folder name, even if it contains dots
    ///   - multiple sources sharing a parent → the parent folder name
    ///   - otherwise → "Archive"
    nonisolated static func suggestedStem(for sources: [URL]) -> String {
        if sources.count == 1, let only = sources.first {
            let standardized = only.standardizedFileURL
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: standardized.path, isDirectory: &isDir)
            let name = (exists && isDir.boolValue)
                ? standardized.lastPathComponent
                : standardized.deletingPathExtension().lastPathComponent
            return name.isEmpty ? "Archive" : name
        }

        let parents = Set(sources.map { $0.deletingLastPathComponent().standardizedFileURL.path })
        if parents.count == 1, let parent = parents.first {
            let parentName = (parent as NSString).lastPathComponent
            if !parentName.isEmpty, parentName != "/" { return parentName }
        }
        return "Archive"
    }

    nonisolated static func preferredDestinationDirectory(for sources: [URL], finderTarget: URL?) -> URL? {
        if let finderTarget {
            var isDir: ObjCBool = false
            let isDirPath = FileManager.default.fileExists(atPath: finderTarget.path, isDirectory: &isDir) && isDir.boolValue
            return isDirPath ? finderTarget : finderTarget.deletingLastPathComponent()
        }
        return sources.first?.deletingLastPathComponent()
    }
}
