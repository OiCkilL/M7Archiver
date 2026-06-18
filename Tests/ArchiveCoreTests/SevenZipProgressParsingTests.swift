import XCTest
@testable import ArchiveCore

final class SevenZipProgressParsingTests: XCTestCase {
    /// Bytes captured from a real `7zz a -bsp1` run (7-Zip 26.01): the
    /// percentage is written as `  NN%` followed by backspace (`\u{08}`)
    /// overwrite sequences, interleaved with normal log lines.
    func testParsesLatestPercentageFromRealBsp1Output() {
        let raw = "\u{08}\u{08}\u{08}\u{08}    \u{08}\u{08}\u{08}\u{08}  0%\u{08}\u{08}\u{08}\u{08}  17%\u{08}\u{08}\u{08}\u{08}  42%"
        let fraction = SevenZipDefaultRunner.parseProgress(from: Data(raw.utf8))
        XCTAssertEqual(fraction, 0.42)
    }

    func testReturnsNilWhenNoPercentageEmittedYet() {
        let raw = "7-Zip (z) 26.01 (arm64)\nScanning the drive:\n1 file, 60000000 bytes\n"
        XCTAssertNil(SevenZipDefaultRunner.parseProgress(from: Data(raw.utf8)))
    }

    func testClampsToUnitRange() {
        let raw = "  100%"
        XCTAssertEqual(SevenZipDefaultRunner.parseProgress(from: Data(raw.utf8)), 1.0)
    }

    func testHandlesCarriageReturnOverwrite() {
        // Some shells/builds use `\r` instead of backspace; the `NN%` regex
        // must still find the latest value.
        let raw = "  0%\r  35%\r  88%\r"
        XCTAssertEqual(SevenZipDefaultRunner.parseProgress(from: Data(raw.utf8)), 0.88)
    }

    func testIgnoresStrayPercentInFilenames() {
        // A filename containing `%` without a leading digit must not be
        // mistaken for progress. `(\d{1,3})%` requires digits, so a bare
        // `foo%.txt` yields no match.
        let raw = "Add new data: foo%.txt\n"
        XCTAssertNil(SevenZipDefaultRunner.parseProgress(from: Data(raw.utf8)))
    }

    func testParsesAcrossIncrementalChunks() {
        // The streaming accumulator feeds partial bytes; parsing the
        // concatenation must yield the latest percentage seen so far.
        var data = Data()
        data.append(Data("  0%".utf8))
        XCTAssertEqual(SevenZipDefaultRunner.parseProgress(from: data), 0.0)
        data.append(Data("  55%".utf8))
        XCTAssertEqual(SevenZipDefaultRunner.parseProgress(from: data), 0.55)
        data.append(Data("  100%".utf8))
        XCTAssertEqual(SevenZipDefaultRunner.parseProgress(from: data), 1.0)
    }
}
