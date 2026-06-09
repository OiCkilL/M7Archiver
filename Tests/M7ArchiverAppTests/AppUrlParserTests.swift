import XCTest
@testable import M7ArchiverApp

final class AppUrlParserTests: XCTestCase {
    // MARK: - Pending request state (unchanged)

    func testPendingAutoExtractStateConsumesOnlyUnlockedMatchingArchive() {
        var state = PendingAutoExtractState()
        let archive = URL(fileURLWithPath: "/tmp/archive.7z")
        let target = URL(fileURLWithPath: "/tmp/out")
        state.stage(PendingAutoExtractRequest(archiveURL: archive, finderTarget: target))

        XCTAssertNil(state.consumeIfReady(openArchiveURL: archive, lockState: .locked(reason: .required)))
        XCTAssertNil(state.consumeIfReady(openArchiveURL: URL(fileURLWithPath: "/tmp/other.7z"), lockState: .unlocked))

        let consumed = state.consumeIfReady(openArchiveURL: archive, lockState: .unlocked)
        XCTAssertEqual(consumed?.archiveURL, archive)
        XCTAssertEqual(consumed?.finderTarget, target)
        XCTAssertNil(state.consumeIfReady(openArchiveURL: archive, lockState: .unlocked))
    }

    func testPendingPromptedExtractStateConsumesOnlyUnlockedMatchingArchive() {
        var state = PendingPromptedExtractState()
        let archive = URL(fileURLWithPath: "/tmp/archive.7z")
        let target = URL(fileURLWithPath: "/tmp/out")
        state.stage(PendingPromptedExtractRequest(archiveURL: archive, finderTarget: target))

        XCTAssertNil(state.consumeIfReady(openArchiveURL: archive, lockState: .locked(reason: .required)))
        XCTAssertNil(state.consumeIfReady(openArchiveURL: URL(fileURLWithPath: "/tmp/other.7z"), lockState: .unlocked))

        let consumed = state.consumeIfReady(openArchiveURL: archive, lockState: .unlocked)
        XCTAssertEqual(consumed?.archiveURL, archive)
        XCTAssertEqual(consumed?.finderTarget, target)
        XCTAssertNil(state.consumeIfReady(openArchiveURL: archive, lockState: .unlocked))
    }

    func testPendingTestArchiveStateConsumesOnlyUnlockedMatchingArchive() {
        var state = PendingTestArchiveState()
        let archive = URL(fileURLWithPath: "/tmp/archive.7z")
        state.stage(PendingTestArchiveRequest(archiveURL: archive))

        XCTAssertNil(state.consumeIfReady(openArchiveURL: archive, lockState: .locked(reason: .required)))
        XCTAssertNil(state.consumeIfReady(openArchiveURL: URL(fileURLWithPath: "/tmp/other.7z"), lockState: .unlocked))

        let consumed = state.consumeIfReady(openArchiveURL: archive, lockState: .unlocked)
        XCTAssertEqual(consumed?.archiveURL, archive)
        XCTAssertNil(state.consumeIfReady(openArchiveURL: archive, lockState: .unlocked))
    }

    // MARK: - AppUrlParser: basic validation

    func testRejectsNonAppScheme() {
        let url = URL(string: "https://example.com/open?files=/tmp/x")!
        XCTAssertNil(AppUrlParser.parse(url))
    }

    func testRejectsUnknownAction() {
        let url = URL(string: "m7archiver://nuke?files=%2Ftmp%2Fx")!
        XCTAssertNil(AppUrlParser.parse(url))
    }

    func testRejectsMissingFiles() {
        let url = URL(string: "m7archiver://open")!
        XCTAssertNil(AppUrlParser.parse(url))
    }

    func testKnownActionsMatchProductRequirements() {
        let raws = AppUrlAction.allCases.map(\.rawValue)
        XCTAssertEqual(
            Set(raws),
            Set([
                "open",
                "extractFiles",
                "extractHere",
                "extractToFolder",
                "addToArchive",
                "addTo7z",
                "addToZip",
                "testArchive"
            ])
        )
    }

    // MARK: - Repeated format (single file)

    func testParsesOpenWithSingleFile() throws {
        let url = URL(string: "m7archiver://open?files=%2Ftmp%2Farchive.zip")!
        let parsed = try XCTUnwrap(AppUrlParser.parse(url))
        XCTAssertEqual(parsed.action, .open)
        XCTAssertEqual(parsed.files.map(\.path), ["/tmp/archive.zip"])
        XCTAssertNil(parsed.target)
    }

    func testParsesAddTo7zAction() throws {
        let url = URL(string: "m7archiver://addTo7z?files=%2Ftmp%2Ffoo.txt")!
        let parsed = try XCTUnwrap(AppUrlParser.parse(url))
        XCTAssertEqual(parsed.action, .addTo7z)
    }

    // MARK: - Repeated format (multiple files)

    func testParsesExtractHereWithMultipleFilesAndTarget() throws {
        let raw = "m7archiver://extractHere?files=%2Ftmp%2Fa.zip&files=%2Ftmp%2Fb.7z&target=%2FUsers%2Fevan%2FDownloads"
        let url = URL(string: raw)!
        let parsed = try XCTUnwrap(AppUrlParser.parse(url))
        XCTAssertEqual(parsed.action, .extractHere)
        XCTAssertEqual(parsed.files.map(\.path), ["/tmp/a.zip", "/tmp/b.7z"])
        XCTAssertEqual(parsed.target?.path, "/Users/evan/Downloads")
    }

    // MARK: - Round-trip

