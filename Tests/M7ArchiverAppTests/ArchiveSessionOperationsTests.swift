import Foundation
import XCTest
import ArchiveCore
@testable import M7ArchiverApp

final class ArchiveSessionOperationsTests: XCTestCase {
    @MainActor
    func testVerifyCurrentArchiveWithoutArchiveReturnsMissingArchive() async {
        let session = ArchiveSession()
        let outcome = await session.verifyCurrentArchive()
        XCTAssertEqual(outcome, .missingArchive)
    }

    @MainActor
    func testShouldStopMultiFileOperationIncludesFailureStates() {
        let session = ArchiveSession()
        XCTAssertFalse(session.shouldStopMultiFileOperation)

        session.applyFailedStateForTesting("bad archive")

        XCTAssertTrue(session.shouldStopMultiFileOperation)
    }

    @MainActor
    func testCreateArchiveWithoutSourcesReturnsMissingSelection() async {
        let session = ArchiveSession()
        let outcome = await session.createArchive(
            from: [],
            to: URL(fileURLWithPath: "/tmp/out.zip"),
            profile: CompressionProfile(name: "ZIP", format: .zip)
        )
        XCTAssertEqual(outcome, .missingSelection)
    }

    @MainActor
    func testVerifyPassesAutomaticEncodingPriorityToEngineOptions() async throws {
        let archive = try await makeSimpleZipArchive()
        let recorder = OperationOptionsRecorder()
        let engine = RecordingOptionsEngine(recorder: recorder)
        let session = ArchiveSession(
            automaticEncodingPriority: [.cp850, .cp437],
            engineResolver: { _, _ in engine }
        )

        await session.open(url: archive)
        XCTAssertEqual(session.lockState, .unlocked)

        let outcome = await session.verifyCurrentArchive()

        guard case .completed = outcome else {
            XCTFail("Expected verification to complete, got \(outcome)")
            return
        }
        XCTAssertEqual(
            recorder.values.last,
            RecordedOperationOptions(encoding: nil, automaticEncodingPriority: [.cp850, .cp437])
        )
    }

    @MainActor
    func testDetectedAutomaticEncodingDoesNotBecomeExplicitEncodingForLaterOperations() async throws {
        let archive = try await makeSimpleZipArchive()
        let recorder = OperationOptionsRecorder()
        let engine = RecordingOptionsEngine(recorder: recorder, metadataEncoding: .cp850)
        let session = ArchiveSession(
            automaticEncodingPriority: [.cp850, .cp437],
            engineResolver: { _, _ in engine }
        )

        await session.open(url: archive)
        XCTAssertEqual(session.lockState, .unlocked)
        XCTAssertEqual(session.encoding, .cp850)

        let outcome = await session.verifyCurrentArchive()

        guard case .completed = outcome else {
            XCTFail("Expected verification to complete, got \(outcome)")
            return
        }
        XCTAssertEqual(
            recorder.values.last,
            RecordedOperationOptions(encoding: nil, automaticEncodingPriority: [.cp850, .cp437])
        )
    }

    @MainActor
    func testExplicitEncodingDoesNotPassAutomaticEncodingPriorityToEngineOptions() async throws {
        let archive = try await makeSimpleZipArchive()
        let recorder = OperationOptionsRecorder()
        let engine = RecordingOptionsEngine(recorder: recorder)
        let session = ArchiveSession(
            defaultEncoding: .windows1252,
            automaticEncodingPriority: [.cp850, .cp437],
            engineResolver: { _, _ in engine }
        )

        await session.open(url: archive)
        XCTAssertEqual(session.lockState, .unlocked)

        let outcome = await session.verifyCurrentArchive()

        guard case .completed = outcome else {
            XCTFail("Expected verification to complete, got \(outcome)")
            return
        }
        XCTAssertEqual(
            recorder.values.last,
            RecordedOperationOptions(encoding: .windows1252, automaticEncodingPriority: nil)
        )
    }

