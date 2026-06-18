import Foundation
import CSevenZipBridge

public enum SevenZipEngineError: Error, Equatable, Sendable, LocalizedError {
    case binaryNotFound(searchedPaths: [String])
    case processLaunchFailed(String)
    case processFailed(exitCode: Int32, stderr: String)
    case unsupportedFormat(ArchiveFormat)
    case unsupportedEncryption
    case missingSources

    public var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return "7-Zip helper was not found."
        case .processLaunchFailed(let message):
            return message
        case .processFailed(_, let stderr):
            return stderr.isEmpty ? "7-Zip operation failed." : stderr
        case .unsupportedFormat(let format):
            return "Creating \(format.rawValue) archives is not supported by the 7-Zip backend."
        case .unsupportedEncryption:
            return "A password is required to encrypt file names."
        case .missingSources:
            return "Select at least one item to archive."
        }
    }
}

/// `SevenZipEngine` shells out to the official ip7z `7zz` (or legacy `7z`)
/// binary. It is the advanced backend for 7z-specific features that
/// libarchive cannot express — solid mode, custom dictionary sizes, split
/// volumes, archive comments, and header encryption.
///
/// Password-protected CLI operations pass the password over stdin so the
/// secret never appears in argv. Unencrypted list, test, and extract keep using
/// the vendored C bridge.
public struct SevenZipEngine: ArchiveEngine {
    public let type: ArchiveEngineType = .sevenZip
    public let executableURL: URL
    private let runner: SevenZipRunner
    private let progressRunner: SevenZipProgressRunner?
    private let listBridge: @Sendable (String) -> M7SevenZipEntryList
    private let testBridge: @Sendable (String) -> M7SevenZipEntryList
    private let extractBridge: @Sendable (String, String, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?, UnsafeMutablePointer<M7SevenZipExtractProgress>?) -> Int32
    private let freeEntryList: @Sendable (M7SevenZipEntryList) -> Void
    private let freeCString: @Sendable (UnsafeMutablePointer<CChar>?) -> Void

    public init(
        executableURL: URL? = nil,
        runner: SevenZipRunner? = nil,
        progressRunner: SevenZipProgressRunner? = nil,
        listBridge: (@Sendable (String) -> M7SevenZipEntryList)? = nil,
        testBridge: (@Sendable (String) -> M7SevenZipEntryList)? = nil,
        extractBridge: (@Sendable (String, String, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?, UnsafeMutablePointer<M7SevenZipExtractProgress>?) -> Int32)? = nil,
        freeEntryList: (@Sendable (M7SevenZipEntryList) -> Void)? = nil,
        freeCString: (@Sendable (UnsafeMutablePointer<CChar>?) -> Void)? = nil
    ) {
        self.executableURL = executableURL ?? SevenZipBinaryResolver.defaultURL()
        self.runner = runner ?? SevenZipDefaultRunner.run
        self.progressRunner = progressRunner
        self.listBridge = listBridge ?? { path in m7_7z_list(path) }
        self.testBridge = testBridge ?? { path in m7_7z_test(path) }
        self.extractBridge = extractBridge ?? { archive, destination, error, progress in
            Int32(m7_7z_extract(archive, destination, error, progress))
        }
        self.freeEntryList = freeEntryList ?? { list in m7_7z_entry_list_free(list) }
        self.freeCString = freeCString ?? { ptr in
            if let ptr { m7_7z_string_free(ptr) }
        }
    }

    // MARK: - List / Metadata

    public func listContents(of archiveURL: URL, options: ArchiveOperationOptions = ArchiveOperationOptions()) async throws -> [ArchiveEntry] {
        let archiveURL = Self.primaryVolumeURL(for: archiveURL)
        try checkCancellation(options)
        if let password = await password(for: archiveURL, operation: .listContents, provider: options.passwordProvider) {
            return try await listContentsWithCLI(of: archiveURL, password: password, options: options)
        }

        // Try in-process bridge first (fast, no subprocess).
        let bridgeList = listBridge(archiveURL.path)
        defer { freeEntryList(bridgeList) }
        try checkCancellation(options)
        if bridgeList.error == nil {
            return Self.makeEntries(from: bridgeList)
        }

        let message = String(cString: bridgeList.error!)

        // Bridge can't handle split volumes — fall back to CLI.
        if Self.looksBridgeLimitation(message),
               (try? ensureBinaryAvailable()) != nil {
            do {
                return try await listContentsViaCLI(archiveURL, password: nil, options: options)
            } catch {
                if Self.looksEncryptionRelated(String(describing: error)) {
                    throw SevenZipEngineError.processFailed(exitCode: 11, stderr: "encrypted")
                }
                throw error
            }
        }

        throw SevenZipEngineError.processFailed(exitCode: 11, stderr: message)
    }

