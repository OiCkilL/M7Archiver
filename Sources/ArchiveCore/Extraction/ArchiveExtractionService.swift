import Foundation

public enum ArchiveExtractionFinalizationError: Error, Equatable, Sendable {
    case unsafeDestinationPath(String)
    /// The user chose "Stop" in a conflict dialog; the finalizer rolls back
    /// everything already written.
    case userStoppedExtraction
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

    public static func finalize(
        entries: [ArchiveEntry],
        from stagingDirectory: URL,
        to destinationURL: URL,
        conflictStrategy: ArchiveExtractionConflictStrategy = .overwrite,
        onConflict: (@Sendable (ArchiveExtractionConflict) async -> ArchiveExtractionConflictDecision)? = nil
    ) async throws -> [URL] {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)

        var plans = try entries.compactMap { entry -> MovePlan? in
            let stagedURL = try ArchivePathValidator.validatedOutputURL(for: entry.path, in: stagingDirectory)
            let finalURL = try ArchivePathValidator.validatedOutputURL(for: entry.path, in: destinationURL)
            try ensureSafeDestination(for: entry.path, in: destinationURL)
            guard fileManager.fileExists(atPath: stagedURL.path) else { return nil }
            return MovePlan(entry: entry, stagedURL: stagedURL, finalURL: finalURL)
        }