    @MainActor
    func testCreateArchiveFailureDoesNotDeleteExistingDestinationFile() async throws {
        let fileManager = FileManager.default
        let workspace = fileManager.temporaryDirectory
            .appendingPathComponent("M7Archiver-session-create-failure-")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workspace) }

        let ignored = workspace.appendingPathComponent(".DS_Store")
        try Data("ignored".utf8).write(to: ignored)
        let existingArchive = workspace.appendingPathComponent("existing.zip")
        let originalData = Data("keep me".utf8)
        try originalData.write(to: existingArchive)

        let session = ArchiveSession()
        let profile = CompressionProfile(
            name: "ZIP",
            format: .zip,
            ignoreRules: IgnoreRule.defaultMacOSRules
        )
        let outcome = await session.createArchive(from: [ignored], to: existingArchive, profile: profile)

        guard case .failed = outcome else {
            XCTFail("Expected archive creation to fail, got \(outcome)")
            return
        }
        XCTAssertEqual(try Data(contentsOf: existingArchive), originalData)
    }

    @MainActor
    func testCancelCreateArchiveKeepsExistingDestinationFile() async throws {
        let fileManager = FileManager.default
        let workspace = fileManager.temporaryDirectory
            .appendingPathComponent("M7Archiver-session-create-cancel-")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workspace) }

        let source = workspace.appendingPathComponent("payload.txt")
        try Data("payload".utf8).write(to: source)
        let existingArchive = workspace.appendingPathComponent("existing.zip")
        let originalData = Data("keep me".utf8)
        try originalData.write(to: existingArchive)

        let createStarted = expectation(description: "create started")
        let engine = BlockingCreateEngine {
            createStarted.fulfill()
        }
        let session = ArchiveSession(engineResolver: { _, _ in engine })

        let createTask = Task { @MainActor in
            await session.createArchive(
                from: [source],
                to: existingArchive,
                profile: BuiltInCompressionProfiles.fastZIP
            )
        }

        await fulfillment(of: [createStarted], timeout: 1.0)
        session.cancelCurrentOperation()

        let outcome = await createTask.value
        XCTAssertEqual(outcome, .failed("Cancelled"))
        XCTAssertEqual(try Data(contentsOf: existingArchive), originalData)
    }

    @MainActor
    func testMaterializePreviewEntryUsesUnlockedPasswordWithoutMutatingOperationState() async throws {
        let fileManager = FileManager.default
        let workspace = fileManager.temporaryDirectory
            .appendingPathComponent("M7Archiver-session-preview-")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workspace) }

        let source = workspace.appendingPathComponent("locked.txt")
        try Data("locked-preview".utf8).write(to: source)
        let archive = workspace.appendingPathComponent("locked.zip")
        let creator = ArchiveSession()
        let creation = await creator.createArchive(
            from: [source],
            to: archive,
            profile: BuiltInCompressionProfiles.fastZIP,
            password: "s3cret"
        )
        guard case .completed = creation else {
            XCTFail("Expected encrypted ZIP creation to complete, got \(creation)")
            return
        }

        let session = ArchiveSession()
        await session.open(url: archive)
        XCTAssertEqual(session.lockState, .locked(reason: .required))

        await session.unlock(password: "s3cret")
        XCTAssertEqual(session.lockState, .unlocked)

        let preservedPermissionError = ArchiveSession.ArchivePermissionError(path: workspace, message: "keep permission")
        let preservedExtractionResult = ArchiveSession.ExtractionResult(
            entryCount: 3,
            skippedEntries: [SkippedEntry(path: "old.txt", reason: "keep")]
        )
        let preservedVerifyResult = ArchiveSession.VerifyResult(success: false, details: ["keep verify"])

        session.operationError = "keep error"
        session.permissionError = preservedPermissionError
        session.retryOperation = {}
        session.lastExtractionResult = preservedExtractionResult
        session.verifyResult = preservedVerifyResult

        let previewRoot = workspace.appendingPathComponent("preview", isDirectory: true)
        let outcome = await session.materializePreviewEntry(path: "locked.txt", to: previewRoot)

        XCTAssertEqual(
            outcome,
            .completed(destination: previewRoot, result: ArchiveSession.ExtractionResult(entryCount: 1))
        )
        let materialized = try Data(contentsOf: previewRoot.appendingPathComponent("locked.txt"))
        XCTAssertEqual(String(decoding: materialized, as: UTF8.self), "locked-preview")
        XCTAssertNil(session.progress)
        XCTAssertEqual(session.operationError, "keep error")
        XCTAssertEqual(session.permissionError, preservedPermissionError)
        XCTAssertNotNil(session.retryOperation)
        XCTAssertEqual(session.lastExtractionResult, preservedExtractionResult)
        XCTAssertEqual(session.verifyResult, preservedVerifyResult)
    }

    @MainActor
    func testMaterializePreviewEntryCancellationReturnsCancelledAndKeepsSessionQuiet() async throws {
        let fileManager = FileManager.default
        let workspace = fileManager.temporaryDirectory
            .appendingPathComponent("M7Archiver-session-preview-")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workspace) }

        let source = workspace.appendingPathComponent("payload.txt")
        try Data("real payload".utf8).write(to: source)
        let archive = workspace.appendingPathComponent("payload.zip")
        let creator = ArchiveSession()
        let creation = await creator.createArchive(
            from: [source],
            to: archive,
            profile: BuiltInCompressionProfiles.fastZIP
        )
        guard case .completed = creation else {
            XCTFail("Expected ZIP creation to complete, got \(creation)")
            return
        }

        let extractionStarted = expectation(description: "preview extraction started")
        let gate = BlockingPreviewGate()
        let engine = BlockingPreviewEngine(
            materializedEntryPath: "payload.txt",
            materializedContents: Data("preview payload".utf8),
            gate: gate,
            onExtractStart: { _ in
                extractionStarted.fulfill()
            }
        )
        let session = ArchiveSession(engineResolver: { _, _ in engine })
        await session.open(url: archive)
        XCTAssertEqual(session.lockState, .unlocked)

        let previewRoot = workspace.appendingPathComponent("preview", isDirectory: true)
        let previewTask = Task {
            await session.materializePreviewEntry(path: "payload.txt", to: previewRoot)
        }

        await fulfillment(of: [extractionStarted], timeout: 1.0)
        XCTAssertNil(session.progress)

        previewTask.cancel()
        await gate.release()
        let result = await previewTask.value

        XCTAssertEqual(result, .cancelled)
        XCTAssertNil(session.progress)
        XCTAssertFalse(fileManager.fileExists(atPath: previewRoot.appendingPathComponent("payload.txt").path))
    }

    @MainActor
    func testMaterializePreviewEntryForDirectoryReturnsMissingSelectionWithoutCreatingPreviewRoot() async throws {
        let fileManager = FileManager.default
        let workspace = fileManager.temporaryDirectory
            .appendingPathComponent("M7Archiver-session-preview-")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workspace) }

        let directory = workspace.appendingPathComponent("nested", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("a".utf8).write(to: directory.appendingPathComponent("a.txt"))
        let archive = workspace.appendingPathComponent("payload.zip")
        let creator = ArchiveSession()
        let creation = await creator.createArchive(
            from: [directory],
            to: archive,
            profile: BuiltInCompressionProfiles.fastZIP
        )
        guard case .completed = creation else {
            XCTFail("Expected ZIP creation to complete, got \(creation)")
            return
        }

        let session = ArchiveSession()
        await session.open(url: archive)
        XCTAssertEqual(session.lockState, .unlocked)

        let previewRoot = workspace.appendingPathComponent("preview", isDirectory: true)
        let outcome = await session.materializePreviewEntry(path: "nested", to: previewRoot)

        XCTAssertEqual(outcome, .missingSelection)
        XCTAssertFalse(fileManager.fileExists(atPath: previewRoot.path))
        XCTAssertNil(session.progress)
    }

    @MainActor
    func testMaterializePreviewEntryWhileLockedReturnsLockedWithoutMutatingOperationState() async throws {
        let fileManager = FileManager.default
        let workspace = fileManager.temporaryDirectory
            .appendingPathComponent("M7Archiver-session-preview-")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workspace) }

        let source = workspace.appendingPathComponent("locked.txt")
        try Data("locked-preview".utf8).write(to: source)
        let archive = workspace.appendingPathComponent("locked.zip")
        let creator = ArchiveSession()
        let creation = await creator.createArchive(
            from: [source],
            to: archive,
            profile: BuiltInCompressionProfiles.fastZIP,
            password: "s3cret"
        )
        guard case .completed = creation else {
            XCTFail("Expected encrypted ZIP creation to complete, got \(creation)")
            return
        }

        let session = ArchiveSession()
        await session.open(url: archive)
        XCTAssertEqual(session.lockState, .locked(reason: .required))

        let preservedPermissionError = ArchiveSession.ArchivePermissionError(path: workspace, message: "keep permission")
        let preservedExtractionResult = ArchiveSession.ExtractionResult(
            entryCount: 3,
            skippedEntries: [SkippedEntry(path: "old.txt", reason: "keep")]
        )
        let preservedVerifyResult = ArchiveSession.VerifyResult(success: false, details: ["keep verify"])

        session.operationError = "keep error"
        session.permissionError = preservedPermissionError
        session.retryOperation = {}
        session.lastExtractionResult = preservedExtractionResult
        session.verifyResult = preservedVerifyResult

        let previewRoot = workspace.appendingPathComponent("preview", isDirectory: true)
        let outcome = await session.materializePreviewEntry(path: "locked.txt", to: previewRoot)

        XCTAssertEqual(outcome, .locked)
        XCTAssertNil(session.progress)
        XCTAssertEqual(session.operationError, "keep error")
        XCTAssertEqual(session.permissionError, preservedPermissionError)
        XCTAssertNotNil(session.retryOperation)
        XCTAssertEqual(session.lastExtractionResult, preservedExtractionResult)
        XCTAssertEqual(session.verifyResult, preservedVerifyResult)
        XCTAssertFalse(fileManager.fileExists(atPath: previewRoot.appendingPathComponent("locked.txt").path))
    }

    @MainActor
    func testSessionUnlocksEncryptedZipWithCorrectPassword() async throws {
        let fileManager = FileManager.default
        let workspace = fileManager.temporaryDirectory
            .appendingPathComponent("M7Archiver-session-zip-")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workspace) }

        let source = workspace.appendingPathComponent("locked.txt")
        try Data("locked-zip".utf8).write(to: source)
        let archive = workspace.appendingPathComponent("locked.zip")
        let creator = ArchiveSession()
        let creation = await creator.createArchive(
            from: [source],
            to: archive,
            profile: BuiltInCompressionProfiles.fastZIP,
            password: "s3cret"
        )
        guard case .completed = creation else {
            XCTFail("Expected encrypted ZIP creation to complete, got \(creation)")
            return
        }

        let session = ArchiveSession()
        await session.open(url: archive)
        XCTAssertEqual(session.lockState, .locked(reason: .required))
        XCTAssertEqual(session.entries.map(\.path), ["locked.txt"])

        await session.unlock(password: "wrong")
        XCTAssertEqual(session.lockState, .locked(reason: .wrongPassword))

        await session.unlock(password: "s3cret")
        XCTAssertEqual(session.lockState, .unlocked)
        XCTAssertEqual(session.entries.map(\.path), ["locked.txt"])
        XCTAssertEqual(session.metadata?.format, .zip)
        XCTAssertTrue(session.metadata?.isEncrypted == true)

        let out = workspace.appendingPathComponent("out", isDirectory: true)
        let extraction = await session.extract(to: out)
        XCTAssertEqual(extraction, .completed(destination: out, result: ArchiveSession.ExtractionResult(entryCount: 1)))
        let extracted = try Data(contentsOf: out.appendingPathComponent("locked.txt"))
        XCTAssertEqual(String(decoding: extracted, as: UTF8.self), "locked-zip")

        let verification = await session.verifyCurrentArchive()
        guard case .completed = verification else {
            XCTFail("Expected verify to complete after unlock, got \(verification)")
            return
        }
    }

    @MainActor
    func testSessionUsesSavedPasswordForEncryptedZip() async throws {
        let fileManager = FileManager.default
        let workspace = fileManager.temporaryDirectory
            .appendingPathComponent("M7Archiver-session-zip-")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workspace) }

        let source = workspace.appendingPathComponent("saved.txt")
        try Data("saved-zip".utf8).write(to: source)
        let archive = workspace.appendingPathComponent("saved.zip")
        let creator = ArchiveSession()
        let creation = await creator.createArchive(
            from: [source],
            to: archive,
            profile: BuiltInCompressionProfiles.fastZIP,
            password: "s3cret"
        )
        guard case .completed = creation else {
            XCTFail("Expected encrypted ZIP creation to complete, got \(creation)")
            return
        }

        let store = SavedPasswordsStore(backend: InMemorySavedPasswordsBackend())
        store.save(password: "s3cret", for: archive)
        let session = ArchiveSession()

        await openSessionWithSavedPassword(session: session, savedPasswords: store, archiveURL: archive)

        XCTAssertEqual(session.lockState, .unlocked)
        XCTAssertEqual(session.entries.map(\.path), ["saved.txt"])
        XCTAssertEqual(store.lookup(for: archive), "s3cret")
    }

    @MainActor
    func testSessionDeletesWrongSavedPasswordForEncryptedZip() async throws {
        let fileManager = FileManager.default
        let workspace = fileManager.temporaryDirectory
            .appendingPathComponent("M7Archiver-session-zip-")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workspace) }

        let source = workspace.appendingPathComponent("saved-wrong.txt")
        try Data("saved-wrong-zip".utf8).write(to: source)
        let archive = workspace.appendingPathComponent("saved-wrong.zip")
        let creator = ArchiveSession()
        let creation = await creator.createArchive(
            from: [source],
            to: archive,
            profile: BuiltInCompressionProfiles.fastZIP,
            password: "s3cret"
        )
        guard case .completed = creation else {
            XCTFail("Expected encrypted ZIP creation to complete, got \(creation)")
            return
        }

        let store = SavedPasswordsStore(backend: InMemorySavedPasswordsBackend())
        store.save(password: "wrong", for: archive)
        let session = ArchiveSession()

        await openSessionWithSavedPassword(session: session, savedPasswords: store, archiveURL: archive)

        XCTAssertEqual(session.lockState, .locked(reason: .wrongPassword))
        XCTAssertTrue(session.entries.isEmpty)
        XCTAssertNil(store.lookup(for: archive))
    }

    @MainActor
    func testSessionKeepsSavedPasswordForCorruptEncryptedZip() async throws {
        let fileManager = FileManager.default
        let workspace = fileManager.temporaryDirectory
            .appendingPathComponent("M7Archiver-session-zip-")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workspace) }

        let source = workspace.appendingPathComponent("saved-corrupt.txt")
        try Data("saved-corrupt-zip".utf8).write(to: source)
        let archive = workspace.appendingPathComponent("saved-corrupt.zip")
        let creator = ArchiveSession()
        let creation = await creator.createArchive(
            from: [source],
            to: archive,
            profile: BuiltInCompressionProfiles.fastZIP,
            password: "s3cret"
        )
        guard case .completed = creation else {
            XCTFail("Expected encrypted ZIP creation to complete, got \(creation)")
            return
        }

        try corruptFirstZipPayloadByte(at: archive)

        let store = SavedPasswordsStore(backend: InMemorySavedPasswordsBackend())
        store.save(password: "s3cret", for: archive)
        let session = ArchiveSession()

        await openSessionWithSavedPassword(session: session, savedPasswords: store, archiveURL: archive)

        guard case .failed = session.lockState else {
            XCTFail("Expected corrupt encrypted ZIP to fail with saved password, got \(session.lockState)")
            return
        }
        XCTAssertEqual(store.lookup(for: archive), "s3cret")
    }

    @MainActor
    func testResolvePermissionErrorRestoresOwnerWritePermissionAndRetriesExtraction() async throws {
        let fileManager = FileManager.default
        let workspace = fileManager.temporaryDirectory
            .appendingPathComponent("M7Archiver-session-permission-")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: workspace, withIntermediateDirectories: true)
        let destination = workspace.appendingPathComponent("read-only-destination", isDirectory: true)
        defer {
            try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
            try? fileManager.removeItem(at: workspace)
        }

        let source = workspace.appendingPathComponent("payload.txt")
        try Data("permission test".utf8).write(to: source)
        let archive = workspace.appendingPathComponent("payload.zip")
        let creator = ArchiveSession()
        let creation = await creator.createArchive(
            from: [source],
            to: archive,
            profile: BuiltInCompressionProfiles.fastZIP
        )
        guard case .completed = creation else {
            XCTFail("Expected ZIP creation to complete, got \(creation)")
            return
        }

        let session = ArchiveSession()
        await session.open(url: archive)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: destination.path)

        let failed = await session.extract(to: destination)
        guard case .failed = failed else {
            XCTFail("Expected read-only destination extraction to fail, got \(failed)")
            return
        }
        XCTAssertNotNil(session.permissionError)
        XCTAssertNotNil(session.retryOperation)

        await session.resolvePermissionError(with: destination)

        XCTAssertNil(session.permissionError)
        XCTAssertNil(session.operationError)
        XCTAssertNil(session.retryOperation)
        let extracted = try Data(contentsOf: destination.appendingPathComponent("payload.txt"))
        XCTAssertEqual(String(decoding: extracted, as: UTF8.self), "permission test")
        let permissions = try XCTUnwrap(
            fileManager.attributesOfItem(atPath: destination.path)[.posixPermissions] as? NSNumber
        ).intValue
        XCTAssertNotEqual(permissions & 0o200, 0)
    }

    @MainActor
    private func makeSimpleZipArchive() async throws -> URL {
        let fileManager = FileManager.default
        let workspace = fileManager.temporaryDirectory
            .appendingPathComponent("M7Archiver-session-options-")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: workspace, withIntermediateDirectories: true)
        addTeardownBlock { try? fileManager.removeItem(at: workspace) }

        let source = workspace.appendingPathComponent("payload.txt")
        try Data("payload".utf8).write(to: source)
        let archive = workspace.appendingPathComponent("payload.zip")
        let creator = ArchiveSession()
        let creation = await creator.createArchive(
            from: [source],
            to: archive,
            profile: BuiltInCompressionProfiles.fastZIP
        )
        guard case .completed = creation else {
            throw TestArchiveError.creationFailed(String(describing: creation))
        }
        return archive
    }

    private func corruptFirstZipPayloadByte(at archive: URL) throws {
        var data = try Data(contentsOf: archive)
        XCTAssertGreaterThanOrEqual(data.count, 30)
        XCTAssertEqual(data[0], 0x50)
        XCTAssertEqual(data[1], 0x4b)
        XCTAssertEqual(data[2], 0x03)
        XCTAssertEqual(data[3], 0x04)

        let nameLength = Int(data[26]) | (Int(data[27]) << 8)
        let extraLength = Int(data[28]) | (Int(data[29]) << 8)
        let encryptedDataOffset = 30 + nameLength + extraLength + 18
        XCTAssertLessThan(encryptedDataOffset, data.count)

        data[encryptedDataOffset] ^= 0xff
        try data.write(to: archive)
    }
}

