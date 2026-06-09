import XCTest
import ArchiveCore
@testable import M7ArchiverApp

final class ArchiveSessionSevenZipIntegrationTests: XCTestCase {
    @MainActor
    func testSessionExtractUsesBridgeBackedSevenZipEngine() async throws {
        guard let bundled = locateBundledBinary() else {
            throw XCTSkip("Vendor/7zip/bin/7zz is not built. Run Vendor/7zip/build-7zz.sh --universal.")
        }

        let fileManager = FileManager.default
        let workspace = fileManager.temporaryDirectory
            .appendingPathComponent("M7Archiver-session-7z-")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workspace) }

        let source = workspace.appendingPathComponent("hello.txt")
        try Data("session-hello".utf8).write(to: source)
        let archive = workspace.appendingPathComponent("hello.7z")

        let creator = SevenZipEngine(executableURL: bundled)
        _ = try await creator.createArchive(
            from: [source],
            to: archive,
            profile: CompressionProfile(name: "Standard 7z", format: .sevenZip, solid: false)
        )

        let session = ArchiveSession()
        await session.open(url: archive)
        XCTAssertEqual(session.lockState, .unlocked)
        XCTAssertEqual(session.entries.map(\.path), ["hello.txt"])

        let out = workspace.appendingPathComponent("out", isDirectory: true)
        let outcome = await session.extract(to: out)
        XCTAssertEqual(outcome, .completed(destination: out, result: ArchiveSession.ExtractionResult(entryCount: 1)))

        let extracted = try Data(contentsOf: out.appendingPathComponent("hello.txt"))
        XCTAssertEqual(String(decoding: extracted, as: UTF8.self), "session-hello")
    }

    @MainActor
    func testSessionExtractSelectedWithoutSelectionReturnsMissingSelection() async throws {
        guard let bundled = locateBundledBinary() else {
            throw XCTSkip("Vendor/7zip/bin/7zz is not built. Run Vendor/7zip/build-7zz.sh --universal.")
        }

        let fileManager = FileManager.default
        let workspace = fileManager.temporaryDirectory
            .appendingPathComponent("M7Archiver-session-7z-")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workspace) }

        let source = workspace.appendingPathComponent("hello.txt")
        try Data("session-hello".utf8).write(to: source)
        let archive = workspace.appendingPathComponent("hello.7z")

        let creator = SevenZipEngine(executableURL: bundled)
        _ = try await creator.createArchive(
            from: [source],
            to: archive,
            profile: CompressionProfile(name: "Standard 7z", format: .sevenZip, solid: false)
        )

        let session = ArchiveSession()
        await session.open(url: archive)

        let out = workspace.appendingPathComponent("out", isDirectory: true)
        let outcome = await session.extractSelected(to: out)
        XCTAssertEqual(outcome, .missingSelection)
    }

    @MainActor
    func testSessionExtractSelectedExtractsOnlySelectedFile() async throws {
        guard let bundled = locateBundledBinary() else {
            throw XCTSkip("Vendor/7zip/bin/7zz is not built. Run Vendor/7zip/build-7zz.sh --universal.")
        }

        let fileManager = FileManager.default
        let workspace = fileManager.temporaryDirectory
            .appendingPathComponent("M7Archiver-session-7z-")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workspace) }

        let first = workspace.appendingPathComponent("first.txt")
        let second = workspace.appendingPathComponent("second.txt")
        try Data("first".utf8).write(to: first)
        try Data("second".utf8).write(to: second)
        let archive = workspace.appendingPathComponent("hello.7z")

        let creator = SevenZipEngine(executableURL: bundled)
        _ = try await creator.createArchive(
            from: [first, second],
            to: archive,
            profile: CompressionProfile(name: "Standard 7z", format: .sevenZip, solid: false)
        )

        let session = ArchiveSession()
        await session.open(url: archive)
        session.selection = ["second.txt"]

        let out = workspace.appendingPathComponent("out", isDirectory: true)
        let outcome = await session.extractSelected(to: out)
        XCTAssertEqual(outcome, .completed(destination: out, result: ArchiveSession.ExtractionResult(entryCount: 1)))
        XCTAssertEqual(
            String(decoding: try Data(contentsOf: out.appendingPathComponent("second.txt")), as: UTF8.self),
            "second"
        )
        XCTAssertFalse(fileManager.fileExists(atPath: out.appendingPathComponent("first.txt").path))
    }

    @MainActor
    func testSessionExtractSelectedExtractsOnlySelectedDirectoryContents() async throws {
        guard let bundled = locateBundledBinary() else {
            throw XCTSkip("Vendor/7zip/bin/7zz is not built. Run Vendor/7zip/build-7zz.sh --universal.")
        }

        let fileManager = FileManager.default
        let workspace = fileManager.temporaryDirectory
            .appendingPathComponent("M7Archiver-session-7z-")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workspace) }

        let nested = workspace.appendingPathComponent("nested", isDirectory: true)
        try fileManager.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("a".utf8).write(to: nested.appendingPathComponent("a.txt"))
        try Data("b".utf8).write(to: nested.appendingPathComponent("b.txt"))
        let other = workspace.appendingPathComponent("other.txt")
        try Data("other".utf8).write(to: other)
        let archive = workspace.appendingPathComponent("hello.7z")

        let creator = SevenZipEngine(executableURL: bundled)
        _ = try await creator.createArchive(
            from: [nested, other],
            to: archive,
            profile: CompressionProfile(name: "Standard 7z", format: .sevenZip, solid: false)
        )

        let session = ArchiveSession()
        await session.open(url: archive)
        session.selection = ["nested"]

        let out = workspace.appendingPathComponent("out", isDirectory: true)
        let outcome = await session.extractSelected(to: out)
        XCTAssertEqual(outcome, .completed(destination: out, result: ArchiveSession.ExtractionResult(entryCount: 2)))
        XCTAssertEqual(
            String(decoding: try Data(contentsOf: out.appendingPathComponent("nested/a.txt")), as: UTF8.self),
            "a"
        )
        XCTAssertEqual(
            String(decoding: try Data(contentsOf: out.appendingPathComponent("nested/b.txt")), as: UTF8.self),
            "b"
        )
        XCTAssertFalse(fileManager.fileExists(atPath: out.appendingPathComponent("other.txt").path))
    }

    @MainActor
    func testSessionCreateEncryptedSevenZipUsesPasswordAndHeaderEncryption() async throws {
        guard let bundled = locateBundledBinary() else {
            throw XCTSkip("Vendor/7zip/bin/7zz is not built. Run Vendor/7zip/build-7zz.sh --universal.")
        }

        let fileManager = FileManager.default
        let workspace = fileManager.temporaryDirectory
            .appendingPathComponent("M7Archiver-session-7z-")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workspace) }

        let source = workspace.appendingPathComponent("secret.txt")
        try Data("session-secret".utf8).write(to: source)
        let archive = workspace.appendingPathComponent("secret.7z")
        let profile = CompressionProfile(
            name: "Encrypted 7z",
            format: .sevenZip,
            solid: false,
            encryptFileNames: true
        )

        let session = ArchiveSession()
        let outcome = await session.createArchive(
            from: [source],
            to: archive,
            profile: profile,
            password: "s3cret"
        )

        guard case .completed(let outputs, _) = outcome else {
            XCTFail("Expected encrypted 7z creation to complete, got \(outcome)")
            return
        }
        XCTAssertEqual(outputs, [archive])

        let right = try runSevenZip(bundled, ["t", archive.path, "-ps3cret", "-y", "-bd"])
        XCTAssertEqual(right.exitCode, 0, right.stderr)

        let wrong = try runSevenZip(bundled, ["l", archive.path, "-pwrong", "-y", "-bd"])
        XCTAssertNotEqual(wrong.exitCode, 0)
        XCTAssertTrue((wrong.stdout + wrong.stderr).contains("Wrong password"))
    }

    @MainActor
    func testSessionUnlocksEncryptedSevenZipWithCorrectPassword() async throws {
        guard locateBundledBinary() != nil else {
            throw XCTSkip("Vendor/7zip/bin/7zz is not built. Run Vendor/7zip/build-7zz.sh --universal.")
        }

        let fileManager = FileManager.default
        let workspace = fileManager.temporaryDirectory
            .appendingPathComponent("M7Archiver-session-7z-")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workspace) }

        let source = workspace.appendingPathComponent("locked.txt")
        try Data("locked-sevenzip".utf8).write(to: source)
        let archive = workspace.appendingPathComponent("locked.7z")
        let profile = CompressionProfile(
            name: "Encrypted 7z",
            format: .sevenZip,
            solid: false,
            encryptFileNames: true
        )

        let creator = ArchiveSession()
        let creation = await creator.createArchive(
            from: [source],
            to: archive,
            profile: profile,
            password: "s3cret"
        )
        guard case .completed = creation else {
            XCTFail("Expected encrypted 7z creation to complete, got \(creation)")
            return
        }

        let session = ArchiveSession()
        await session.open(url: archive)
        XCTAssertEqual(session.lockState, .locked(reason: .required))
        XCTAssertTrue(session.entries.isEmpty)

        await session.unlock(password: "wrong")
        XCTAssertEqual(session.lockState, .locked(reason: .wrongPassword))
        XCTAssertTrue(session.entries.isEmpty)

        await session.unlock(password: "s3cret")
        XCTAssertEqual(session.lockState, .unlocked)
        XCTAssertEqual(session.entries.map(\.path), ["locked.txt"])
        XCTAssertEqual(session.metadata?.format, .sevenZip)
        XCTAssertTrue(session.metadata?.isEncrypted == true)

        let out = workspace.appendingPathComponent("out", isDirectory: true)
        let extraction = await session.extract(to: out)
        XCTAssertEqual(extraction, .completed(destination: out, result: ArchiveSession.ExtractionResult(entryCount: 1)))
        let extracted = try Data(contentsOf: out.appendingPathComponent("locked.txt"))
        XCTAssertEqual(String(decoding: extracted, as: UTF8.self), "locked-sevenzip")

        let verification = await session.verifyCurrentArchive()
        guard case .completed = verification else {
            XCTFail("Expected verify to complete after unlock, got \(verification)")
            return
        }
    }

    @MainActor
    func testSessionUsesSavedPasswordForEncryptedSevenZip() async throws {
        guard locateBundledBinary() != nil else {
            throw XCTSkip("Vendor/7zip/bin/7zz is not built. Run Vendor/7zip/build-7zz.sh --universal.")
        }

        let fileManager = FileManager.default
        let workspace = fileManager.temporaryDirectory
            .appendingPathComponent("M7Archiver-session-7z-")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workspace) }

        let source = workspace.appendingPathComponent("saved.txt")
        try Data("saved-sevenzip".utf8).write(to: source)
        let archive = workspace.appendingPathComponent("saved.7z")
        let profile = CompressionProfile(
            name: "Encrypted 7z",
            format: .sevenZip,
            solid: false,
            encryptFileNames: true
        )

        let creator = ArchiveSession()
        let creation = await creator.createArchive(
            from: [source],
            to: archive,
            profile: profile,
            password: "s3cret"
        )
        guard case .completed = creation else {
            XCTFail("Expected encrypted 7z creation to complete, got \(creation)")
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
    func testSavedPasswordUnlockMakesPendingSevenZipOperationsReplayable() async throws {
        guard locateBundledBinary() != nil else {
            throw XCTSkip("Vendor/7zip/bin/7zz is not built. Run Vendor/7zip/build-7zz.sh --universal.")
        }

        let fileManager = FileManager.default
        let workspace = fileManager.temporaryDirectory
            .appendingPathComponent("M7Archiver-session-7z-")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workspace) }

        let source = workspace.appendingPathComponent("pending.txt")
        try Data("pending-sevenzip".utf8).write(to: source)
        let archive = workspace.appendingPathComponent("pending.7z")
        let profile = CompressionProfile(
            name: "Encrypted 7z",
            format: .sevenZip,
            solid: false,
            encryptFileNames: true
        )

        let creator = ArchiveSession()
        let creation = await creator.createArchive(
            from: [source],
            to: archive,
            profile: profile,
            password: "s3cret"
        )
        guard case .completed = creation else {
            XCTFail("Expected encrypted 7z creation to complete, got \(creation)")
            return
        }

        let store = SavedPasswordsStore(backend: InMemorySavedPasswordsBackend())
        store.save(password: "s3cret", for: archive)
        let session = ArchiveSession()
        let out = workspace.appendingPathComponent("out", isDirectory: true)
        var pendingAutoExtract = PendingAutoExtractState()
        var pendingTestArchive = PendingTestArchiveState()
        pendingAutoExtract.stage(PendingAutoExtractRequest(archiveURL: archive, finderTarget: out))
        pendingTestArchive.stage(PendingTestArchiveRequest(archiveURL: archive))

        await openSessionWithSavedPassword(session: session, savedPasswords: store, archiveURL: archive)

        XCTAssertEqual(session.lockState, .unlocked)
        XCTAssertEqual(session.entries.map(\.path), ["pending.txt"])
        XCTAssertEqual(
            pendingAutoExtract.consumeIfReady(openArchiveURL: session.archiveURL, lockState: session.lockState),
            PendingAutoExtractRequest(archiveURL: archive, finderTarget: out)
        )
        XCTAssertEqual(
            pendingTestArchive.consumeIfReady(openArchiveURL: session.archiveURL, lockState: session.lockState),
            PendingTestArchiveRequest(archiveURL: archive)
        )

        let extraction = await session.extract(to: out)
        XCTAssertEqual(extraction, .completed(destination: out, result: ArchiveSession.ExtractionResult(entryCount: 1)))
        let extracted = try Data(contentsOf: out.appendingPathComponent("pending.txt"))
        XCTAssertEqual(String(decoding: extracted, as: UTF8.self), "pending-sevenzip")

        let verification = await session.verifyCurrentArchive()
        guard case .completed = verification else {
            XCTFail("Expected verify to complete after saved-password unlock, got \(verification)")
            return
        }
    }

    @MainActor
    func testSessionDeletesWrongSavedPasswordForEncryptedSevenZip() async throws {
        guard locateBundledBinary() != nil else {
            throw XCTSkip("Vendor/7zip/bin/7zz is not built. Run Vendor/7zip/build-7zz.sh --universal.")
        }

        let fileManager = FileManager.default
        let workspace = fileManager.temporaryDirectory
            .appendingPathComponent("M7Archiver-session-7z-")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workspace) }

        let source = workspace.appendingPathComponent("saved-wrong.txt")
        try Data("saved-wrong-sevenzip".utf8).write(to: source)
        let archive = workspace.appendingPathComponent("saved-wrong.7z")
        let profile = CompressionProfile(
            name: "Encrypted 7z",
            format: .sevenZip,
            solid: false,
            encryptFileNames: true
        )

        let creator = ArchiveSession()
        let creation = await creator.createArchive(
            from: [source],
            to: archive,
            profile: profile,
            password: "s3cret"
        )
        guard case .completed = creation else {
            XCTFail("Expected encrypted 7z creation to complete, got \(creation)")
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

    private func runSevenZip(_ executableURL: URL, _ arguments: [String]) throws -> SevenZipProcessResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        return SevenZipProcessResult(
            exitCode: process.terminationStatus,
            stdout: String(decoding: stdoutData, as: UTF8.self),
            stderr: String(decoding: stderrData, as: UTF8.self)
        )
    }

    private func locateBundledBinary() -> URL? {
        let here = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
        var dir = here.deletingLastPathComponent()
        for _ in 0..<10 {
            let candidate = dir
                .appendingPathComponent("Vendor/7zip/bin/7zz")
                .standardizedFileURL
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
            let parent = dir.deletingLastPathComponent()
            if parent == dir { break }
            dir = parent
        }
        return nil
    }
}