    public func metadata(of archiveURL: URL, options: ArchiveOperationOptions = ArchiveOperationOptions()) async throws -> ArchiveMetadata {
        let archiveURL = Self.primaryVolumeURL(for: archiveURL)
        try checkCancellation(options)
        if let password = await password(for: archiveURL, operation: .metadata, provider: options.passwordProvider) {
            let entries = try await listContentsWithCLI(of: archiveURL, password: password, options: options)
            try checkCancellation(options)
            return ArchiveMetadata(
                format: .sevenZip,
                isEncrypted: entries.contains(where: \.isEncrypted),
                isMultiVolume: false,
                entriesCount: entries.count,
                uncompressedSize: entries.compactMap { $0.size }.reduce(0, +),
                compressedSize: ArchiveMetadata.compressedSize(from: entries, archiveURL: archiveURL)
            )
        }

        // Try bridge first.
        let bridgeList = listBridge(archiveURL.path)
        defer { freeEntryList(bridgeList) }

        if let error = bridgeList.error {
            let message = String(cString: error)
            if Self.looksEncryptionRelated(message) {
                return ArchiveMetadata(format: .sevenZip, isEncrypted: true)
            }
            // Try CLI fallback for split volumes etc.
            if Self.looksBridgeLimitation(message),
               (try? ensureBinaryAvailable()) != nil {
                do {
                    let entries = try await listContentsViaCLI(archiveURL, password: nil, options: options)
                    try checkCancellation(options)
                    return ArchiveMetadata(
                        format: .sevenZip,
                        isEncrypted: entries.contains(where: \.isEncrypted),
                        isMultiVolume: true,
                        entriesCount: entries.count,
                        uncompressedSize: entries.compactMap { $0.size }.reduce(0, +),
                        compressedSize: ArchiveMetadata.compressedSize(from: entries, archiveURL: archiveURL)
                    )
                } catch {
                    if Self.looksEncryptionRelated(String(describing: error)) {
                        return ArchiveMetadata(format: .sevenZip, isEncrypted: true, isMultiVolume: true)
                    }
                    throw SevenZipEngineError.processFailed(exitCode: 11, stderr: message)
                }
            }
            // Unknown bridge error — don't mask corruption or missing volumes.
            throw SevenZipEngineError.processFailed(exitCode: 11, stderr: message)
        }

        let entries = Self.makeEntries(from: bridgeList)
        try checkCancellation(options)
        return ArchiveMetadata(
            format: .sevenZip,
            comment: Self.extractComment(from: bridgeList),
            isEncrypted: bridgeList.isEncrypted,
            entriesCount: entries.count,
            uncompressedSize: entries.compactMap { $0.size }.reduce(0, +),
            compressedSize: ArchiveMetadata.compressedSize(from: entries, archiveURL: archiveURL)
        )
    }

    private static func extractComment(from bridgeList: M7SevenZipEntryList) -> String? {
        nil
    }

    // MARK: - Test

    public func testArchive(_ archiveURL: URL, options: ArchiveOperationOptions = ArchiveOperationOptions()) async throws -> ArchiveOperationResult {
        let archiveURL = Self.primaryVolumeURL(for: archiveURL)
        try checkCancellation(options)
        if let password = await password(for: archiveURL, operation: .testArchive, provider: options.passwordProvider) {
            return try await testArchiveWithCLI(archiveURL, password: password, options: options)
        }

        let bridgeList = testBridge(archiveURL.path)
        defer { freeEntryList(bridgeList) }
        try checkCancellation(options)
        if let error = bridgeList.error {
            let message = String(cString: error)
            // Try CLI fallback for split volumes etc.
            if Self.looksBridgeLimitation(message),
               (try? ensureBinaryAvailable()) != nil {
                return try await testArchiveWithCLI(archiveURL, password: "", options: options)
            }
            throw SevenZipEngineError.processFailed(exitCode: 11, stderr: message)
        }
        return ArchiveOperationResult(
            operation: .testArchive,
            archiveURL: archiveURL,
            entries: Self.makeEntries(from: bridgeList)
        )
    }

