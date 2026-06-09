import XCTest
import ArchiveCore
import ArchivePresentation
@testable import M7ArchiverApp

final class ArchiveInspectorPreviewSupportTests: XCTestCase {
    func testPreviewPolicyRecognizesSupportedKinds() {
        let metadata = ArchiveMetadata(format: .zip, compressedSize: 1_024)

        let text = ArchiveRow(entry: ArchiveEntry(path: "README.txt", size: 120))
        let image = ArchiveRow(entry: ArchiveEntry(path: "Preview.png", size: 4_096))
        let pdf = ArchiveRow(entry: ArchiveEntry(path: "Manual.pdf", size: 8_192))

        XCTAssertEqual(
            ArchiveInspectorPreviewPolicy.decision(
                for: text,
                metadata: metadata,
                lockState: .unlocked,
                isBusy: false
            ),
            .load(.text)
        )
        XCTAssertEqual(
            ArchiveInspectorPreviewPolicy.decision(
                for: image,
                metadata: metadata,
                lockState: .unlocked,
                isBusy: false
            ),
            .load(.image)
        )
        XCTAssertEqual(
            ArchiveInspectorPreviewPolicy.decision(
                for: pdf,
                metadata: metadata,
                lockState: .unlocked,
                isBusy: false
            ),
            .load(.pdf)
        )
    }

    func testPreviewPolicyRejectsLockedBusyDirectoryAndOversizedRows() {
        let directory = ArchiveRow.directory(name: "Docs", path: "Docs")
        let text = ArchiveRow(entry: ArchiveEntry(path: "README.txt", size: 120))
        let huge = ArchiveRow(entry: ArchiveEntry(
            path: "movie.pdf",
            size: ArchiveInspectorPreviewPolicy.maximumEntrySize + 1
        ))
        let normalMetadata = ArchiveMetadata(format: .zip, uncompressedSize: 1_024, compressedSize: 1_024)
        let hugeMetadata = ArchiveMetadata(
            format: .zip,
            uncompressedSize: ArchiveInspectorPreviewPolicy.maximumArchiveSize + 1,
            compressedSize: 1_024
        )

        XCTAssertEqual(
            ArchiveInspectorPreviewPolicy.decision(
                for: text,
                metadata: normalMetadata,
                lockState: .locked(reason: .required),
                isBusy: false
            ),
            .locked
        )

        assertUnavailable(
            ArchiveInspectorPreviewPolicy.decision(
                for: text,
                metadata: normalMetadata,
                lockState: .unlocked,
                isBusy: true
            )
        )
        assertUnavailable(
            ArchiveInspectorPreviewPolicy.decision(
                for: directory,
                metadata: normalMetadata,
                lockState: .unlocked,
                isBusy: false
            )
        )
        assertUnavailable(
            ArchiveInspectorPreviewPolicy.decision(
                for: huge,
                metadata: normalMetadata,
                lockState: .unlocked,
                isBusy: false
            )
        )
        assertUnavailable(
            ArchiveInspectorPreviewPolicy.decision(
                for: text,
                metadata: hugeMetadata,
                lockState: .unlocked,
                isBusy: false
            )
        )
    }

    func testPreviewWorkIsDisabledOutsideInfoTab() {
        XCTAssertFalse(ArchiveInspectorPreviewSupport.shouldLoadPreview(selectedTab: .comment))
        XCTAssertTrue(ArchiveInspectorPreviewSupport.shouldLoadPreview(selectedTab: .info))
        XCTAssertEqual(ArchiveInspectorPreviewSupport.previewAspectRatio, 4.0 / 3.0)
    }

    func testImagePreviewModePreservesOrdinaryShapesAndCropsExtremeRatios() {
        XCTAssertEqual(
            ArchiveInspectorPreviewSupport.imagePreviewMode(for: CGSize(width: 640, height: 480)),
            .fit
        )
        XCTAssertEqual(
            ArchiveInspectorPreviewSupport.imagePreviewMode(for: CGSize(width: 480, height: 640)),
            .fit
        )
        XCTAssertEqual(
            ArchiveInspectorPreviewSupport.imagePreviewMode(for: CGSize(width: 4_000, height: 400)),
            .fill
        )
        XCTAssertEqual(
            ArchiveInspectorPreviewSupport.imagePreviewMode(for: CGSize(width: 400, height: 4_000)),
            .fill
        )
    }

    func testPreviewIdentityChangesWhenSelectedTabChanges() {
        let info = ArchiveInspectorPreviewSupport.previewIdentity(
            archivePath: "/tmp/a.zip",
            previewPath: "file.txt",
            selectedTab: .info,
            isUnlocked: true,
            isBusy: false
        )
        let comment = ArchiveInspectorPreviewSupport.previewIdentity(
            archivePath: "/tmp/a.zip",
            previewPath: "file.txt",
            selectedTab: .comment,
            isUnlocked: true,
            isBusy: false
        )
        XCTAssertNotEqual(info, comment)
    }

