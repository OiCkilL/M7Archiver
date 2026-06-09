import Foundation
import Observation
import ArchiveCore
import ArchivePresentation

/// Thread-safe boolean flag for cancel propagation to detached tasks.
/// Replaces the old pattern of capturing a snapshot of `@MainActor`
/// `isOperationCancelled` before entering a `Task.detached` block.
final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _isCancelled = false
    var isCancelled: Bool { lock.withLock { _isCancelled } }
    func cancel() { lock.withLock { _isCancelled = true } }
}

/// Owns the open-archive view-model state for one window: archive metadata,
/// entry index, breadcrumb position, search query, encoding, selection,
/// lock/unlock state, and operation progress.
@MainActor
@Observable
public final class ArchiveSession {
    public enum LockState: Equatable, Sendable {
        case empty
        case unlocked
        case unlocking
        case locked(reason: ArchivePasswordReason)
        case failed(message: String, details: String? = nil)
    }

    public struct Progress: Equatable, Sendable {
        public var operation: ArchiveOperation
        public var fraction: Double?
        public var message: String

        public init(operation: ArchiveOperation, fraction: Double? = nil, message: String = "") {
            self.operation = operation
            self.fraction = fraction
            self.message = message
        }
    }

    public struct ExtractionResult: Equatable, Sendable {
        public let entryCount: Int
        public let skippedEntries: [SkippedEntry]
        public var hasWarnings: Bool { !skippedEntries.isEmpty }

        public init(entryCount: Int, skippedEntries: [SkippedEntry] = []) {
            self.entryCount = entryCount
            self.skippedEntries = skippedEntries
        }
    }

    private struct MaterializedEntries: Sendable {
        let count: Int
        let warnings: [String]
        let skippedEntries: [SkippedEntry]
    }

    public struct CompressionResult: Equatable, Sendable {
        public let originalSize: Int64
        public let compressedSize: Int64
        public let volumeCount: Int
        public var savingsPercent: Int {
            guard originalSize > 0 else { return 0 }
            let saved = originalSize - compressedSize
            guard saved > 0 else { return 0 }
            return Int((Double(saved) / Double(originalSize) * 100).rounded())
        }
        public init(originalSize: Int64, compressedSize: Int64, volumeCount: Int = 1) {
            self.originalSize = originalSize
            self.compressedSize = compressedSize
            self.volumeCount = volumeCount
        }
    }

    public enum ExtractionOutcome: Equatable, Sendable {
        case completed(destination: URL, result: ExtractionResult)
        case unsupportedBackend(ArchiveFormat)
        case locked
        case missingArchive
        case missingSelection
        case cancelled
        case failed(String)
    }

    public enum VerificationOutcome: Equatable, Sendable {
        case completed(details: [String])
        case failed(message: String, details: [String])
        case cancelled
        case missingArchive
        case locked
    }

    public enum CreationOutcome: Equatable, Sendable {
        case completed(outputURLs: [URL], createdVolumes: [ArchiveVolumeInfo])
        case failed(String)
        case missingSelection
    }

    // Archive identity
    public private(set) var archiveURL: URL?
    public private(set) var metadata: ArchiveMetadata?
    public private(set) var entries: [ArchiveEntry] = []
    public private(set) var lockState: LockState = .empty
    public private(set) var progress: Progress?
    /// Thread-safe cancel flag for the currently running operation.
    /// Replaced at the start of each extract/verify/create operation.
    private var currentCancellationFlag: CancellationFlag?

    /// File URL that `cancelCurrentOperation()` may delete on cancel.
    /// Only set when the current create operation owns a temporary output path.
    private var operationOutputURL: URL?

    // Extraction result
    public var lastExtractionResult: ExtractionResult?
    public var compressionResult: CompressionResult?

    /// Closure stored when an operation fails with a permission error.
    /// Called by the Grant Access & Retry flow after the user selects a folder.
    @ObservationIgnored public var retryOperation: (() async -> Void)?

    /// Security-scoped URL granted by the user via NSOpenPanel.
    /// Must call `stopAccessingSecurityScopedResource()` when clearing.
    public var grantedFolderURL: URL? {
        willSet { stopAccessingGrantedFolder() }
    }

    // Browsing / view state
    public var currentPath: [String] = []
    public var selection: Set<ArchiveRow.ID> = []
    public var searchQuery: String = ""
    public var encoding: ArchiveEncoding
    public var inspectorVisible: Bool = false

    public private(set) var defaultEncoding: ArchiveEncoding
    private var automaticEncodingPriority: [ArchiveEncoding]
    private var usesAutomaticEncodingDetection: Bool

    // Internal
    private var pendingPassword: String?
    private let engineSelector: ArchiveEngineSelector
    private let detector: ArchiveTypeDetector
    private let engineResolver: (ArchiveFormat, Set<ArchiveCapability>) throws -> any ArchiveEngine