    // MARK: - Extract

    public func extract(_ archiveURL: URL, to destinationURL: URL, options: ArchiveOperationOptions = ArchiveOperationOptions()) async throws -> ArchiveOperationResult {
        let archiveURL = Self.primaryVolumeURL(for: archiveURL)
        try checkCancellation(options)
        let tempDirectory = try ArchiveExtractionFinalizer.makeStagingDirectory(for: destinationURL)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let result: ArchiveOperationResult
        if let password = await password(for: archiveURL, operation: .extract, provider: options.passwordProvider) {
            result = try await extractWithCLI(archiveURL, to: tempDirectory, password: password, options: options)
        } else {
            result = try await extractWithBridge(archiveURL, to: tempDirectory, options: options)
        }
        try checkCancellation(options)

        let outputURLs = try ArchiveExtractionFinalizer.finalize(
            entries: result.entries,
            from: tempDirectory,
            to: destinationURL
        )
        try checkCancellation(options)
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

    private func extractWithBridge(_ archiveURL: URL, to destinationURL: URL, options: ArchiveOperationOptions = ArchiveOperationOptions()) async throws -> ArchiveOperationResult {
        try checkCancellation(options)
        try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)

        let entries = try await listContents(of: archiveURL, options: options)
        let totalEntries = Int64(entries.count)
        for entry in entries {
            try checkCancellation(options)
            _ = try ArchivePathValidator.validatedOutputURL(for: entry.path, in: destinationURL)
        }

        let progressPtr = UnsafeMutablePointer<M7SevenZipExtractProgress>.allocate(capacity: 1)
        progressPtr.pointee = M7SevenZipExtractProgress(
            current: 0, cancel_flag: 0, total: totalEntries, skipped: 0, skipped_paths: nil
        )
        defer { progressPtr.deallocate() }

        // Monitor progress from the C bridge and forward to the caller.
        let reader = _SevenZipProgressReader(ptr: progressPtr)
        let monitor = Task { [handler = options.onExtractProgress, isCancelled = options.isCancelled, reader] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                if isCancelled?() == true {
                    reader.cancel()
                    break
                }
                handler?(reader.current, reader.total)
                if reader.current >= reader.total { break }
            }
        }

        var error: UnsafeMutablePointer<CChar>?
        let status = extractBridge(archiveURL.path, destinationURL.path, &error, progressPtr)
        monitor.cancel()
        await monitor.value
        defer { freeCString(error) }
        try checkCancellation(options)
        if status != 0, progressPtr.pointee.skipped == 0 {
            let message = error.map { String(cString: $0) } ?? "7-Zip extract failed"
            throw SevenZipEngineError.processFailed(exitCode: status, stderr: message)
        }

        let skipped = Int(progressPtr.pointee.skipped)
        var warnings: [String] = []
        var skippedEntries: [SkippedEntry] = []
        if skipped > 0 {
            if let cPath = progressPtr.pointee.skipped_paths {
                let paths = String(cString: cPath)
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .filter { !$0.isEmpty }
                for path in paths {
                    skippedEntries.append(SkippedEntry(
                        path: String(path),
                        reason: "Data corruption (CRC or decode error)"
                    ))
                }
                freeCString(cPath)
            }
            var detail = "Skipped \(skipped) corrupted file(s)"
            let fileNames = skippedEntries.map(\.path)
            if !fileNames.isEmpty {
                detail += ": " + fileNames.joined(separator: ", ")
            }
            warnings.append(detail)
        }