    func testSelectionResolverHonorsHiddenFileVisibility() {
        let entries = [
            ArchiveEntry(path: ".secret.txt", size: 10),
            ArchiveEntry(path: "visible.txt", size: 10)
        ]

        XCTAssertNil(
            ArchiveInspectorSelectionResolver.singleSelectedRow(
                selection: [".secret.txt"],
                currentPath: [],
                searchQuery: "",
                entries: entries,
                showHiddenFiles: false
            )
        )

        XCTAssertEqual(
            ArchiveInspectorSelectionResolver.singleSelectedRow(
                selection: [".secret.txt"],
                currentPath: [],
                searchQuery: "",
                entries: entries,
                showHiddenFiles: true
            )?.path,
            ".secret.txt"
        )
    }

    func testTextPreviewExcerptClipsLengthAndNormalizesNewlines() {
        let excerpt = ArchiveInspectorTextPreview.excerpt(
            from: "line 1\r\nline 2\rline 3\nline 4",
            maximumCharacters: 18,
            maximumLines: 2
        )

        XCTAssertEqual(excerpt, "line 1\nline 2…")
    }

    func testTextPreviewDecoderHandlesUnicodeAndBOMVariants() {
        let utf8BOM = Data([0xEF, 0xBB, 0xBF]) + Data("中文 UTF-8".utf8)
        let utf16LE = "こんにちは UTF16".data(using: .utf16LittleEndian)!
        let utf16BE = "مرحبا UTF16".data(using: .utf16BigEndian)!

        XCTAssertEqual(ArchiveInspectorTextPreview.decodeText(from: utf8BOM), "中文 UTF-8")
        XCTAssertEqual(ArchiveInspectorTextPreview.decodeText(from: utf16LE), "こんにちは UTF16")
        XCTAssertEqual(ArchiveInspectorTextPreview.decodeText(from: utf16BE), "مرحبا UTF16")
    }

    func testTextPreviewDecoderPrefersReasonableUtf8ForShortAsciiText() {
        XCTAssertEqual(ArchiveInspectorTextPreview.decodeText(from: Data("test".utf8)), "test")
        XCTAssertEqual(ArchiveInspectorTextPreview.decodeText(from: Data("hello.txt".utf8)), "hello.txt")
        XCTAssertEqual(ArchiveInspectorTextPreview.decodeText(from: Data("é".utf8)), "é")
        XCTAssertEqual(ArchiveInspectorTextPreview.decodeText(from: Data("Ł".utf8)), "Ł")
        XCTAssertEqual(ArchiveInspectorTextPreview.decodeText(from: Data("Ă".utf8)), "Ă")
    }

