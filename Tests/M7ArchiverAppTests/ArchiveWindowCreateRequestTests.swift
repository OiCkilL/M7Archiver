import XCTest
@testable import M7ArchiverApp

@MainActor
final class ArchiveWindowCreateRequestTests: XCTestCase {
    func testPresentStagingCompressStagesPendingCreateRequestAndShowsDialog() throws {
        let model = makeModel()
        let base = try makeTempDirectory()
        let urls = try makeFiles(in: base, names: ["a.txt", "b.txt"])

        model.enterStagingMode()
        model.addToStaging(urls)
        model.presentStagingCompress()

        XCTAssertTrue(model.newArchiveDialogPresented)
        XCTAssertEqual(model.pendingCreateRequest?.source, .staging)
        XCTAssertEqual(model.pendingCreateRequest?.sources.map(\.path), urls.map(\.path))
        XCTAssertNil(model.pendingCreateRequest?.finderTarget)
    }

    func testStagingCancelPreservesPendingCreateRequest() throws {
        let model = makeModel()
        let base = try makeTempDirectory()
        let urls = try makeFiles(in: base, names: ["a.txt"])

        model.enterStagingMode()
        model.addToStaging(urls)
        model.presentStagingCompress()
        model.handlePendingCreateOutcome(.cancel)

        XCTAssertEqual(model.pendingCreateRequest?.source, .staging)
        XCTAssertEqual(model.stagingSources.count, 1)
    }

    func testStagingFailurePreservesPendingCreateRequest() throws {
        let model = makeModel()
        let base = try makeTempDirectory()
        let urls = try makeFiles(in: base, names: ["a.txt"])

        model.enterStagingMode()
        model.addToStaging(urls)
        model.presentStagingCompress()
        model.handlePendingCreateOutcome(.failure)

        XCTAssertEqual(model.pendingCreateRequest?.source, .staging)
        XCTAssertEqual(model.stagingSources.count, 1)
    }

    func testStagingSuccessClearsPendingCreateRequestAndStaging() throws {
        let model = makeModel()
        let base = try makeTempDirectory()
        let urls = try makeFiles(in: base, names: ["a.txt"])

        model.enterStagingMode()
        model.addToStaging(urls)
        model.presentStagingCompress()
        model.handlePendingCreateOutcome(.success)

        XCTAssertNil(model.pendingCreateRequest)
        XCTAssertTrue(model.stagingSources.isEmpty)
        XCTAssertEqual(model.mode, .default_)
    }

    func testFinderOutcomesAlwaysClearPendingCreateRequest() {
        for outcome in [PendingCreateOutcome.cancel, .failure, .success] {
            let model = makeModel()
            model.pendingCreateRequest = PendingCreateArchiveRequest(
                sources: [URL(fileURLWithPath: "/tmp/a.txt")],
                finderTarget: URL(fileURLWithPath: "/tmp"),
                source: .finder
            )

            model.handlePendingCreateOutcome(outcome)

            XCTAssertNil(model.pendingCreateRequest, "outcome=\(outcome)")
        }
    }

    func testStageFinderCreateRequestStoresTargetAndShowsDialog() throws {
        let model = makeModel()
        let base = try makeTempDirectory()
        let files = try makeFiles(in: base, names: ["a.txt", "b.txt"])

        model.stageFinderCreateRequest(sources: files, finderTarget: base)

        XCTAssertTrue(model.newArchiveDialogPresented)
        XCTAssertEqual(model.pendingCreateRequest?.source, .finder)
        XCTAssertEqual(model.pendingCreateRequest?.finderTarget?.path, base.path)
        XCTAssertEqual(model.pendingCreateRequest?.sources.map(\.path), files.map(\.path))
    }

    func testHandleValidatedAppURLAddToArchiveRoutesToFullDialog() async throws {
        let model = makeModel()
        let base = try makeTempDirectory()
        let files = try makeFiles(in: base, names: ["a.txt", "b.txt"])
        let appUrl = AppUrl(action: .addToArchive, files: files, target: base)

        model.handleValidatedAppURL(appUrl, autoExtract: false)

        for _ in 0..<20 {
            if model.pendingCreateRequest != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertTrue(model.newArchiveDialogPresented)
        XCTAssertEqual(model.pendingCreateRequest?.source, .finder)
        XCTAssertEqual(model.pendingCreateRequest?.finderTarget?.path, base.path)
        XCTAssertEqual(model.pendingCreateRequest?.sources.map(\.path), files.map(\.path))
        XCTAssertFalse(model.session.hasArchive)
    }

    func testDialogDismissTreatsIdleDismissAsCancel() throws {
        let model = makeModel()
        let base = try makeTempDirectory()
        let urls = try makeFiles(in: base, names: ["a.txt"])
        model.enterStagingMode()
        model.addToStaging(urls)
        model.presentStagingCompress()

        model.handleNewArchiveDialogDismissed()

        XCTAssertEqual(model.pendingCreateRequest?.source, .staging)
    }

    func testDialogDismissDoesNothingWhileSubmissionInFlight() throws {
        let model = makeModel()
        model.pendingCreateRequest = PendingCreateArchiveRequest(
            sources: [URL(fileURLWithPath: "/tmp/a.txt")],
            finderTarget: URL(fileURLWithPath: "/tmp"),
            source: .finder
        )
        model.pendingCreateSubmissionInFlight = true

        model.handleNewArchiveDialogDismissed()

        XCTAssertEqual(model.pendingCreateRequest?.source, .finder)
    }

    private func makeModel() -> ArchiveWindowModel {
        ArchiveWindowModel(
            settings: ArchiveSettings(defaults: UserDefaults(suiteName: "ArchiveWindowCreateRequestTests.\(UUID().uuidString)")!),
            savedPasswords: SavedPasswordsStore(backend: InMemorySavedPasswordsBackend())
        )
    }

    @discardableResult
    private func makeTempDirectory() throws -> URL {
        let base = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("ArchiveWindowCreateRequestTests.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: base)
        }
        return base
    }

    private func makeFiles(in directory: URL, names: [String]) throws -> [URL] {
        try names.map { name in
            let url = directory.appendingPathComponent(name)
            try Data().write(to: url)
            return url
        }
    }
}