    public init(
        defaultEncoding: ArchiveEncoding = .automatic,
        automaticEncodingPriority: [ArchiveEncoding] = ArchiveEncoding.defaultAutomaticDetectionPriority,
        engineSelector: ArchiveEngineSelector = ArchiveEngineSelector(),
        detector: ArchiveTypeDetector = ArchiveTypeDetector()
    ) {
        self.defaultEncoding = defaultEncoding
        self.encoding = defaultEncoding
        self.automaticEncodingPriority = ArchiveEncoding.automaticDetectionCandidates(in: automaticEncodingPriority)
        self.usesAutomaticEncodingDetection = defaultEncoding == .automatic
        self.engineSelector = engineSelector
        self.detector = detector
        self.engineResolver = { format, requestedCapabilities in
            try engineSelector.makeEngine(for: format, requestedCapabilities: requestedCapabilities)
        }
    }

    init(
        defaultEncoding: ArchiveEncoding = .automatic,
        automaticEncodingPriority: [ArchiveEncoding] = ArchiveEncoding.defaultAutomaticDetectionPriority,
        engineSelector: ArchiveEngineSelector = ArchiveEngineSelector(),
        detector: ArchiveTypeDetector = ArchiveTypeDetector(),
        engineResolver: @escaping (ArchiveFormat, Set<ArchiveCapability>) throws -> any ArchiveEngine
    ) {
        self.defaultEncoding = defaultEncoding
        self.encoding = defaultEncoding
        self.automaticEncodingPriority = ArchiveEncoding.automaticDetectionCandidates(in: automaticEncodingPriority)
        self.usesAutomaticEncodingDetection = defaultEncoding == .automatic
        self.engineSelector = engineSelector
        self.detector = detector
        self.engineResolver = engineResolver
    }

    // MARK: - Public API

    public var isLocked: Bool {
        switch lockState {
        case .locked, .unlocking: return true
        default: return false
        }
    }

    public var shouldStopMultiFileOperation: Bool {
        switch lockState {
        case .locked, .unlocking, .failed: return true
        default: return false
        }
    }

    public var hasArchive: Bool { archiveURL != nil }

    public var displayName: String {
        archiveURL?.lastPathComponent ?? "M7Archiver"
    }

    func applyFailedStateForTesting(_ message: String) {
        lockState = .failed(message: message)
    }

    public func open(url: URL) async {
        archiveURL = url
        metadata = nil
        entries = []
        currentPath = []
        selection = []
        searchQuery = ""
        encoding = defaultEncoding
        usesAutomaticEncodingDetection = defaultEncoding == .automatic
        pendingPassword = nil
        lockState = .unlocking
        await reload()
    }

    public func unlock(password: String) async {
        guard archiveURL != nil else { return }
        pendingPassword = password
        lockState = .unlocking
        await reload()
    }

    public func clear() {
        archiveURL = nil
        metadata = nil
        entries = []
        currentPath = []
        selection = []
        searchQuery = ""
        encoding = defaultEncoding
        usesAutomaticEncodingDetection = defaultEncoding == .automatic
        pendingPassword = nil
        progress = nil
        permissionError = nil
        retryOperation = nil
        grantedFolderURL = nil
        lockState = .empty
    }

    public func descend(into directoryName: String) {
        guard !directoryName.isEmpty, directoryName != ".." else { return }
        currentPath.append(directoryName)
        selection.removeAll()
    }

    public func goUp() {
        guard !currentPath.isEmpty else { return }
        currentPath.removeLast()
        selection.removeAll()
    }

    public func navigate(to path: [String]) {
        currentPath = path
        selection.removeAll()
    }

    public func cancelCurrentOperation() {
        currentCancellationFlag?.cancel()
        progress = nil
        if let url = operationOutputURL {
            try? FileManager.default.removeItem(at: url)
            operationOutputURL = nil
        }
    }

    public var verifyResult: VerifyResult?
    public var operationError: String?
    public struct ArchivePermissionError: Equatable, Sendable {
        public let path: URL
        public let message: String
        public init(path: URL, message: String) {
            self.path = path
            self.message = message
        }
    }

    public var permissionError: ArchivePermissionError?

    /// Clear the permission error. Keeps `grantedFolderURL` alive so the
    /// next operation can use the scoped access. Does NOT stop accessing.
    public func clearPermissionError() {
        permissionError = nil
        retryOperation = nil
    }

    /// Dismiss the permission error and release the scoped access.
    /// Call this when the user explicitly dismisses the error (X button),
    /// NOT when retrying.
    public func dismissPermissionError() {
        permissionError = nil
        retryOperation = nil
        grantedFolderURL = nil
    }

    public func resolvePermissionError(with grantedURL: URL) async {
        let retry = retryOperation
        _ = grantedURL.startAccessingSecurityScopedResource()
        grantedFolderURL = grantedURL

        do {
            try Self.restoreOwnerWritePermissionIfNeeded(for: grantedURL)
            if let deniedURL = permissionError?.path,
               deniedURL.standardizedFileURL != grantedURL.standardizedFileURL {
                try Self.restoreOwnerWritePermissionIfNeeded(for: deniedURL)
            }
        } catch {
            let message = Self.message(for: error)
            permissionError = ArchivePermissionError(path: grantedURL, message: message)
            operationError = message
            return
        }

        permissionError = nil
        operationError = nil
        await retry?()
        if permissionError == nil {
            retryOperation = nil
        }
    }