        // Resolve directory collisions up front so a renamed directory's child
        // entries can be redirected to the renamed path (e.g. folder/ → folder 2/
        // means folder/a.txt → folder 2/a.txt).  Only `.overwrite`/`.ask+.overwrite`
        // keeps the existing directory (merges into it); every other strategy
        // renames the colliding directory.
        var dirRemap: [(originalPath: String, renamedURL: URL)] = []
        var cachedAskDecision: ArchiveExtractionConflictDecision?
        for index in plans.indices where plans[index].entry.isDirectory {
            let plan = plans[index]
            let dirPath = plan.finalURL.standardizedFileURL.path
            guard fileManager.fileExists(atPath: dirPath) else { continue }
            // Existing item at the dir path must itself be a directory.
            var isDir: ObjCBool = false
            _ = fileManager.fileExists(atPath: dirPath, isDirectory: &isDir)
            guard isDir.boolValue else {
                throw ArchiveExtractionFinalizationError.unsafeDestinationPath(plan.entry.path)
            }
            let decision: ArchiveExtractionConflictDecision
            switch conflictStrategy {
            case .overwrite:
                decision = .overwrite
            case .rename:
                decision = .keepBoth
            case .ask:
                if let cached = cachedAskDecision {
                    decision = cached
                } else {
                    guard let onConflict else {
                        throw ArchiveExtractionFinalizationError.unsafeDestinationPath(plan.entry.path)
                    }
                    let conflict = ArchiveExtractionConflict(
                        existingURL: plan.finalURL,
                        incomingStagedURL: plan.stagedURL,
                        proposedFinalURL: plan.finalURL,
                        entryPath: plan.entry.path
                    )
                    decision = await onConflict(conflict)
                    cachedAskDecision = decision
                }
            }
            switch decision {
            case .overwrite:
                continue // merge into the existing directory
            case .keepBoth:
                let renamed = uniqueRenamedURL(for: plan.finalURL, fileManager: fileManager)
                plans[index].finalURL = renamed
                dirRemap.append((originalPath: dirPath, renamedURL: renamed))
            case .stop:
                throw ArchiveExtractionFinalizationError.userStoppedExtraction
            }
        }
        // Redirect every plan whose original finalURL is inside a renamed dir.
        if !dirRemap.isEmpty {
            let sortedRemap = dirRemap.sorted { $0.originalPath.count > $1.originalPath.count } // longest first, so nested dirs win
            for index in plans.indices {
                let path = plans[index].finalURL.standardizedFileURL.path
                guard let match = sortedRemap.first(where: { path.hasPrefix($0.originalPath + "/") }) else { continue }
                let suffix = String(path.dropFirst(match.originalPath.count)) // includes leading "/"
                plans[index].finalURL = match.renamedURL.standardizedFileURL.appendingPathComponent(String(suffix.dropFirst()))
            }
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
                // Resolve a file-name collision according to the strategy.
                let target = try await resolveFileConflictTarget(
                    for: plan,
                    existingIsDirectory: {
                        fileManager.fileExists(atPath: plan.finalURL.path, isDirectory: &isDirectory)
                        return isDirectory.boolValue
                    }(),
                    conflictStrategy: conflictStrategy,
                    onConflict: onConflict,
                    rollbackDirectory: rollbackDirectory,
                    fileManager: fileManager,
                    createRollbackDirectory: { () throws in
                        if !createdRollbackDirectory {
                            try fileManager.createDirectory(at: rollbackDirectory, withIntermediateDirectories: true)
                            createdRollbackDirectory = true
                        }
                    },
                    cachedAskDecision: &cachedAskDecision
                )
                rollbackActions.append(target.rollbackAction)
                try ensureSafeDestination(for: plan.entry.path, in: destinationURL)
                try fileManager.moveItem(at: plan.stagedURL, to: target.destinationURL)
                outputURLs.append(target.destinationURL)
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

    /// Resolved target for one file plan, bundling the destination URL and the
    /// rollback action to record for it.
    private struct ConflictTarget {
        let destinationURL: URL
        let rollbackAction: RollbackAction
    }

    /// Decides where to write a file entry when its final URL may already be
    /// occupied, and records the matching rollback action.  `existingIsDirectory`
    /// is the result of the `fileExists` probe (captured separately so the
    /// caller can branch on directory-vs-file).
    private static func resolveFileConflictTarget(
        for plan: MovePlan,
        existingIsDirectory: Bool,
        conflictStrategy: ArchiveExtractionConflictStrategy,
        onConflict: (@Sendable (ArchiveExtractionConflict) async -> ArchiveExtractionConflictDecision)?,
        rollbackDirectory: URL,
        fileManager: FileManager,
        createRollbackDirectory: () throws -> Void,
        cachedAskDecision: inout ArchiveExtractionConflictDecision?
    ) async throws -> ConflictTarget {
        guard fileManager.fileExists(atPath: plan.finalURL.path) else {
            // No collision: write to the proposed URL, remove it on failure.
            return ConflictTarget(destinationURL: plan.finalURL, rollbackAction: .remove(plan.finalURL))
        }
        guard !existingIsDirectory else {
            // Existing item is a directory — can't overwrite a file over a dir.
            throw ArchiveExtractionFinalizationError.unsafeDestinationPath(plan.entry.path)
        }

        switch conflictStrategy {
        case .overwrite:
            return try overwriteTarget(for: plan, rollbackDirectory: rollbackDirectory,
                                        fileManager: fileManager, createRollbackDirectory: createRollbackDirectory)
        case .rename:
            let renamed = uniqueRenamedURL(for: plan.finalURL, fileManager: fileManager)
            return ConflictTarget(destinationURL: renamed, rollbackAction: .remove(renamed))
        case .ask:
            let decision: ArchiveExtractionConflictDecision
            if let cached = cachedAskDecision {
                decision = cached
            } else {
                guard let onConflict else {
                    throw ArchiveExtractionFinalizationError.unsafeDestinationPath(plan.entry.path)
                }
                let conflict = ArchiveExtractionConflict(
                    existingURL: plan.finalURL,
                    incomingStagedURL: plan.stagedURL,
                    proposedFinalURL: plan.finalURL,
                    entryPath: plan.entry.path
                )
                decision = await onConflict(conflict)
                cachedAskDecision = decision
            }
            switch decision {
            case .overwrite:
                return try overwriteTarget(for: plan, rollbackDirectory: rollbackDirectory,
                                            fileManager: fileManager, createRollbackDirectory: createRollbackDirectory)
            case .keepBoth:
                let renamed = uniqueRenamedURL(for: plan.finalURL, fileManager: fileManager)
                return ConflictTarget(destinationURL: renamed, rollbackAction: .remove(renamed))
            case .stop:
                throw ArchiveExtractionFinalizationError.userStoppedExtraction
            }
        }
    }

    /// Backs up the existing file to the rollback directory and returns a
    /// target that overwrites it (rollback restores the original on failure).
    private static func overwriteTarget(
        for plan: MovePlan,
        rollbackDirectory: URL,
        fileManager: FileManager,
        createRollbackDirectory: () throws -> Void
    ) throws -> ConflictTarget {
        try createRollbackDirectory()
        let backup = rollbackDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.moveItem(at: plan.finalURL, to: backup)
        return ConflictTarget(destinationURL: plan.finalURL, rollbackAction: .restore(backup: backup, original: plan.finalURL))
    }

    /// Returns a Finder-style unique name that doesn't yet exist:
    /// `name.ext` → `name 2.ext` → `name 3.ext` … (and `name` → `name 2`).
    private static func uniqueRenamedURL(for proposedURL: URL, fileManager: FileManager) -> URL {
        let directory = proposedURL.deletingLastPathComponent()
        let baseName = proposedURL.deletingPathExtension().lastPathComponent
        let pathExtension = proposedURL.pathExtension
        var index = 2
        while true {
            let candidateName: String
            if pathExtension.isEmpty {
                candidateName = "\(baseName) \(index)"
            } else {
                candidateName = "\(baseName) \(index).\(pathExtension)"
            }
            let candidate = directory.appendingPathComponent(candidateName)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            index += 1
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
        let outputURLs = try await ArchiveExtractionFinalizer.finalize(
            entries: result.entries, from: tempDirectory, to: destinationURL,
            conflictStrategy: options.conflictStrategy, onConflict: options.onConflict)

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