        let outputURLs: [URL] = entries.compactMap {
            try? ArchivePathValidator.validatedOutputURL(for: $0.path, in: destinationURL)
        }
        return ArchiveOperationResult(
            operation: .extract,
            archiveURL: archiveURL,
            destinationURL: destinationURL,
            entries: entries,
            outputURLs: outputURLs,
            warnings: warnings,
            skippedEntries: skippedEntries
        )
    }

    /// Bridging wrapper so the monitoring Task can read `M7SevenZipExtractProgress`
    /// without capturing the non-Sendable `UnsafeMutablePointer` directly.
    private final class _SevenZipProgressReader: @unchecked Sendable {
        private let ptr: UnsafeMutablePointer<M7SevenZipExtractProgress>
        init(ptr: UnsafeMutablePointer<M7SevenZipExtractProgress>) { self.ptr = ptr }
        var current: Int64 { ptr.pointee.current }
        var total: Int64 { ptr.pointee.total }
        func cancel() { ptr.pointee.cancel_flag = 1 }
    }

    // MARK: - Create

    public func createArchive(from sourceURLs: [URL], to archiveURL: URL, profile: CompressionProfile, password: String?, encryptionMethod: String?, options: ArchiveOperationOptions = ArchiveOperationOptions()) async throws -> ArchiveOperationResult {
        try checkCancellation(options)
        try ensureBinaryAvailable()

        let formatToken: String
        switch profile.format {
        case .sevenZip:
            formatToken = "7z"
        case .zip:
            formatToken = "zip"
        default:
            throw SevenZipEngineError.unsupportedFormat(profile.format)
        }

        let matcher = IgnoreRuleMatcher(rules: profile.ignoreRules)
        let filteredSources = sourceURLs.filter { !matcher.shouldIgnore($0) }
        guard !filteredSources.isEmpty else { throw SevenZipEngineError.missingSources }
        try checkCancellation(options)

        var arguments: [String] = ["a", "-y", "-bsp1", "-t\(formatToken)"]
        arguments.append("-mx\(profile.level.rawValue)")

        if profile.format == .sevenZip {
            switch profile.solid {
            case .some(true):  arguments.append("-ms=on")
            case .some(false): arguments.append("-ms=off")
            case .none:        break
            }
            if let dict = profile.dictionarySize {
                arguments.append("-md=\(Self.formatBytesAsMega(dict))")
            }
            if let method = profile.method, !method.isEmpty {
                arguments.append("-m0=\(method)")
            }
            if profile.encryptFileNames {
                arguments.append("-mhe=on")
            }
        }

        let passwordInput = password.flatMap { $0.isEmpty ? nil : $0 + "\n" }
        if passwordInput != nil {
            arguments.append("-p")
        } else if profile.encryptFileNames {
            throw SevenZipEngineError.unsupportedEncryption
        }

        if let volumeSize = profile.volumeSize {
            arguments.append("-v\(Self.formatBytesAsMega(volumeSize))")
        }

        arguments.append(contentsOf: Self.excludeArguments(for: profile.ignoreRules))

        arguments.append(archiveURL.path)
        arguments.append(contentsOf: filteredSources.map(\.path))

        let result: SevenZipProcessResult
        if let progressRunner {
            result = try await progressRunner(executableURL, arguments, passwordInput, options.onCreateProgress)
        } else {
            result = try await runner(executableURL, arguments, passwordInput)
        }
        try ensureSuccess(result)
        try checkCancellation(options)

        var outputURLs: [URL] = [archiveURL]
        var createdVolumes: [ArchiveVolumeInfo] = []
        if profile.volumeSize != nil {
            // 7zz writes split volumes as <archive>.001, <archive>.002, ...
            // Discover the actual files on disk so the result reflects
            // reality even if 7zz produced a different number of parts than
            // we expected.
            let parent = archiveURL.deletingLastPathComponent()
            let prefix = archiveURL.lastPathComponent + "."
            if let contents = try? FileManager.default.contentsOfDirectory(atPath: parent.path) {
                let volumeFiles = contents
                    .filter { $0.hasPrefix(prefix) }
                    .sorted()
                outputURLs = volumeFiles.map { parent.appendingPathComponent($0) }
                for (index, name) in volumeFiles.enumerated() {
                    try checkCancellation(options)
                    createdVolumes.append(ArchiveVolumeInfo(
                        index: index,
                        count: volumeFiles.count,
                        size: profile.volumeSize ?? 0,
                        fileName: name
                    ))
                }
            }
        }

        return ArchiveOperationResult(
            operation: .create,
            archiveURL: archiveURL,
            outputURLs: outputURLs,
            createdVolumes: createdVolumes
        )
    }

    // MARK: - Engine plumbing

    public func statusStream() async -> AsyncStream<ArchiveEngineStatus> {
        AsyncStream { continuation in
            continuation.yield(.idle)
            continuation.finish()
        }
    }

    public func cancel() async {}

    // MARK: - Helpers

    private static func primaryVolumeURL(for archiveURL: URL) -> URL {
        ArchiveTypeDetector.primarySevenZipVolumeURL(for: archiveURL)
    }

    private func checkCancellation(_ options: ArchiveOperationOptions) throws {
        if Task.isCancelled || options.isCancelled?() == true {
            throw CancellationError()
        }
    }

    private func listContentsWithCLI(of archiveURL: URL, password: String, options: ArchiveOperationOptions) async throws -> [ArchiveEntry] {
        try checkCancellation(options)
        try ensureBinaryAvailable()
        let result = try await runner(
            executableURL,
            ["l", archiveURL.path, "-slt", "-ba", "-y", "-bd"],
            password + "\n"
        )
        try ensureSuccess(result)
        try checkCancellation(options)
        return SevenZipListParser.parse(result.stdout).entries
    }

    /// List contents via 7zz CLI without a password. Used as fallback when the
    /// in-process bridge can't handle split volumes or other edge cases.
    private func listContentsViaCLI(_ archiveURL: URL, password: String?, options: ArchiveOperationOptions) async throws -> [ArchiveEntry] {
        try checkCancellation(options)
        try ensureBinaryAvailable()
        let stdinInput = password.map { $0 + "\n" } ?? "\n"
        let result = try await runner(
            executableURL,
            ["l", archiveURL.path, "-slt", "-ba", "-y", "-bd"],
            stdinInput
        )
        try ensureSuccess(result)
        try checkCancellation(options)
        return SevenZipListParser.parse(result.stdout).entries
    }

    private func testArchiveWithCLI(_ archiveURL: URL, password: String, options: ArchiveOperationOptions) async throws -> ArchiveOperationResult {
        try checkCancellation(options)
        try ensureBinaryAvailable()
        let result = try await runner(
            executableURL,
            ["t", archiveURL.path, "-y", "-bd"],
            password + "\n"
        )
        try ensureSuccess(result)
        try checkCancellation(options)
        return ArchiveOperationResult(
            operation: .testArchive,
            archiveURL: archiveURL,
            entries: try await listContentsWithCLI(of: archiveURL, password: password, options: options)
        )
    }

    private func extractWithCLI(_ archiveURL: URL, to destinationURL: URL, password: String, options: ArchiveOperationOptions) async throws -> ArchiveOperationResult {
        try checkCancellation(options)
        try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        let entries = try await listContentsWithCLI(of: archiveURL, password: password, options: options)
        for entry in entries {
            try checkCancellation(options)
            _ = try ArchivePathValidator.validatedOutputURL(for: entry.path, in: destinationURL)
        }

        let result = try await runner(
            executableURL,
            ["x", archiveURL.path, "-o\(destinationURL.path)", "-y", "-bd"],
            password + "\n"
        )
        try ensureSuccess(result)
        try checkCancellation(options)

        let outputURLs: [URL] = entries.compactMap {
            try? ArchivePathValidator.validatedOutputURL(for: $0.path, in: destinationURL)
        }
        return ArchiveOperationResult(
            operation: .extract,
            archiveURL: archiveURL,
            destinationURL: destinationURL,
            entries: entries,
            outputURLs: outputURLs
        )
    }

    private func password(for archiveURL: URL, operation: ArchiveOperation, provider: ArchivePasswordProvider?) async -> String? {
        guard let provider else { return nil }
        let request = ArchivePasswordRequest(
            archiveURL: archiveURL,
            operation: operation,
            attempt: 1,
            reason: .required
        )
        guard let password = await provider(request), !password.isEmpty else { return nil }
        return password
    }

    private func ensureBinaryAvailable() throws {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw SevenZipEngineError.binaryNotFound(
                searchedPaths: [executableURL.path] + SevenZipBinaryResolver.defaultCandidatePaths
            )
        }
    }

    private func ensureSuccess(_ result: SevenZipProcessResult) throws {
        if result.exitCode != 0 {
            // `-bsp1` (create path) leaves progress/carriage-return/backspace
            // bytes in stdout; strip them so error messages stay readable.
            let stderr = Self.stripProgressNoise(from: result.stderr)
            let stdout = Self.stripProgressNoise(from: result.stdout)
            let message = [stderr, stdout]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            throw SevenZipEngineError.processFailed(exitCode: result.exitCode, stderr: message)
        }
    }

    /// Removes 7-Zip `-bsp1` progress artifacts (backspace/carriage-return
    /// overwrite sequences and `NN%` tokens) from captured output so error
    /// messages stay readable.  Leaves normal log lines intact.
    private static func stripProgressNoise(from string: String) -> String {
        // Drop `NN%` tokens first, then collapse runs of backspace/\r that
        // the percentage indicator used to overwrite the line.
        guard let regex = try? NSRegularExpression(pattern: #"\s*\d{1,3}%"#) else { return string }
        let stripped = regex.stringByReplacingMatches(
            in: string,
            range: NSRange(string.startIndex..., in: string),
            withTemplate: ""
        )
        // Replace backspace sequences (a char followed by one or more \b) and
        // lone carriage returns with nothing, then trim trailing whitespace.
        let bsScrubbed = stripped
            .replacingOccurrences(of: "\u{08}", with: "")
            .replacingOccurrences(of: "\r", with: "")
        return bsScrubbed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func excludeArguments(for rules: [IgnoreRule]) -> [String] {
        rules.compactMap { rule in
            guard rule.isEnabled, !rule.pattern.isEmpty else { return nil }
            switch rule.scope {
            case .all:
                return "-xr!\(rule.pattern)"
            case .files:
                return "-xr!\(rule.pattern)"
            case .directories:
                return "-xr!\(rule.pattern)/"
            }
        }
    }

    private static func looksEncryptionRelated(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("wrong password")
            || lower.contains("password is incorrect")
            || lower.contains("encrypted")
            || lower.contains("data error in encrypted")
            || lower.contains("decoder does not support this archive")
    }

    /// Returns true when the C bridge error is a known bridge limitation
    /// (e.g., split volumes) rather than a corrupt or unsupported archive.
    private static func looksBridgeLimitation(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("unexpected end")
            || lower.contains("cannot open file as archive")
            || lower.contains("is not 7z archive")
            || lower.contains("is not archive")
    }

    private static func makeEntries(from bridgeList: M7SevenZipEntryList) -> [ArchiveEntry] {
        let count = Int(bridgeList.count)
        guard let base = bridgeList.entries, count > 0 else { return [] }
        return (0..<count).map { index in
            let item = base[index]
            return ArchiveEntry(
                path: item.path != nil ? String(cString: item.path) : "",
                size: item.size >= 0 ? item.size : nil,
                packedSize: nil,
                modifiedAt: item.modifiedAt >= 0 ? Date(timeIntervalSince1970: TimeInterval(item.modifiedAt)) : nil,
                isDirectory: item.isDirectory,
                method: nil,
                isEncrypted: item.isEncrypted
            )
        }
    }

    private static func archiveFormat(from typeToken: String?) -> ArchiveFormat? {
        guard let token = typeToken?.lowercased() else { return nil }
        switch token {
        case "7z":   return .sevenZip
        case "zip":  return .zip
        case "rar":  return .rar
        case "tar":  return .tar
        case "gzip": return .gzip
        case "bzip2": return .bzip2
        case "xz":   return .xz
        default:     return nil
        }
    }

    /// 7zz expects `-md=` and `-v` in megabytes (or with `m`/`g` suffix).
    /// Convert raw bytes into the closest megabyte form to keep the argv
    /// string compact.
    private static func formatBytesAsMega(_ bytes: Int64) -> String {
        let mega = max(1, bytes / (1024 * 1024))
        return "\(mega)m"
    }
}