    /// Stops accessing the previously granted security-scoped folder.
    /// Does NOT nil out `grantedFolderURL` — the property's `willSet` observer
    /// calls this before the new value is stored, so setting `grantedFolderURL`
    /// to `nil` here would trigger infinite recursion.
    private func stopAccessingGrantedFolder() {
        if let url = grantedFolderURL {
            url.stopAccessingSecurityScopedResource()
        }
    }

    public struct VerifyResult: Equatable { let success: Bool; let details: [String] }

    public func setEncoding(_ encoding: ArchiveEncoding) {
        guard self.encoding != encoding || usesAutomaticEncodingDetection != (encoding == .automatic) else { return }
        usesAutomaticEncodingDetection = encoding == .automatic
        self.encoding = encoding
        Task { await reload() }
    }

    public func applyDefaultEncoding(_ encoding: ArchiveEncoding) {
        let previous = defaultEncoding
        defaultEncoding = encoding

        let followsPreviousDefault = usesAutomaticEncodingDetection
            ? previous == .automatic
            : self.encoding == previous
        guard !hasArchive || followsPreviousDefault else { return }

        if hasArchive {
            setEncoding(encoding)
        } else {
            usesAutomaticEncodingDetection = encoding == .automatic
            self.encoding = encoding
        }
    }

    func applyAutomaticEncodingPriority(_ priority: [ArchiveEncoding]) {
        let normalized = ArchiveEncoding.automaticDetectionCandidates(in: priority)
        guard automaticEncodingPriority != normalized else { return }
        automaticEncodingPriority = normalized
        if hasArchive, usesAutomaticEncodingDetection {
            Task { await reload() }
        }
    }

    private var operationEncoding: ArchiveEncoding? {
        usesAutomaticEncodingDetection ? nil : encoding
    }

    private var operationAutomaticEncodingPriority: [ArchiveEncoding]? {
        usesAutomaticEncodingDetection ? automaticEncodingPriority : nil
    }

    // MARK: - Extraction

    /// Extract the currently open archive into `destinationFolder`. The folder
    /// is created if it does not exist. Caller is responsible for any
    /// security-scope handling on the destination.
    ///
    /// Routing follows `ArchiveEngineSelector`: libarchive handles the
    /// common formats in-process, `SevenZipEngine` handles 7z paths that
    /// need the official ip7z CLI, and the placeholder external RAR engine
    /// is rejected up front so we never silently produce empty output.
    public func extract(to destinationFolder: URL) async -> ExtractionOutcome {
        guard let archiveURL else {
            operationError = "No archive is open."
            return .missingArchive
        }

        switch lockState {
        case .empty:
            operationError = "No archive is open."
            return .missingArchive
        case .locked, .unlocking:
            operationError = "Unlock the archive before extracting files."
            return .locked
        case .failed(message: let message, details: _):
            operationError = message
            return .failed(message)
        case .unlocked:
            break
        }

        // Clear previous extraction warnings
        lastExtractionResult = nil

        let format = metadata?.format ?? ((try? detector.detect(fileURL: archiveURL)) ?? .zip)

        let engine: any ArchiveEngine
        do {
            engine = try engineResolver(format, [.extractFiles])
        } catch {
            operationError = "\(format.displayLabel) extraction is not available with the current backend."
            return .unsupportedBackend(format)
        }

        if engine.type == .externalRar {
            operationError = "\(format.displayLabel) extraction is not available with the current backend."
            return .unsupportedBackend(format)
        }

        // Reset previous results
        lastExtractionResult = nil
        operationError = nil
        permissionError = nil
        verifyResult = nil

        progress = Progress(operation: .extract, fraction: nil, message: "Extracting…")

        let pending = pendingPassword
        let encodingValue = operationEncoding
        let automaticEncodingPriorityValue = operationAutomaticEncodingPriority
        let archiveURLCopy = archiveURL
        let destinationCopy = destinationFolder

        let cancelFlag = CancellationFlag()
        currentCancellationFlag = cancelFlag
        do {
            let task = Task.detached(priority: .userInitiated) { () -> ArchiveOperationResult in
                let provider: ArchivePasswordProvider?
                if let pending {
                    provider = { _ in pending }
                } else {
                    provider = nil
                }
                let options = ArchiveOperationOptions(
                    passwordProvider: provider,
                    requestedCapabilities: [.extractFiles],
                    encoding: encodingValue,
                    automaticEncodingPriority: automaticEncodingPriorityValue,
                    isCancelled: { cancelFlag.isCancelled || Task.isCancelled },
                    onExtractProgress: { [weak self] current, total in
                        Task { @MainActor in
                            self?.progress = Progress(
                                operation: .extract,
                                fraction: total > 0 ? Double(current) / Double(total) : nil,
                                message: "Extracting… (\(current)/\(total))"
                            )
                        }
                    }
                )
                return try await engine.extract(archiveURLCopy, to: destinationCopy, options: options)
            }
            let result = try await withTaskCancellationHandler(operation: {
                try await task.value
            }, onCancel: {
                task.cancel()
            })

            progress = nil

            if cancelFlag.isCancelled {
                return .cancelled
            }
            let extractResult = ExtractionResult(
                entryCount: result.entries.count,
                skippedEntries: result.skippedEntries
            )
            if extractResult.hasWarnings {
                lastExtractionResult = extractResult
            }
            return .completed(destination: destinationCopy, result: extractResult)
        } catch {
            progress = nil
            if error is CancellationError || cancelFlag.isCancelled {
                return .cancelled
            }
            if let permError = Self.detectPermissionError(error, destination: destinationCopy) {
                permissionError = permError
                retryOperation = { [weak self] in
                    guard let self else { return }
                    _ = await self.extract(to: destinationCopy)
                }
            } else {
                operationError = Self.message(for: error)
            }
            return .failed(Self.message(for: error))
        }
    }