private enum TestArchiveError: Error {
    case creationFailed(String)
}

private struct RecordedOperationOptions: Equatable {
    var encoding: ArchiveEncoding?
    var automaticEncodingPriority: [ArchiveEncoding]?
}

private final class OperationOptionsRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [RecordedOperationOptions] = []

    var values: [RecordedOperationOptions] {
        lock.lock()
        defer { lock.unlock() }
        return storedValues
    }

    func record(_ options: ArchiveOperationOptions) {
        lock.lock()
        storedValues.append(RecordedOperationOptions(
            encoding: options.encoding,
            automaticEncodingPriority: options.automaticEncodingPriority
        ))
        lock.unlock()
    }
}

private struct RecordingOptionsEngine: ArchiveEngine {
    let type: ArchiveEngineType = .libarchive
    let recorder: OperationOptionsRecorder
    var metadataEncoding: ArchiveEncoding?

    func listContents(of archiveURL: URL, options: ArchiveOperationOptions) async throws -> [ArchiveEntry] {
        recorder.record(options)
        return [ArchiveEntry(path: "payload.txt")]
    }

    func metadata(of archiveURL: URL, options: ArchiveOperationOptions) async throws -> ArchiveMetadata {
        recorder.record(options)
        return ArchiveMetadata(format: .zip, encoding: metadataEncoding)
    }