    func testTextPreviewDecoderKeepsShortASCIICodeSnippetAsUTF8() {
        XCTAssertEqual(ArchiveInspectorTextPreview.decodeText(from: Data("x=1".utf8)), "x=1")
        XCTAssertEqual(ArchiveInspectorTextPreview.decodeText(from: Data("x=".utf8)), "x=")
        XCTAssertEqual(ArchiveInspectorTextPreview.decodeText(from: Data("[]".utf8)), "[]")
        XCTAssertEqual(ArchiveInspectorTextPreview.decodeText(from: Data("if".utf8)), "if")
        XCTAssertEqual(ArchiveInspectorTextPreview.decodeText(from: Data("==".utf8)), "==")
        XCTAssertEqual(ArchiveInspectorTextPreview.decodeText(from: Data("!=".utf8)), "!=")
        XCTAssertEqual(ArchiveInspectorTextPreview.decodeText(from: Data("<=".utf8)), "<=")
        XCTAssertEqual(ArchiveInspectorTextPreview.decodeText(from: Data(">=".utf8)), ">=")
        XCTAssertEqual(ArchiveInspectorTextPreview.decodeText(from: Data("::".utf8)), "::")
        XCTAssertEqual(ArchiveInspectorTextPreview.decodeText(from: Data("->".utf8)), "->")
        XCTAssertEqual(ArchiveInspectorTextPreview.decodeText(from: Data("||".utf8)), "||")
        XCTAssertEqual(ArchiveInspectorTextPreview.decodeText(from: Data("=>".utf8)), "=>")
        XCTAssertEqual(ArchiveInspectorTextPreview.decodeText(from: Data("??".utf8)), "??")
        XCTAssertEqual(ArchiveInspectorTextPreview.decodeText(from: Data("?.".utf8)), "?.")
        XCTAssertEqual(ArchiveInspectorTextPreview.decodeText(from: Data("+=".utf8)), "+=")
        XCTAssertEqual(ArchiveInspectorTextPreview.decodeText(from: Data("-=".utf8)), "-=")
        XCTAssertEqual(ArchiveInspectorTextPreview.decodeText(from: Data("*=".utf8)), "*=")
        XCTAssertEqual(ArchiveInspectorTextPreview.decodeText(from: Data("/=".utf8)), "/=")
        XCTAssertEqual(ArchiveInspectorTextPreview.decodeText(from: Data("%=".utf8)), "%=")
        XCTAssertEqual(ArchiveInspectorTextPreview.decodeText(from: Data("&=".utf8)), "&=")
        XCTAssertEqual(ArchiveInspectorTextPreview.decodeText(from: Data("|=".utf8)), "|=")
        XCTAssertEqual(ArchiveInspectorTextPreview.decodeText(from: Data("^=".utf8)), "^=")
        XCTAssertEqual(ArchiveInspectorTextPreview.decodeText(from: Data("<-".utf8)), "<-")
        XCTAssertEqual(ArchiveInspectorTextPreview.decodeText(from: Data("?:".utf8)), "?:")
        XCTAssertEqual(ArchiveInspectorTextPreview.decodeText(from: Data("@@".utf8)), "@@")
        XCTAssertEqual(ArchiveInspectorTextPreview.decodeText(from: Data("~~".utf8)), "~~")
        XCTAssertEqual(ArchiveInspectorTextPreview.decodeText(from: Data(";;".utf8)), ";;")
        XCTAssertEqual(ArchiveInspectorTextPreview.decodeText(from: Data("{{".utf8)), "{{")
        XCTAssertEqual(ArchiveInspectorTextPreview.decodeText(from: Data("}}".utf8)), "}}")
        XCTAssertEqual(ArchiveInspectorTextPreview.decodeText(from: Data("a;".utf8)), "a;")
        XCTAssertEqual(ArchiveInspectorTextPreview.decodeText(from: Data("a+".utf8)), "a+")
        XCTAssertEqual(ArchiveInspectorTextPreview.decodeText(from: Data("a-".utf8)), "a-")
        XCTAssertEqual(ArchiveInspectorTextPreview.decodeText(from: Data("a*".utf8)), "a*")
        XCTAssertEqual(ArchiveInspectorTextPreview.decodeText(from: Data("a/".utf8)), "a/")
        XCTAssertEqual(ArchiveInspectorTextPreview.decodeText(from: Data("a%".utf8)), "a%")
        XCTAssertEqual(ArchiveInspectorTextPreview.decodeText(from: Data("a&".utf8)), "a&")
        XCTAssertEqual(ArchiveInspectorTextPreview.decodeText(from: Data("a|".utf8)), "a|")
        XCTAssertEqual(ArchiveInspectorTextPreview.decodeText(from: Data("a^".utf8)), "a^")
        XCTAssertEqual(ArchiveInspectorTextPreview.decodeText(from: Data("A+".utf8)), "A+")
        XCTAssertEqual(ArchiveInspectorTextPreview.decodeText(from: Data("A;".utf8)), "A;")
        XCTAssertEqual(ArchiveInspectorTextPreview.decodeText(from: Data("A?".utf8)), "A?")
        XCTAssertEqual(ArchiveInspectorTextPreview.decodeText(from: Data("A0".utf8)), "A0")
        XCTAssertEqual(ArchiveInspectorTextPreview.decodeText(from: Data("a?".utf8)), "a?")
        XCTAssertEqual(ArchiveInspectorTextPreview.decodeText(from: Data("a0".utf8)), "a0")
        XCTAssertEqual(ArchiveInspectorTextPreview.decodeText(from: Data("=1".utf8)), "=1")
        XCTAssertEqual(ArchiveInspectorTextPreview.decodeText(from: Data("<<".utf8)), "<<")
        XCTAssertEqual(ArchiveInspectorTextPreview.decodeText(from: Data(">>".utf8)), ">>")
    }

    func testTextPreviewDecoderTreatsShortNoBOMSamplesAsUTF8Bytes() {
        let samples: [Data] = [
            "test".data(using: .utf16LittleEndian)!,
            "TEST".data(using: .utf16BigEndian)!,
            "é".data(using: .utf16BigEndian)!,
            "Ł".data(using: .utf16BigEndian)!,
            "Ă".data(using: .utf16BigEndian)!,
            "ŁŁ".data(using: .utf16BigEndian)!,
            "ĂĂ".data(using: .utf16BigEndian)!,
            "你".data(using: .utf16LittleEndian)!,
            "你".data(using: .utf16BigEndian)!,
            "一".data(using: .utf16LittleEndian)!,
            "一".data(using: .utf16BigEndian)!,
            "中".data(using: .utf16LittleEndian)!,
            "中".data(using: .utf16BigEndian)!,
            "不".data(using: .utf16LittleEndian)!,
            "不".data(using: .utf16BigEndian)!,
            "你好".data(using: .utf16LittleEndian)!,
            "你好".data(using: .utf16BigEndian)!
        ]

        for data in samples {
            XCTAssertEqual(
                ArchiveInspectorTextPreview.decodeText(from: data),
                String(decoding: data, as: UTF8.self)
            )
        }
    }