    public func extractSelected(to destinationFolder: URL) async -> ExtractionOutcome {
        guard archiveURL != nil else {
            operationError = "No archive is open."
            return .missingArchive
        }
        let paths = selectedEntryPaths()
        guard !paths.isEmpty else {
            operationError = "No files selected for extraction."
            return .missingSelection
        }
        return await extract(paths: Array(paths), to: destinationFolder)
    }

    /// Extracts a single entry by its archive path into `destinationFolder`.
    /// Does not touch UI `selection` — paths are passed explicitly.
    public func extractEntry(path: String, to destinationFolder: URL) async -> ExtractionOutcome {
        return await extract(paths: [path], to: destinationFolder)
    }

    /// Materializes a single archive entry into `destinationFolder` for
    /// preview-only consumers. Reuses the extraction engine and finalizer
    /// pipeline without mutating shared operation UI state.
    public func materializePreviewEntry(path: String, to destinationFolder: URL) async -> ExtractionOutcome {
        guard let archiveURL else {
            return .missingArchive
        }
        guard !path.isEmpty else {
            return .missingSelection
        }

        switch lockState {
        case .empty:
            return .missingArchive
        case .locked, .unlocking:
            return .locked
        case .failed(message: let message, details: _):
            return .failed(message)
        case .unlocked:
            break
        }

        let format = metadata?.format ?? ((try? detector.detect(fileURL: archiveURL)) ?? .zip)

        let engine: any ArchiveEngine
        do {
            engine = try engineResolver(format, [.extractFiles])
        } catch {
            return .unsupportedBackend(format)
        }

        if engine.type == .externalRar {
            return .unsupportedBackend(format)
        }

        guard let selectedEntry = entries.first(where: { $0.path == path && !$0.isDirectory }) else {
            return .missingSelection
        }

        let pending = pendingPassword
        let encodingValue = operationEncoding
        let automaticEncodingPriorityValue = operationAutomaticEncodingPriority
        let archiveURLCopy = archiveURL
        let destinationCopy = destinationFolder
        let selectedEntryCopy = selectedEntry
        let cancelFlag = CancellationFlag()

        do {
            let task = Task.detached(priority: .userInitiated) { () -> MaterializedEntries in
                try await Self.materializeEntries(
                    [selectedEntryCopy],
                    archiveURL: archiveURLCopy,
                    destination: destinationCopy,
                    engine: engine,
                    password: pending,
                    encoding: encodingValue,
                    automaticEncodingPriority: automaticEncodingPriorityValue,
                    cancelFlag: cancelFlag
                )
            }
            let extractResult = try await withTaskCancellationHandler(operation: {
                try await task.value
            }, onCancel: {
                cancelFlag.cancel()
                task.cancel()
            })

            if cancelFlag.isCancelled {
                return .cancelled
            }
            guard extractResult.count > 0 else { return .missingSelection }
            return .completed(
                destination: destinationCopy,
                result: ExtractionResult(
                    entryCount: extractResult.count,
                    skippedEntries: extractResult.skippedEntries
                )
            )
        } catch is CancellationError {
            return .cancelled
        } catch {
            if cancelFlag.isCancelled {
                return .cancelled
            }
            return .failed(Self.message(for: error))
        }
    }