    func testArchive(_ archiveURL: URL, options: ArchiveOperationOptions) async throws -> ArchiveOperationResult {
        recorder.record(options)
        return ArchiveOperationResult(operation: .testArchive, archiveURL: archiveURL)
    }

    func extract(_ archiveURL: URL, to destinationURL: URL, options: ArchiveOperationOptions) async throws -> ArchiveOperationResult {
        recorder.record(options)
        return ArchiveOperationResult(operation: .extract, archiveURL: archiveURL, destinationURL: destinationURL)
    }

    func createArchive(from sourceURLs: [URL], to archiveURL: URL, profile: CompressionProfile, password: String?, encryptionMethod: String?, options: ArchiveOperationOptions) async throws -> ArchiveOperationResult {
        recorder.record(options)
        return ArchiveOperationResult(operation: .create, archiveURL: archiveURL, outputURLs: [archiveURL])
    }

    func statusStream() async -> AsyncStream<ArchiveEngineStatus> {
        AsyncStream { continuation in
            continuation.yield(.idle)
            continuation.finish()
        }
    }

    func cancel() async {}
}

private struct BlockingCreateEngine: ArchiveEngine {
    let type: ArchiveEngineType = .libarchive
    private let onCreateStart: @Sendable () -> Void

    init(onCreateStart: @escaping @Sendable () -> Void = {}) {
        self.onCreateStart = onCreateStart
    }

