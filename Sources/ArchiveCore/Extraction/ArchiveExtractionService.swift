import Foundation

public enum ArchiveExtractionFinalizationError: Error, Equatable, Sendable {
    case unsafeDestinationPath(String)
}

public struct ArchiveExtractionFinalizer: Sendable {
    private struct MovePlan {
        var entry: ArchiveEntry
        var stagedURL: URL
        var finalURL: URL
    }

    private enum RollbackAction {
        case remove(URL)
        case restore(backup: URL, original: URL)
    }

    public init() {}

    public static func makeStagingDirectory(for destinationURL: URL, prefix: String = ".M7Archiver-staging-") throws -> URL {
        let fileManager = FileManager.default
        let parent = destinationURL.deletingLastPathComponent()
        if fileManager.fileExists(atPath: destinationURL.path) {
            let staging = destinationURL
                .appendingPathComponent(prefix + UUID().uuidString, isDirectory: true)
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
            return staging
        }
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent
            .appendingPathComponent(prefix + UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        return staging
    }

    public static func finalize(entries: [ArchiveEntry], from stagingDirectory: URL, to destinationURL: URL) throws -> [URL] {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)

        let plans = try entries.compactMap { entry -> MovePlan? in
            let stagedURL = try ArchivePathValidator.validatedOutputURL(for: entry.path, in: stagingDirectory)
            let finalURL = try ArchivePathValidator.validatedOutputURL(for: entry.path, in: destinationURL)
            try ensureSafeDestination(for: entry.path, in: destinationURL)
            guard fileManager.fileExists(atPath: stagedURL.path) else { return nil }
            return MovePlan(entry: entry, stagedURL: stagedURL, finalURL: finalURL)
        }

        var rollbackActions: [RollbackAction] = []
        let rollbackDirectory = destinationURL
            .appendingPathComponent(".M7Archiver-rollback-" + UUID().uuidString, isDirectory: true)
        var createdRollbackDirectory = false

        do {
            var outputURLs: [URL] = []
            for plan in plans {
                try ensureSafeDestination(for: plan.entry.path, in: destinationURL)
                guard fileManager.fileExists(atPath: plan.stagedURL.path) else { continue }
                if plan.entry.isDirectory {
                    var isDirectory: ObjCBool = false
                    if fileManager.fileExists(atPath: plan.finalURL.path, isDirectory: &isDirectory) {
                        guard isDirectory.boolValue else {
                            throw ArchiveExtractionFinalizationError.unsafeDestinationPath(plan.entry.path)
                        }
                    } else {
                        try fileManager.createDirectory(at: plan.finalURL, withIntermediateDirectories: true)
                        rollbackActions.append(.remove(plan.finalURL))
                    }
                    outputURLs.append(plan.finalURL)
                    continue
                }

                try fileManager.createDirectory(at: plan.finalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                var isDirectory: ObjCBool = false
                if fileManager.fileExists(atPath: plan.finalURL.path, isDirectory: &isDirectory) {
                    if isDirectory.boolValue {
                        throw ArchiveExtractionFinalizationError.unsafeDestinationPath(plan.entry.path)
                    }
                    if !createdRollbackDirectory {
                        try fileManager.createDirectory(at: rollbackDirectory, withIntermediateDirectories: true)
                        createdRollbackDirectory = true
                    }
                    let backup = rollbackDirectory.appendingPathComponent(UUID().uuidString)
                    try fileManager.moveItem(at: plan.finalURL, to: backup)
                    rollbackActions.append(.restore(backup: backup, original: plan.finalURL))
                } else {
                    rollbackActions.append(.remove(plan.finalURL))
                }
                try ensureSafeDestination(for: plan.entry.path, in: destinationURL)
                try fileManager.moveItem(at: plan.stagedURL, to: plan.finalURL)
                outputURLs.append(plan.finalURL)
            }

            if createdRollbackDirectory {
                try? fileManager.removeItem(at: rollbackDirectory)
            }
            return outputURLs
        } catch {
            for action in rollbackActions.reversed() {
                switch action {
                case .remove(let url):
                    try? fileManager.removeItem(at: url)
                case .restore(let backup, let original):
                    try? fileManager.removeItem(at: original)
                    if fileManager.fileExists(atPath: backup.path) {
                        try? fileManager.moveItem(at: backup, to: original)
                    }
                }
            }
            if createdRollbackDirectory {
                try? fileManager.removeItem(at: rollbackDirectory)
            }
            throw error
        }
    }

    private static func ensureSafeDestination(for entryPath: String, in destinationURL: URL) throws {
        let fileManager = FileManager.default
        let destination = destinationURL.standardizedFileURL
        let components = entryPath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !components.isEmpty else { throw ArchivePathValidationError.emptyPath }

        var current = destination
        if pathIsSymlink(current.path, fileManager: fileManager) {
            throw ArchiveExtractionFinalizationError.unsafeDestinationPath(entryPath)
        }

        for component in components.dropLast() {
            current.appendPathComponent(component, isDirectory: true)
            if pathIsSymlink(current.path, fileManager: fileManager) {
                throw ArchiveExtractionFinalizationError.unsafeDestinationPath(entryPath)
            }
        }

        let final = destination.appendingPathComponent(entryPath)
        if pathIsSymlink(final.path, fileManager: fileManager) {
            throw ArchiveExtractionFinalizationError.unsafeDestinationPath(entryPath)
        }
    }

    private static func pathIsSymlink(_ path: String, fileManager: FileManager) -> Bool {
        guard let type = try? fileManager.attributesOfItem(atPath: path)[.type] as? FileAttributeType else {
            return false
        }
        return type == .typeSymbolicLink
    }
}

public struct ArchiveExtractionService: Sendable {
    private let engine: LibArchiveEngine

    public init(engine: LibArchiveEngine = LibArchiveEngine()) {
        self.engine = engine
    }

    public func extract(_ archiveURL: URL, to destinationURL: URL, options: ArchiveOperationOptions = ArchiveOperationOptions()) async throws -> ArchiveOperationResult {
        let tempDirectory = try ArchiveExtractionFinalizer.makeStagingDirectory(for: destinationURL)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let result = try await engine.extractDirectly(archiveURL, to: tempDirectory, options: options)
        let outputURLs = try ArchiveExtractionFinalizer.finalize(entries: result.entries, from: tempDirectory, to: destinationURL)

        return ArchiveOperationResult(
            operation: .extract,
            archiveURL: archiveURL,
            destinationURL: destinationURL,
            entries: result.entries,
            outputURLs: outputURLs,
            warnings: result.warnings,
            skippedEntries: result.skippedEntries
        )
    }
}