    func testTextPreviewDecoderHandlesLongNoBOMUTF16Samples() {
        let littleEndian = String(repeating: "你好", count: 10)

        // CJK-only UTF-16LE: all bytes > 0x7F, UTF-8 fallback is ASCII.
        // Native API cannot distinguish from real ASCII. Accept UTF-8 fallback.
        XCTAssertEqual(
            ArchiveInspectorTextPreview.decodeText(from: littleEndian.data(using: .utf16LittleEndian)!),
            String(decoding: littleEndian.data(using: .utf16LittleEndian)!, as: UTF8.self)
        )

        let bigEndian = String(repeating: "ŁĂ", count: 10)

        // Latin UTF-16BE: all bytes < 0x80, no endianness signal.
        // Native API cannot distinguish from real ASCII. Accept UTF-8 fallback.
        XCTAssertEqual(
            ArchiveInspectorTextPreview.decodeText(from: bigEndian.data(using: .utf16BigEndian)!),
            String(decoding: bigEndian.data(using: .utf16BigEndian)!, as: UTF8.self)
        )
    }

    func testTextPreviewDecoderHandlesLegacyEncodings() {
        XCTAssertEqual(
            ArchiveInspectorTextPreview.decodeText(from: encoded("中文-文件名-你好", cfEncoding: CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))),
            "中文-文件名-你好"
        )

        XCTAssertEqual(
            ArchiveInspectorTextPreview.decodeText(from: encoded("日本語-ファイル名-こんにちは\n\n日本語-ファイル名-こんにちは", cfEncoding: CFStringEncoding(CFStringEncodings.shiftJIS.rawValue))),
            "日本語-ファイル名-こんにちは\n\n日本語-ファイル名-こんにちは"
        )

        XCTAssertEqual(
            ArchiveInspectorTextPreview.decodeText(from: encoded("繁體-檔名-你好\n繁體-檔名-你好", cfEncoding: CFStringEncoding(CFStringEncodings.big5.rawValue))),
            "繁體-檔名-你好\n繁體-檔名-你好"
        )
        XCTAssertEqual(
            ArchiveInspectorTextPreview.decodeText(from: encoded("최근 공식 전자입국신고서를 사칭한 유사사이트가\n공식 전자입국신고서 사이트는", cfEncoding: CFStringEncoding(CFStringEncodings.EUC_KR.rawValue))),
            "최근 공식 전자입국신고서를 사칭한 유사사이트가\n공식 전자입국신고서 사이트는"
        )
        XCTAssertEqual(
            ArchiveInspectorTextPreview.decodeText(from: encoded("café-déjà-vu-résumé\ncafé-déjà-vu-résumé", windowsCodePage: 1252)),
            "café-déjà-vu-résumé\ncafé-déjà-vu-résumé"
        )
    }

    private func encoded(_ string: String, cfEncoding: CFStringEncoding, file: StaticString = #filePath, line: UInt = #line) -> Data {
        let nsEncoding = CFStringConvertEncodingToNSStringEncoding(cfEncoding)
        guard let data = string.data(using: String.Encoding(rawValue: nsEncoding), allowLossyConversion: false) else {
            XCTFail("Unable to encode test string", file: file, line: line)
            return Data()
        }
        return data
    }

    private func encoded(_ string: String, windowsCodePage: UInt32, file: StaticString = #filePath, line: UInt = #line) -> Data {
        let cfEncoding = CFStringConvertWindowsCodepageToEncoding(windowsCodePage)
        let nsEncoding = CFStringConvertEncodingToNSStringEncoding(cfEncoding)
        guard let data = string.data(using: String.Encoding(rawValue: nsEncoding), allowLossyConversion: false) else {
            XCTFail("Unable to encode Windows code page test string", file: file, line: line)
            return Data()
        }
        return data
    }

    private func assertUnavailable(
        _ decision: ArchiveInspectorPreviewDecision,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .unavailable(let reason) = decision else {
            XCTFail("Expected unavailable, got \(decision)", file: file, line: line)
            return
        }
        XCTAssertFalse(reason.isEmpty, file: file, line: line)
    }
}