    /// Core extraction for explicit paths. Does not read `selection`.
    private func extract(paths: [String], to destinationFolder: URL) async -> ExtractionOutcome {
        guard let archiveURL else {
            operationError = "No archive is open."
            return .missingArchive
        }
        guard !paths.isEmpty else {
            operationError = "No files selected for extraction."
            return .missingSelection
        }

        // Clear previous extraction warnings
        lastExtractionResult = nil

        switch lockState {
        case .empty:
            operationError = "No archive is open."
            return .missingArchive
        case .locked, .unlocking:
            operationError = "Unlock the archive before extracting files."
            return .locked
        case .failed(message: let message, details: _):
            operationError = message
            return .failed(message)
        case .unlocked: break
        }

        let format = metadata?.format ?? ((try? detector.detect(fileURL: archiveURL)) ?? .zip)

        let engine: any ArchiveEngine
        do {
            engine = try engineResolver(format, [.extractFiles])
        } catch {
            operationError = "\(format.displayLabel) extraction is not available with the current backend."
            return .unsupportedBackend(format)
        }

        if engine.type == .externalRar {
            operationError = "\(format.displayLabel) extraction is not available with the current backend."
            return .unsupportedBackend(format)
        }

        // Reset previous results
        lastExtractionResult = nil
        operationError = nil
        permissionError = nil
        verifyResult = nil

        progress = Progress(operation: .extract, fraction: nil, message: "Extracting…")

        let cancelFlag = CancellationFlag()
        currentCancellationFlag = cancelFlag

        let pending = pendingPassword
        let encodingValue = operationEncoding
        let automaticEncodingPriorityValue = operationAutomaticEncodingPriority
        let archiveURLCopy = archiveURL
        let destinationCopy = destinationFolder
        let pathsCopy = paths
        let entriesCopy = entries
        let selectedEntries = pathsCopy.compactMap { path in
            entriesCopy.first { $0.path == path }
        }

        do {
            let task = Task.detached(priority: .userInitiated) { () -> MaterializedEntries in
                try await Self.materializeEntries(
                    selectedEntries,
                    archiveURL: archiveURLCopy,
                    destination: destinationCopy,
                    engine: engine,
                    password: pending,
                    encoding: encodingValue,
                    automaticEncodingPriority: automaticEncodingPriorityValue,
                    cancelFlag: cancelFlag,
                    onExtractProgress: { [weak self] current, total in
                        Task { @MainActor in
                            self?.progress = Progress(
                                operation: .extract,
                                fraction: total > 0 ? Double(current) / Double(total) : nil,
                                message: "Extracting… (\(current)/\(total))"
                            )
                        }
                    }
                )
            }
            let extractResult = try await withTaskCancellationHandler(operation: {
                try await task.value
            }, onCancel: {
                task.cancel()
            })

            progress = nil
            guard extractResult.count > 0 else { return .missingSelection }
            let result = ExtractionResult(
                entryCount: extractResult.count,
                skippedEntries: extractResult.skippedEntries
            )
            lastExtractionResult = result
            return .completed(destination: destinationCopy, result: result)
        } catch {
            progress = nil
            if error is CancellationError || cancelFlag.isCancelled {
                return .cancelled
            }
            if let permError = Self.detectPermissionError(error, destination: destinationFolder) {
                permissionError = permError
                retryOperation = { [weak self] in
                    guard let self else { return }
                    _ = await self.extract(paths: pathsCopy, to: destinationCopy)
                }
            } else {
                operationError = Self.message(for: error)
            }
            return .failed(Self.message(for: error))
        }
    }

    private static func materializeEntries(
        _ entries: [ArchiveEntry],
        archiveURL: URL,
        destination: URL,
        engine: any ArchiveEngine,
        password: String?,
        encoding: ArchiveEncoding?,
        automaticEncodingPriority: [ArchiveEncoding]?,
        cancelFlag: CancellationFlag,
        onExtractProgress: (@Sendable (Int64, Int64) -> Void)? = nil
    ) async throws -> MaterializedEntries {
        let fileManager = FileManager.default
        let stagingRoot = try ArchiveExtractionFinalizer.makeStagingDirectory(for: destination)
        defer { try? fileManager.removeItem(at: stagingRoot) }

        let provider: ArchivePasswordProvider?
        if let password {
            provider = { _ in password }
        } else {
            provider = nil
        }
        let options = ArchiveOperationOptions(
            passwordProvider: provider,
            requestedCapabilities: [.extractFiles],
            encoding: encoding,
            automaticEncodingPriority: automaticEncodingPriority,
            isCancelled: { cancelFlag.isCancelled || Task.isCancelled },
            onExtractProgress: onExtractProgress
        )
        let result = try await engine.extract(archiveURL, to: stagingRoot, options: options)

        if cancelFlag.isCancelled || Task.isCancelled {
            throw CancellationError()
        }

        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        let outputURLs = try ArchiveExtractionFinalizer.finalize(
            entries: entries,
            from: stagingRoot,
            to: destination
        )

        return MaterializedEntries(
            count: outputURLs.count,
            warnings: result.warnings,
            skippedEntries: result.skippedEntries
        )
    }