    func listContents(of archiveURL: URL, options: ArchiveOperationOptions) async throws -> [ArchiveEntry] { [] }

    func metadata(of archiveURL: URL, options: ArchiveOperationOptions) async throws -> ArchiveMetadata {
        ArchiveMetadata(format: .zip)
    }

    func testArchive(_ archiveURL: URL, options: ArchiveOperationOptions) async throws -> ArchiveOperationResult {
        ArchiveOperationResult(operation: .testArchive, archiveURL: archiveURL)
    }

    func extract(_ archiveURL: URL, to destinationURL: URL, options: ArchiveOperationOptions) async throws -> ArchiveOperationResult {
        ArchiveOperationResult(operation: .extract, archiveURL: archiveURL, destinationURL: destinationURL)
    }

    func createArchive(from sourceURLs: [URL], to archiveURL: URL, profile: CompressionProfile, password: String?, encryptionMethod: String?, options: ArchiveOperationOptions) async throws -> ArchiveOperationResult {
        onCreateStart()
        while options.isCancelled?() != true {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw CancellationError()
    }

    func statusStream() async -> AsyncStream<ArchiveEngineStatus> {
        AsyncStream { continuation in
            continuation.yield(.idle)
            continuation.finish()
        }
    }

    func cancel() async {}
}

private actor BlockingPreviewGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private struct BlockingPreviewEngine: ArchiveEngine {
    let type: ArchiveEngineType = .libarchive
    let materializedEntryPath: String
    let materializedContents: Data
    let gate: BlockingPreviewGate
    let onExtractStart: @Sendable (ArchiveOperationOptions) -> Void

    init(
        materializedEntryPath: String,
        materializedContents: Data,
        gate: BlockingPreviewGate,
        onExtractStart: @escaping @Sendable (ArchiveOperationOptions) -> Void = { _ in }
    ) {
        self.materializedEntryPath = materializedEntryPath
        self.materializedContents = materializedContents
        self.gate = gate
        self.onExtractStart = onExtractStart
    }

    func listContents(of archiveURL: URL, options: ArchiveOperationOptions) async throws -> [ArchiveEntry] {
        [ArchiveEntry(path: materializedEntryPath)]
    }

    func metadata(of archiveURL: URL, options: ArchiveOperationOptions) async throws -> ArchiveMetadata {
        ArchiveMetadata(format: .zip)
    }

    func testArchive(_ archiveURL: URL, options: ArchiveOperationOptions) async throws -> ArchiveOperationResult {
        ArchiveOperationResult(operation: .testArchive, archiveURL: archiveURL)
    }

    func extract(_ archiveURL: URL, to destinationURL: URL, options: ArchiveOperationOptions) async throws -> ArchiveOperationResult {
        onExtractStart(options)
        await gate.wait()
        let outputURL = destinationURL.appendingPathComponent(materializedEntryPath)
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try materializedContents.write(to: outputURL)
        return ArchiveOperationResult(
            operation: .extract,
            archiveURL: archiveURL,
            destinationURL: destinationURL,
            entries: [ArchiveEntry(path: materializedEntryPath)]
        )
    }

    func createArchive(from sourceURLs: [URL], to archiveURL: URL, profile: CompressionProfile, password: String?, encryptionMethod: String?, options: ArchiveOperationOptions) async throws -> ArchiveOperationResult {
        ArchiveOperationResult(operation: .create, archiveURL: archiveURL, outputURLs: [archiveURL])
    }

    func statusStream() async -> AsyncStream<ArchiveEngineStatus> {
        AsyncStream { continuation in
            continuation.yield(.idle)
            continuation.finish()
        }
    }

    func cancel() async {}
}