    func testRoundTripsThroughMakeURL() throws {
        let files = [URL(fileURLWithPath: "/tmp/a.zip"), URL(fileURLWithPath: "/tmp/b.7z")]
        let target = URL(fileURLWithPath: "/Users/evan/Downloads")
        let made = try XCTUnwrap(AppUrlParser.makeURL(action: .extractToFolder, files: files, target: target))
        XCTAssertEqual(made.scheme, "m7archiver")
        XCTAssertEqual(made.host, "extractToFolder")
        let parsed = try XCTUnwrap(AppUrlParser.parse(made))
        XCTAssertEqual(parsed.action, .extractToFolder)
        XCTAssertEqual(parsed.files.map(\.path), files.map(\.path))
        XCTAssertEqual(parsed.target?.path, target.path)
    }

    // MARK: - Edge cases: special characters in file paths

    func testRoundTripsFilePathsContainingCommas() throws {
        let files = [URL(fileURLWithPath: "/tmp/report,final.zip")]
        let made = try XCTUnwrap(AppUrlParser.makeURL(action: .open, files: files))
        let parsed = try XCTUnwrap(AppUrlParser.parse(made))
        XCTAssertEqual(parsed.files.map(\.path), files.map(\.path))
    }

    func testSingleRepeatedFormatFilePathKeepsLiteralPercentSequence() throws {
        let files = [URL(fileURLWithPath: "/tmp/a%20b.zip")]
        let target = URL(fileURLWithPath: "/tmp/target%20folder")
        let made = try XCTUnwrap(AppUrlParser.makeURL(action: .extractHere, files: files, target: target))
        let parsed = try XCTUnwrap(AppUrlParser.parse(made))
        XCTAssertEqual(parsed.files.map(\.path), files.map(\.path))
        XCTAssertEqual(parsed.target?.path, target.path)
    }

    func testRoundTripsFilePathContainingCommaSlashThroughNewFormat() throws {
        let files = [URL(fileURLWithPath: "/Users/me/foo,/tmp/bar.zip")]
        let made = try XCTUnwrap(AppUrlParser.makeURL(action: .open, files: files))
        let parsed = try XCTUnwrap(AppUrlParser.parse(made))
        XCTAssertEqual(parsed.files.map(\.path), files.map(\.path))
    }

    func testEncodedCommaInSingleFilePathIsNotSplit() throws {
        let url = URL(string: "m7archiver://open?files=%2Ftmp%2Freport%2Cfinal.zip")!
        let parsed = try XCTUnwrap(AppUrlParser.parse(url))
        XCTAssertEqual(parsed.files.map(\.path), ["/tmp/report,final.zip"])
    }

    func testSingleRepeatedFormatFilePathContainingCommaSlashIsNotSplit() throws {
        let files = [URL(fileURLWithPath: "/tmp/foo,/bar.zip")]
        let made = try XCTUnwrap(AppUrlParser.makeURL(action: .open, files: files))
        let parsed = try XCTUnwrap(AppUrlParser.parse(made))
        XCTAssertEqual(parsed.files.map(\.path), files.map(\.path))
    }

    func testParsesFilePathWithChineseCharacters() throws {
        let files = [URL(fileURLWithPath: "/Users/用户/文件.txt")]
        let made = try XCTUnwrap(AppUrlParser.makeURL(action: .open, files: files))
        let parsed = try XCTUnwrap(AppUrlParser.parse(made))
        XCTAssertEqual(parsed.files.map(\.path), files.map(\.path))
    }

    func testParsesFilePathWithAmpersand() throws {
        let files = [URL(fileURLWithPath: "/tmp/a&b.txt")]
        let made = try XCTUnwrap(AppUrlParser.makeURL(action: .open, files: files))
        let parsed = try XCTUnwrap(AppUrlParser.parse(made))
        XCTAssertEqual(parsed.files.map(\.path), files.map(\.path))
    }

    func testParsesFilePathWithPlus() throws {
        let files = [URL(fileURLWithPath: "/tmp/a+b.txt")]
        let made = try XCTUnwrap(AppUrlParser.makeURL(action: .open, files: files))
        let parsed = try XCTUnwrap(AppUrlParser.parse(made))
        XCTAssertEqual(parsed.files.map(\.path), files.map(\.path))
    }

    func testParsesFilePathWithHash() throws {
        let files = [URL(fileURLWithPath: "/tmp/a#b.txt")]
        let made = try XCTUnwrap(AppUrlParser.makeURL(action: .open, files: files))
        let parsed = try XCTUnwrap(AppUrlParser.parse(made))
        XCTAssertEqual(parsed.files.map(\.path), files.map(\.path))
    }

    func testParsesMultipleFilesWithMixedSpecialCharacters() throws {
        let files = [
            URL(fileURLWithPath: "/tmp/a&b +c.txt"),
            URL(fileURLWithPath: "/用户/文件#1.zip"),
            URL(fileURLWithPath: "/tmp/foo,bar.7z"),
        ]
        let target = URL(fileURLWithPath: "/输出/文件夹")
        let made = try XCTUnwrap(AppUrlParser.makeURL(action: .extractHere, files: files, target: target))
        let parsed = try XCTUnwrap(AppUrlParser.parse(made))
        XCTAssertEqual(parsed.action, .extractHere)
        XCTAssertEqual(parsed.files.map(\.path), files.map(\.path))
        XCTAssertEqual(parsed.target?.path, target.path)
    }

    // MARK: - format=repeated query param is ignored (forward-compat)

    func testIgnoresFormatParam() throws {
        let url = URL(string: "m7archiver://open?files=%2Ftmp%2Fa.zip&format=repeated")!
        let parsed = try XCTUnwrap(AppUrlParser.parse(url))
        XCTAssertEqual(parsed.files.map(\.path), ["/tmp/a.zip"])
    }

}