    public func verifyCurrentArchive() async -> VerificationOutcome {
        guard let archiveURL else { return .missingArchive }

        switch lockState {
        case .empty:
            return .missingArchive
        case .locked, .unlocking:
            return .locked
        case .failed(message: let message, details: _):
            return .failed(message: message, details: [])
        case .unlocked:
            break
        }

        let format = metadata?.format ?? ((try? detector.detect(fileURL: archiveURL)) ?? .zip)
        let engine: any ArchiveEngine
        do {
            engine = try engineResolver(format, [.listContents])
        } catch {
            return .failed(message: "Cannot verify archive", details: [Self.message(for: error)])
        }

        // Reset previous results
        lastExtractionResult = nil
        operationError = nil
        permissionError = nil
        verifyResult = nil

        progress = Progress(operation: .testArchive, fraction: nil, message: "Verifying…")

        let cancelFlag = CancellationFlag()
        currentCancellationFlag = cancelFlag

        let pending = pendingPassword
        let encodingValue = operationEncoding
        let automaticEncodingPriorityValue = operationAutomaticEncodingPriority
        let archiveURLCopy = archiveURL

        do {
            let task = Task.detached(priority: .userInitiated) { () -> ArchiveOperationResult in
                let provider: ArchivePasswordProvider?
                if let pending {
                    provider = { _ in pending }
                } else {
                    provider = nil
                }
                let options = ArchiveOperationOptions(
                    passwordProvider: provider,
                    requestedCapabilities: [.listContents],
                    encoding: encodingValue,
                    automaticEncodingPriority: automaticEncodingPriorityValue,
                    isCancelled: { cancelFlag.isCancelled || Task.isCancelled }
                )
                return try await engine.testArchive(archiveURLCopy, options: options)
            }
            let result = try await withTaskCancellationHandler(operation: {
                try await task.value
            }, onCancel: {
                task.cancel()
            })
            progress = nil

            if cancelFlag.isCancelled { return .cancelled }

            var details = ["All files passed CRC checks"]
            if !result.warnings.isEmpty {
                details.append(contentsOf: result.warnings)
            } else {
                details.append("No corruption detected")
            }
            verifyResult = VerifyResult(success: true, details: details)
            return .completed(details: details)
        } catch {
            progress = nil
            if cancelFlag.isCancelled { return .cancelled }
            verifyResult = VerifyResult(success: false, details: [Self.message(for: error)])
            return .failed(message: "Verification failed", details: [Self.message(for: error)])
        }
    }

    public func createArchive(
        from sourceURLs: [URL],
        to archiveURL: URL,
        profile: CompressionProfile,
        password: String? = nil,
        encryptionMethod: String? = nil
    ) async -> CreationOutcome {
        guard !sourceURLs.isEmpty else { return .missingSelection }

        // Reset previous results
        lastExtractionResult = nil
        operationError = nil
        permissionError = nil
        verifyResult = nil

        progress = Progress(operation: .create, fraction: nil, message: "Creating archive…")

        let format = profile.format
        let engine: any ArchiveEngine
        do {
            let capabilities = ArchiveCreationService.requestedCapabilities(for: profile)
            engine = try engineResolver(format, capabilities)
        } catch {
            progress = nil
            return .failed(Self.message(for: error))
        }

        let sourceCopies = sourceURLs
        let archiveCopy = archiveURL
        let profileCopy = profile
        let passwordCopy = password
        let encryptionMethodCopy = encryptionMethod
        let fileManager = FileManager.default
        let ownedOperationOutputURL = fileManager.fileExists(atPath: archiveCopy.path)
            ? nil
            : archiveCopy

        let cancelFlag = CancellationFlag()
        currentCancellationFlag = cancelFlag
        self.operationOutputURL = ownedOperationOutputURL
        do {
            let task = Task.detached(priority: .userInitiated) { () -> ArchiveOperationResult in
                let options = ArchiveOperationOptions(isCancelled: { cancelFlag.isCancelled || Task.isCancelled })
                return try await engine.createArchive(
                    from: sourceCopies,
                    to: archiveCopy,
                    profile: profileCopy,
                    password: passwordCopy,
                    encryptionMethod: encryptionMethodCopy,
                    options: options
                )
            }
            let result = try await withTaskCancellationHandler(operation: {
                try await task.value
            }, onCancel: {
                task.cancel()
            })
            progress = nil
            self.operationOutputURL = nil

            if cancelFlag.isCancelled {
                if let ownedOperationOutputURL {
                    try? fileManager.removeItem(at: ownedOperationOutputURL)
                }
                return .failed("Cancelled")
            }

            // Compute compression savings stats
            let fm = FileManager.default
            let originalSize = sourceCopies.reduce(Int64(0)) { total, url in
                let attrs = try? fm.attributesOfItem(atPath: url.path)
                return total + ((attrs?[.size] as? Int64) ?? 0)
            }
            let compressedSize = result.outputURLs.reduce(Int64(0)) { total, url in
                let attrs = try? fm.attributesOfItem(atPath: url.path)
                return total + ((attrs?[.size] as? Int64) ?? 0)
            }
            compressionResult = CompressionResult(
                originalSize: originalSize,
                compressedSize: compressedSize,
                volumeCount: max(result.createdVolumes.count, 1)
            )

            return .completed(outputURLs: result.outputURLs, createdVolumes: result.createdVolumes)
        } catch {
            progress = nil
            self.operationOutputURL = nil
            if cancelFlag.isCancelled {
                if let ownedOperationOutputURL {
                    try? fileManager.removeItem(at: ownedOperationOutputURL)
                }
                return .failed("Cancelled")
            }
            if let ownedOperationOutputURL {
                try? fileManager.removeItem(at: ownedOperationOutputURL)
            }
            if let permError = Self.detectPermissionError(error, destination: archiveCopy) {
                permissionError = permError
                retryOperation = { [weak self] in
                    guard let self else { return }
                    _ = await self.createArchive(
                        from: sourceCopies,
                        to: archiveCopy,
                        profile: profileCopy,
                        password: passwordCopy,
                        encryptionMethod: encryptionMethodCopy
                    )
                }
            } else {
                operationError = Self.message(for: error)
            }
            return .failed(Self.message(for: error))
        }
    }

    private func selectedEntryPaths() -> Set<String> {
        guard !selection.isEmpty else { return [] }

        let entryPaths = Set(entries.map(\.path))
        var resolved = Set<String>()

        for id in selection {
            if entryPaths.contains(id) {
                if let entry = entries.first(where: { $0.path == id }) {
                    if entry.isDirectory {
                        resolved.formUnion(descendantEntryPaths(forDirectoryPath: id))
                    } else {
                        resolved.insert(id)
                    }
                }
                continue
            }

            resolved.formUnion(descendantEntryPaths(forDirectoryPath: id))
        }

        return resolved
    }

    private func descendantEntryPaths(forDirectoryPath directoryPath: String) -> Set<String> {
        let prefix = directoryPath.hasSuffix("/") ? directoryPath : directoryPath + "/"
        return Set(
            entries
                .filter { !$0.isDirectory && $0.path.hasPrefix(prefix) }
                .map(\.path)
        )
    }

    private func reload() async {
        guard let archiveURL else {
            lockState = .empty
            return
        }

        let pending = pendingPassword
        let encodingValue = operationEncoding
        let automaticEncodingPriorityValue = operationAutomaticEncodingPriority
        let format = (try? detector.detect(fileURL: archiveURL)) ?? .zip
        let cancelFlag = currentCancellationFlag

        do {
            let engine = try engineResolver(format, [.listContents])
            let task = Task.detached(priority: .userInitiated) { () -> (entries: [ArchiveEntry], metadata: ArchiveMetadata) in
                let provider: ArchivePasswordProvider?
                if let pending {
                    provider = { _ in pending }
                } else {
                    provider = nil
                }
                let options = ArchiveOperationOptions(
                    passwordProvider: provider,
                    requestedCapabilities: [.listContents],
                    encoding: encodingValue,
                    automaticEncodingPriority: automaticEncodingPriorityValue,
                    isCancelled: { cancelFlag?.isCancelled == true || Task.isCancelled }
                )
                let listed = try await engine.listContents(of: archiveURL, options: options)
                let metadata = try await engine.metadata(of: archiveURL, options: options)
                if metadata.isEncrypted, pending != nil {
                    _ = try await engine.testArchive(archiveURL, options: options)
                }
                return (listed, metadata)
            }
            let outcome = try await withTaskCancellationHandler(operation: {
                try await task.value
            }, onCancel: {
                task.cancel()
            })

            entries = outcome.entries
            metadata = outcome.metadata

            // Adopt auto-detected encoding so the UI badge reflects reality,
            // while keeping operations in Auto mode for subsequent extract/test.
            if usesAutomaticEncodingDetection {
                self.encoding = outcome.metadata.encoding ?? .automatic
            }

            if outcome.metadata.isEncrypted, pending == nil {
                lockState = .locked(reason: .required)
            } else {
                lockState = .unlocked
            }
        } catch {
            entries = []
            metadata = nil

            if pending != nil {
                if Self.errorLooksPasswordFailure(error) {
                    pendingPassword = nil
                    lockState = .locked(reason: .wrongPassword)
                } else {
                    lockState = .failed(message: Self.message(for: error), details: String(describing: error))
                }
            } else if Self.errorLooksEncryptionRelated(error) {
                lockState = .locked(reason: .required)
            } else {
                lockState = .failed(message: Self.message(for: error), details: String(describing: error))
            }
        }
    }

    private static func errorLooksPasswordFailure(_ error: Error) -> Bool {
        let text = String(describing: error).lowercased()
        return text.contains("wrong password")
            || text.contains("incorrect password")
            || text.contains("bad password")
            || text.contains("password is incorrect")
            || text.contains("passphrase is incorrect")
            || text.contains("incorrect passphrase")
    }

    private static func errorLooksEncryptionRelated(_ error: Error) -> Bool {
        let text = String(describing: error).lowercased()
        return text.contains("password")
            || text.contains("encrypt")
            || text.contains("crypt")
            || text.contains("passphrase")
            || text.contains("decoder does not support this archive")
    }

    private static func detectPermissionError(_ error: Error, destination: URL) -> ArchivePermissionError? {
        // Check typed NSError domain/code first
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain,
           nsError.code == NSFileWriteNoPermissionError {
            return ArchivePermissionError(path: destination, message: Self.message(for: error))
        }
        if nsError.domain == NSPOSIXErrorDomain,
           nsError.code == Int(EACCES) {
            return ArchivePermissionError(path: destination, message: Self.message(for: error))
        }
        // Fallback: string matching for engines that don't set NSError domain
        let text = String(describing: error).lowercased()
            .replacing("\u{2019}", with: "'") // normalize curly apostrophe
        if text.contains("permission denied") || text.contains("eacces") || text.contains("don't have permission") {
            return ArchivePermissionError(path: destination, message: Self.message(for: error))
        }
        return nil
    }

    private static func restoreOwnerWritePermissionIfNeeded(for url: URL) throws {
        let fileManager = FileManager.default
        let directory = existingDirectoryForPermissionRepair(url)
        guard fileManager.fileExists(atPath: directory.path) else { return }
        guard !fileManager.isWritableFile(atPath: directory.path) else { return }

        let attributes = try fileManager.attributesOfItem(atPath: directory.path)
        guard let current = attributes[.posixPermissions] as? NSNumber else {
            throw NSError(
                domain: NSCocoaErrorDomain,
                code: NSFileWriteNoPermissionError,
                userInfo: [NSFilePathErrorKey: directory.path]
            )
        }

        let repaired = current.intValue | 0o300
        if repaired != current.intValue {
            try fileManager.setAttributes([.posixPermissions: repaired], ofItemAtPath: directory.path)
        }

        guard fileManager.isWritableFile(atPath: directory.path) else {
            throw NSError(
                domain: NSCocoaErrorDomain,
                code: NSFileWriteNoPermissionError,
                userInfo: [NSFilePathErrorKey: directory.path]
            )
        }
    }

    private static func existingDirectoryForPermissionRepair(_ url: URL) -> URL {
        var isDirectory = ObjCBool(false)
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            return isDirectory.boolValue ? url : url.deletingLastPathComponent()
        }
        return url.deletingLastPathComponent()
    }

    public static func message(for error: Error) -> String {
        let text = String(describing: error)
        guard !text.isEmpty else { return "Operation failed." }
        
        // 1. 处理 7z 进程失败 (SevenZipProcessRunner.Error)
        // 典型格式: processFailed(exitCode: 2, stderr: "...ERROR: /path/to/file : message\nUnexpected end of archive")
        if text.contains("stderr: ") {
            if let stderrRange = text.range(of: "stderr: \"(.*?)\"", options: .regularExpression) {
                var stderr = String(text[stderrRange].dropFirst(9).dropLast())
                // 替换转义的换行符
                stderr = stderr.replacingOccurrences(of: "\\n", with: "\n")
                
                // 提取有意义的行
                let lines = stderr.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                
                // 常见的 7z 错误特征行
                let errorPatterns = [
                    "Unexpected end of archive",
                    "Can not open the file as archive",
                    "Is not archive",
                    "Wrong password",
                    "Data Error"
                ]
                
                for pattern in errorPatterns {
                    if stderr.contains(pattern) {
                        return translateInternalError(pattern)
                    }
                }
                
                // 如果没有匹配到特征，尝试找最后一行非空的错误信息，并移除路径
                if let lastErrorLine = lines.last(where: { $0.lowercased().contains("error:") }) {
                    if let colonIdx = lastErrorLine.range(of: ":", options: .backwards)?.upperBound {
                        return String(lastErrorLine[colonIdx...]).trimmingCharacters(in: .whitespaces)
                    }
                    return lastErrorLine
                }
            }
        }

        // 2. 尝试清理 Cocoa/POSIX 冗长的 Error Domain 信息
        if text.contains("Error Domain=") {
            let pattern = "\"(.*?)\""
            if let range = text.range(of: pattern, options: .regularExpression) {
                let quoted = text[range].dropFirst().dropLast()
                if !quoted.isEmpty {
                    return translateInternalError(String(quoted))
                }
            }
        }
        
        // 3. 移除常见的 UserInfo 噪音
        var cleaned = text
        if let idx = cleaned.range(of: "UserInfo=", options: .caseInsensitive)?.lowerBound {
            cleaned = String(cleaned[..<idx]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        return translateInternalError(cleaned)
    }

    private static func translateInternalError(_ original: String) -> String {
        let lower = original.lowercased()
        if lower.contains("unexpected end of archive") {
            return "The archive appears to be corrupted or incomplete."
        }
        if lower.contains("can not open the file as archive") || lower.contains("is not archive") {
            return "This file is not a supported archive or is severely corrupted."
        }
        if lower.contains("permission denied") {
            return "Access denied. Check your folder permissions."
        }
        if lower.contains("no such file") {
            return "The specified file or folder could not be found."
        }
        return original
    }
}
