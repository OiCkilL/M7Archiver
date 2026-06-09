import Foundation
import NaturalLanguage
import CLibArchiveBridge

public enum LibArchiveError: Error, Equatable, Sendable {
    case cannotOpenArchive(String)
    case readFailed(String)
    case writeFailed(String)
    case unsupportedCreateFormat(ArchiveFormat)
    case missingSources
}

public struct LibArchiveEngine: ArchiveEngine {
    public let type: ArchiveEngineType = .libarchive
    private let detector: ArchiveTypeDetector
    private let beforeCreateArchive: (@Sendable () async -> Void)?
    private let beforeReadEntryList: (@Sendable (String?) -> Void)?

    public init(detector: ArchiveTypeDetector = ArchiveTypeDetector()) {
        self.detector = detector
        self.beforeCreateArchive = nil
        self.beforeReadEntryList = nil
    }

    init(
        detector: ArchiveTypeDetector = ArchiveTypeDetector(),
        beforeCreateArchive: (@Sendable () async -> Void)? = nil,
        beforeReadEntryList: (@Sendable (String?) -> Void)? = nil
    ) {
        self.detector = detector
        self.beforeCreateArchive = beforeCreateArchive
        self.beforeReadEntryList = beforeReadEntryList
    }

    public func listContents(of archiveURL: URL, options: ArchiveOperationOptions = ArchiveOperationOptions()) async throws -> [ArchiveEntry] {
        try checkCancellation(options)
        let password = password(for: archiveURL, operation: .listContents, provider: options.passwordProvider)
        let (entries, _, _) = try await readWithEncodingDetection(archiveURL, password: password, options: options)
        try checkCancellation(options)
        return entries
    }

    public func metadata(of archiveURL: URL, options: ArchiveOperationOptions = ArchiveOperationOptions()) async throws -> ArchiveMetadata {
        try checkCancellation(options)
        let password = password(for: archiveURL, operation: .metadata, provider: options.passwordProvider)
        let (entries, isEncrypted, detectedEncoding) = try await readWithEncodingDetection(archiveURL, password: password, options: options)
        try checkCancellation(options)

        return ArchiveMetadata(
            format: try detector.detect(fileURL: archiveURL) ?? .zip,
            comment: nil,
            encoding: detectedEncoding,
            isEncrypted: isEncrypted || entries.contains(where: \.isEncrypted),
            isMultiVolume: false,
            entriesCount: entries.count,
            uncompressedSize: entries.compactMap(\.size).reduce(0, +),
            compressedSize: entries.compactMap(\.packedSize).reduce(0, +)
        )
    }

    public func testArchive(_ archiveURL: URL, options: ArchiveOperationOptions = ArchiveOperationOptions()) async throws -> ArchiveOperationResult {
        try checkCancellation(options)
        let password = password(for: archiveURL, operation: .testArchive, provider: options.passwordProvider)
        // Detect encoding via lightweight header-only list first.
        let (_, _, detectedEncoding) = try await readWithEncodingDetection(archiveURL, password: password, options: options)
        try checkCancellation(options)
        // Run the actual CRC verification with the detected encoding.
        let charset = detectedEncoding?.libarchiveCharset ?? cEncoding(for: options)
        let list = archiveURL.path.withCString { archivePath in
            password.withOptionalCString { pwd in
                charset.withOptionalCString { ch in
                    m7_archive_test(archivePath, pwd, ch)
                }
            }
        }
        defer { m7_archive_entry_list_free(list) }
        try throwIfNeeded(list.error)
        try checkCancellation(options)
        return ArchiveOperationResult(operation: .testArchive, archiveURL: archiveURL, entries: entries(from: list))
    }

    /// Returns the libarchive charset name from `options.encoding`, or nil
    /// when encoding is `.automatic` / `.utf8`.
    private func cEncoding(for options: ArchiveOperationOptions) -> String? {
        options.encoding?.libarchiveCharset
    }

    private static func automaticEncodingPriority(for options: ArchiveOperationOptions) -> [ArchiveEncoding] {
        guard let priority = options.automaticEncodingPriority else {
            return ArchiveEncoding.defaultAutomaticDetectionPriority
        }
        return ArchiveEncoding.automaticDetectionCandidates(in: priority)
    }

    private func checkCancellation(_ options: ArchiveOperationOptions) throws {
        if Task.isCancelled || options.isCancelled?() == true {
            throw CancellationError()
        }
    }

    /// Reads the archive's entry list, optionally applying charset conversion.
    /// When `charset` is nil, no `zip:hdrcharset=` option is set.
    private func readEntryList(archiveURL: URL, password: String?, charset: String?) -> M7ArchiveEntryList {
        beforeReadEntryList?(charset)
        return archiveURL.path.withCString { archivePath in
            password.withOptionalCString { pwd in
                charset.withOptionalCString { ch in
                    m7_archive_list(archivePath, pwd, ch)
                }
            }
        }
    }

    /// Reads archive entries with automatic encoding detection.
    private func readWithEncodingDetection(
        _ archiveURL: URL,
        password: String?,
        options: ArchiveOperationOptions
    ) async throws -> (entries: [ArchiveEntry], isEncrypted: Bool, detectedEncoding: ArchiveEncoding?) {
        let archiveFormat = try? detector.detect(fileURL: archiveURL)
        let isZIP = archiveFormat == .zip

        // Explicit UTF-8 on ZIP bypasses legacy detection.  For non-ZIP formats,
        // keep the previous nil-charset automatic path.
        if options.encoding == .utf8 && isZIP {
            try checkCancellation(options)
            let list = readEntryList(archiveURL: archiveURL, password: password, charset: nil)
            defer { m7_archive_entry_list_free(list) }
            try throwIfNeeded(list.error)
            try checkCancellation(options)
            return (entries(from: list), list.isEncrypted, nil)
        }

        // Explicit legacy encoding — use it directly.
        if let forcedCharset = cEncoding(for: options) {
            try checkCancellation(options)
            let list = readEntryList(archiveURL: archiveURL, password: password, charset: forcedCharset)
            defer { m7_archive_entry_list_free(list) }
            try throwIfNeeded(list.error)
            try checkCancellation(options)
            return (entries(from: list), list.isEncrypted, options.encoding)
        }

        // Automatic mode: try without encoding first.
        try checkCancellation(options)
        let first = readEntryList(archiveURL: archiveURL, password: password, charset: nil)
        try throwIfNeeded(first.error)
        try checkCancellation(options)
        let firstEntries = entries(from: first)

        guard isZIP else {
            return try readWithScoringFallback(
                archiveURL,
                password: password,
                options: options,
                first: first,
                firstEntries: firstEntries
            )
        }

        return try readZIPWithRawEncodingDetection(
            archiveURL,
            password: password,
            options: options,
            first: first,
            firstEntries: firstEntries
        )
    }

    private func readZIPWithRawEncodingDetection(
        _ archiveURL: URL,
        password: String?,
        options: ArchiveOperationOptions,
        first: M7ArchiveEntryList,
        firstEntries: [ArchiveEntry]
    ) throws -> (entries: [ArchiveEntry], isEncrypted: Bool, detectedEncoding: ArchiveEncoding?) {
        guard let rawNames = ZipRawNameScanner.rawNamesIfAvailable(in: archiveURL) else {
            return try readWithScoringFallback(
                archiveURL,
                password: password,
                options: options,
                first: first,
                firstEntries: firstEntries
            )
        }

        guard let sample = ZipRawNameScanner.legacyDetectionSample(from: rawNames) else {
            if !first.needsEncodingFix && Self.pathsAreClean(firstEntries) {
                defer { m7_archive_entry_list_free(first) }
                return (firstEntries, first.isEncrypted, nil)
            }
            return try readWithScoringFallback(
                archiveURL,
                password: password,
                options: options,
                first: first,
                firstEntries: firstEntries
            )
        }

        if let detected = FilenameEncodingDetector(priority: Self.automaticEncodingPriority(for: options)).detect(sample),
           let charset = detected.encoding.libarchiveCharset {
            try checkCancellation(options)
            let list = readEntryList(archiveURL: archiveURL, password: password, charset: charset)
            if list.error == nil && !list.needsEncodingFix {
                let detectedEntries = entries(from: list)
                if Self.detectedEntriesPassQualityGate(detectedEntries, encoding: detected.encoding) {
                    m7_archive_entry_list_free(first)
                    defer { m7_archive_entry_list_free(list) }
                    return (detectedEntries, list.isEncrypted, detected.encoding)
                }
            }
            m7_archive_entry_list_free(list)
        }

        return try readWithScoringFallback(
            archiveURL,
            password: password,
            options: options,
            first: first,
            firstEntries: firstEntries
        )
    }

    /// Hybrid fallback retained for scanner failure, detector ambiguity, and
    /// quality-gate rejection. Remove it only when fixtures prove automatic
    /// detection no longer needs the scoring path.
    private func readWithScoringFallback(
        _ archiveURL: URL,
        password: String?,
        options: ArchiveOperationOptions,
        first: M7ArchiveEntryList,
        firstEntries: [ArchiveEntry]
    ) throws -> (entries: [ArchiveEntry], isEncrypted: Bool, detectedEncoding: ArchiveEncoding?) {
        guard first.needsEncodingFix else {
            defer { m7_archive_entry_list_free(first) }
            return (firstEntries, first.isEncrypted, nil)
        }

        // Skip auto-detection when there is not enough non-ASCII content
        // to reliably identify the encoding.  Fewer than ~8 raw bytes of
        // non-ASCII data across all entry paths means detection would be
        // guessing — not worth the candidate-encoding trials and NLP cost.
        let nonASCIIScalarCount = firstEntries
            .flatMap { $0.path.unicodeScalars }
            .filter { $0.value > 0x7F }
            .count
        guard nonASCIIScalarCount >= 4 else {
            defer { m7_archive_entry_list_free(first) }
            return (firstEntries, first.isEncrypted, nil)
        }

        // Try the configured candidate encodings. Collect every candidate that produces
        // valid UTF-8 pathnames for all entries, then pick the best one.
        // Multiple CJK encodings can "accept" the same raw bytes as valid
        // sequences while producing different characters, so we need a
        // quality score to break ties.
        var bestCandidate: ArchiveEncoding?
        var bestEntries: [ArchiveEntry]?
        var bestList: M7ArchiveEntryList?
        var bestScore = Int.min

        for candidate in Self.automaticEncodingPriority(for: options) {
            try checkCancellation(options)
            guard let charset = candidate.libarchiveCharset else { continue }
            let list = readEntryList(archiveURL: archiveURL, password: password, charset: charset)
            guard list.error == nil && !list.needsEncodingFix else {
                m7_archive_entry_list_free(list)
                continue
            }
            let entries = entries(from: list)
            let score = Self.decodeQuality(entries, encoding: candidate)
            if score > bestScore {
                if let old = bestList { m7_archive_entry_list_free(old) }
                bestScore = score
                bestCandidate = candidate
                bestEntries = entries
                bestList = list
            } else if score == bestScore {
                if let old = bestList { m7_archive_entry_list_free(old) }
                bestCandidate = nil
                bestEntries = nil
                bestList = nil
                m7_archive_entry_list_free(list)
            } else {
                m7_archive_entry_list_free(list)
            }
        }

        m7_archive_entry_list_free(first)

        if let candidate = bestCandidate, let entries = bestEntries, let list = bestList {
            defer { m7_archive_entry_list_free(list) }
            return (entries, list.isEncrypted, candidate)
        }

        // No candidate resolved the garbled paths. Return the original
        // entries as-is so the user can still browse (paths may be garbled).
        try checkCancellation(options)
        let fallback = readEntryList(archiveURL: archiveURL, password: password, charset: nil)
        defer { m7_archive_entry_list_free(fallback) }
        try throwIfNeeded(fallback.error)
        try checkCancellation(options)
        return (entries(from: fallback), fallback.isEncrypted, nil)
    }

    private static func detectedEntriesPassQualityGate(_ entries: [ArchiveEntry], encoding: ArchiveEncoding) -> Bool {
        guard pathsAreClean(entries) else { return false }

        let text = entries.map(\.path).joined(separator: " ")
        let hasKana = text.unicodeScalars.contains { scalar in
            (0x3040...0x309F).contains(scalar.value) ||
            (0x30A0...0x30FF).contains(scalar.value) ||
            (0xFF61...0xFF9F).contains(scalar.value)
        }
        let hasHangul = text.unicodeScalars.contains { scalar in
            (0xAC00...0xD7AF).contains(scalar.value) ||
            (0x1100...0x11FF).contains(scalar.value) ||
            (0x3130...0x318F).contains(scalar.value)
        }
        let hasCJK = text.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value) ||
            (0x3400...0x4DBF).contains(scalar.value) ||
            (0x20000...0x2A6DF).contains(scalar.value)
        }

        switch encoding {
        case .shiftJIS:
            return hasKana || hasCJK
        case .eucKR:
            return hasHangul
        case .big5, .gb18030:
            return hasCJK
        case .cp437, .windows1252, .cp850:
            return !hasKana && !hasHangul && !hasCJK
        case .automatic, .utf8:
            return true
        }
    }

    private static func pathsAreClean(_ entries: [ArchiveEntry]) -> Bool {
        entries.allSatisfy { entry in
            entry.path.unicodeScalars.allSatisfy { scalar in
                scalar.value != 0xFFFD &&
                !isControlScalar(scalar.value) &&
                !isNoncharacter(scalar.value)
            }
        }
    }

    private static func isControlScalar(_ value: UInt32) -> Bool {
        (0x00...0x1F).contains(value) || (0x7F...0x9F).contains(value)
    }

    private static func isNoncharacter(_ value: UInt32) -> Bool {
        (0xFDD0...0xFDEF).contains(value) || (value & 0xFFFE) == 0xFFFE
    }

    /// Scores decoded entries against the expected character profile for
    /// a given encoding. Encoding-specific penalties detect common
    /// cross-encoding false positives (e.g. EUC-KR decoding Chinese bytes
    /// as Hangul Jamo; Shift-JIS eating Latin high bytes as CJK).
    private static func decodeQuality(_ entries: [ArchiveEntry], encoding: ArchiveEncoding) -> Int {
        let text = entries.map(\.path).joined(separator: " ")
        guard !text.isEmpty else { return Int.min }

        var score = 0

        // Character class flags.
        let hasKana = text.unicodeScalars.contains { scalar in
            (0x3040...0x309F).contains(scalar.value) ||  // Hiragana
            (0x30A0...0x30FF).contains(scalar.value) ||  // Katakana
            (0xFF61...0xFF9F).contains(scalar.value)     // Halfwidth Katakana (CP932 single-byte)
        }
        let hasHangul = text.unicodeScalars.contains { scalar in
            (0xAC00...0xD7AF).contains(scalar.value) ||  // Hangul Syllables
            (0x1100...0x11FF).contains(scalar.value) ||  // Hangul Jamo
            (0x3130...0x318F).contains(scalar.value)     // Hangul Compatibility Jamo
        }
        let hasCJK = text.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value) ||  // CJK Unified
            (0x3400...0x4DBF).contains(scalar.value) ||  // CJK Extension A
            (0x20000...0x2A6DF).contains(scalar.value)   // CJK Extension B
        }

        // PUA penalty — for Shift-JIS, PUA characters are legitimate CP932
        // gaiji (vendor-specific characters).  For all other encodings, PUA
        // is a strong garbled-text signal.
        let puaCount = text.unicodeScalars.filter { (0xE000...0xF8FF).contains($0.value) }.count
        if encoding != .shiftJIS {
            score -= puaCount * 50
        }

        // Empty-path penalty — some encodings produce empty strings for
        // incompatible byte sequences.
        let emptyCount = entries.filter { $0.path.isEmpty }.count
        score -= emptyCount * 200

        // Characters atypical in filenames: box-drawing, geometric shapes,
        // math symbols, Greek letters — common artifacts from wrong decoding.
        let unusualCount = text.unicodeScalars.filter { scalar in
            (0x2500...0x259F).contains(scalar.value) ||  // Box Drawing
            (0x25A0...0x25FF).contains(scalar.value) ||  // Geometric Shapes
            (0x2200...0x22FF).contains(scalar.value) ||  // Mathematical Operators
            (0x0370...0x03FF).contains(scalar.value)     // Greek and Coptic
        }.count
        score -= unusualCount * 3

        // NLLanguageRecognizer on non-ASCII entries, stripped of ASCII-only
        // path components and file extensions.  ASCII entries (e.g. "INFO.txt")
        // and components (e.g. "/hello" in "中文/hello.txt") provide no
        // encoding signal and dilute NLL confidence for short CJK filenames.
        let langText = entries.map(\.path)
            .filter { $0.contains(where: { !$0.isASCII }) }
            .flatMap { $0.components(separatedBy: "/") }
            .filter { $0.contains(where: { !$0.isASCII }) }
            .map { ($0 as NSString).deletingPathExtension }
            .joined(separator: " ")
        let recognizer = NLLanguageRecognizer()
        if !langText.isEmpty {
            recognizer.processString(langText)
        }
        let hypotheses = recognizer.languageHypotheses(withMaximum: 5)
        let zhHansConf = hypotheses[.simplifiedChinese] ?? 0
        let zhHantConf = hypotheses[.traditionalChinese] ?? 0
        let jaConf = hypotheses[.japanese] ?? 0

        // Counts of encoding-specific script characters.
        // Halfwidth katakana is weighted lower than fullwidth: it can appear
        // as a correct-decoding artifact (CP932 single-byte kana range) but
        // also as wrong-decoding noise when non-Japanese bytes happen to
        // fall in the halfwidth Unicode block.
        let fullwidthKanaCount = text.unicodeScalars.filter { scalar in
            (0x3040...0x309F).contains(scalar.value) ||
            (0x30A0...0x30FF).contains(scalar.value)
        }.count
        let halfwidthKanaCount = text.unicodeScalars.filter { scalar in
            (0xFF61...0xFF9F).contains(scalar.value)
        }.count
        let hangulCount = text.unicodeScalars.filter { scalar in
            (0xAC00...0xD7AF).contains(scalar.value) ||
            (0x1100...0x11FF).contains(scalar.value) ||
            (0x3130...0x318F).contains(scalar.value)
        }.count
        let cjkCount = text.unicodeScalars.filter { scalar in
            (0x4E00...0x9FFF).contains(scalar.value) ||
            (0x3400...0x4DBF).contains(scalar.value) ||
            (0x20000...0x2A6DF).contains(scalar.value)
        }.count

        // Any encoding that produces CJK/Kana/Hangul characters is more
        // likely correct than a Latin interpretation of the same bytes.
        // This base bonus prevents Latin encodings from winning when the
        // decoded text is mostly ASCII with only a few CJK characters
        // (NLLanguageRecognizer can't identify the language from sparse CJK).
        // PUA characters in Shift-JIS are CP932 gaiji (vendor-specific),
        // also a positive signal.
        if hasCJK || hasKana || hasHangul || (encoding == .shiftJIS && puaCount > 0) { score += 40 }

        switch encoding {
        case .shiftJIS:
            // Japanese text almost always mixes kanji and kana.
            // Scale kana bonus by count — a single kana in mostly-ASCII
            // text is more likely a false positive.  Halfwidth katakana
            // gets lower weight because it more often appears as artifact
            // from wrong CJK decoding (many non-Japanese byte pairs fall
            // in the CP932 single-byte halfwidth range 0xA1-0xDF).
            score += min(fullwidthKanaCount * 30 + halfwidthKanaCount * 8, 100)
            // Japanese kanji-only filenames (e.g. 日本語.txt) get no kana
            // bonus; CJK presence is still a positive signal for Shift-JIS.
            if hasCJK && fullwidthKanaCount == 0 && halfwidthKanaCount == 0 { score += 15 }
            // PUA characters in Shift-JIS are CP932 gaiji (vendor-specific
            // characters).  Their presence is a strong Shift-JIS signal.
            score += min(puaCount * 15, 50)
            if hasHangul { score -= 50 }   // Hangul in Shift-JIS output = wrong
            score += Int(jaConf * 40)

        case .eucKR:
            // Real Korean text is all-Hangul (no CJK ideographs).
            // Mixed CJK + Hangul means Chinese bytes decoded as Korean.
            // Kana in EUC-KR output is a strong artifact signal (hiragana
            // has no business appearing in Korean-encoded text).
            if hasKana { score -= 30 }
            if hasHangul && !hasCJK { score += min(hangulCount * 20, 80) }
            if hasHangul && hasCJK { score -= 100 }
            if !hasHangul { score -= 100 }

        case .big5:
            // Traditional Chinese: high zh-Hant, low zh-Hans.
            // A meaningful zh-Hans signal suggests GB18030 bytes, not Big5.
            // NLL bonus requires 3+ CJK chars: 2 chars with perfect NLL
            // (e.g. Big5 decoding halfwidth-kana bytes as "黃債") is too
            // weak a signal to outweigh other encodings.
            if hasKana { score -= 60 }
            if hasHangul { score -= 60 }
            score += min(cjkCount * 10, 40)
            if cjkCount >= 3 {
                score += min(Int(zhHantConf * 50), 50)
            }
            if zhHansConf > 0.25 { score -= 60 }

        case .gb18030:
            // Simplified Chinese; also the greediest CJK encoding.
            // zh-Hant gets flat low weight since GB18030 producing
            // Traditional Chinese text is a false-positive signal.
            if hasKana { score -= 60 }
            if hasHangul { score -= 60 }
            score += min(cjkCount * 10, 30)
            if cjkCount >= 3 {
                score += min(Int(zhHansConf * 40), 40)
            }
            score += Int(zhHantConf * 20)

        case .cp437, .windows1252, .cp850:
            // Latin encodings — should not produce CJK, Kana, or Hangul.
            if hasCJK { score -= 80 }
            if hasKana { score -= 80 }
            if hasHangul { score -= 80 }
            if !hasCJK && !hasKana && !hasHangul { score += 30 }

        default:
            break
        }

        return score
    }

    public func extract(_ archiveURL: URL, to destinationURL: URL, options: ArchiveOperationOptions = ArchiveOperationOptions()) async throws -> ArchiveOperationResult {
        let service = ArchiveExtractionService(engine: self)
        return try await service.extract(archiveURL, to: destinationURL, options: options)
    }

    func extractDirectly(_ archiveURL: URL, to destinationURL: URL, options: ArchiveOperationOptions = ArchiveOperationOptions()) async throws -> ArchiveOperationResult {
        try checkCancellation(options)
        try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        let password = password(for: archiveURL, operation: .extract, provider: options.passwordProvider)
        let (entries, _, detectedEncoding) = try await readWithEncodingDetection(archiveURL, password: password, options: options)
        for entry in entries {
            try checkCancellation(options)
            _ = try ArchivePathValidator.validatedOutputURL(for: entry.path, in: destinationURL)
        }

        let totalEntries = Int64(entries.count)
        let progressPtr = UnsafeMutablePointer<M7ExtractProgress>.allocate(capacity: 1)
        progressPtr.pointee = M7ExtractProgress(
            current: 0, cancel_flag: 0, total: totalEntries, skipped: 0, skipped_paths: nil
        )
        defer { progressPtr.deallocate() }

        // Monitor progress from the C bridge and forward to the caller.
        let reader = _UnsafeProgressReader(ptr: progressPtr)
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

        let charset = detectedEncoding?.libarchiveCharset ?? cEncoding(for: options)
        var error: UnsafeMutablePointer<CChar>?
        let result = archiveURL.path.withCString { archivePath in
            destinationURL.path.withCString { destinationPath in
                password.withOptionalCString { pwd in
                    charset.withOptionalCString { ch in
                        m7_archive_extract(archivePath, destinationPath, pwd, ch, &error, progressPtr)
                    }
                }
            }
        }
        monitor.cancel()
        await monitor.value
        defer { m7_archive_string_free(error) }
        try checkCancellation(options)

        if result < 0 {
            throw LibArchiveError.readFailed(error.map { String(cString: $0) } ?? "Unknown extraction error")
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
                        reason: "Data corruption (CRC error or invalid data)"
                    ))
                }
                m7_archive_string_free(cPath)
            }
            var detail = "Skipped \(skipped) corrupted file(s) during extraction"
            let fileNames = skippedEntries.map(\.path)
            if !fileNames.isEmpty {
                detail += ": " + fileNames.joined(separator: ", ")
            }
            warnings.append(detail)
        }

        return ArchiveOperationResult(
            operation: .extract,
            archiveURL: archiveURL,
            destinationURL: destinationURL,
            entries: entries,
            warnings: warnings,
            skippedEntries: skippedEntries
        )
    }

    /// Bridging wrapper so the monitoring Task can read `M7ExtractProgress`
    /// without capturing the non-Sendable `UnsafeMutablePointer` directly.
    private final class _UnsafeProgressReader: @unchecked Sendable {
        private let ptr: UnsafeMutablePointer<M7ExtractProgress>
        init(ptr: UnsafeMutablePointer<M7ExtractProgress>) { self.ptr = ptr }
        var current: Int64 { ptr.pointee.current }
        var total: Int64 { ptr.pointee.total }
        func cancel() { ptr.pointee.cancel_flag = 1 }
    }

    public func createArchive(from sourceURLs: [URL], to archiveURL: URL, profile: CompressionProfile, password: String?, encryptionMethod: String?, options: ArchiveOperationOptions = ArchiveOperationOptions()) async throws -> ArchiveOperationResult {
        try checkCancellation(options)
        guard profile.format == .zip else {
            throw LibArchiveError.unsupportedCreateFormat(profile.format)
        }

        let matcher = IgnoreRuleMatcher(rules: profile.ignoreRules)
        let sources = try expandedSourceEntries(from: sourceURLs, matcher: matcher, options: options)
        guard !sources.isEmpty else { throw LibArchiveError.missingSources }
        try checkCancellation(options)
        let fileManager = FileManager.default
        let temporaryArchiveURL = archiveURL
            .deletingLastPathComponent()
            .appendingPathComponent(".m7archiver-create-\(UUID().uuidString)-\(archiveURL.lastPathComponent)")
        defer {
            if fileManager.fileExists(atPath: temporaryArchiveURL.path) {
                try? fileManager.removeItem(at: temporaryArchiveURL)
            }
        }
        let destinationExisted = fileManager.fileExists(atPath: archiveURL.path)
        var paths = sources.map(\.source.path)
        var entryPaths = sources.map(\.entryPath)
        let charset = profile.filenameEncoding?.libarchiveZipWriteCharset
        if let beforeCreateArchive {
            await beforeCreateArchive()
        }
        try checkCancellation(options)
        var error: UnsafeMutablePointer<CChar>?
        let result = temporaryArchiveURL.path.withCString { archivePath in
            paths.withUnsafeMutableBufferPointer { pathBuffer in
                entryPaths.withUnsafeMutableBufferPointer { entryBuffer in
                    var cStrings = pathBuffer.map { strdup($0) }
                    var cEntryStrings = entryBuffer.map { strdup($0) }
                    defer {
                        cStrings.forEach { free($0) }
                        cEntryStrings.forEach { free($0) }
                    }
                    return cStrings.withUnsafeMutableBufferPointer { sourcePointer in
                        cEntryStrings.withUnsafeMutableBufferPointer { entryPointer in
                            charset.withOptionalCString { encoding in
                                encryptionMethod.withOptionalCString { encryption in
                                    password.withOptionalCString { pwd in
                                        m7_archive_create_zip(
                                            archivePath,
                                            sourcePointer.baseAddress,
                                            entryPointer.baseAddress,
                                            Int32(sourcePointer.count),
                                            Int32(profile.level.rawValue),
                                            encoding,
                                            encryption,
                                            pwd,
                                            &error
                                        )
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        defer { m7_archive_string_free(error) }
        try checkCancellation(options)
        if result < 0 {
            throw LibArchiveError.writeFailed(error.map { String(cString: $0) } ?? "Unknown archive creation error")
        }

        if destinationExisted {
            _ = try fileManager.replaceItemAt(archiveURL, withItemAt: temporaryArchiveURL)
        } else {
            try fileManager.moveItem(at: temporaryArchiveURL, to: archiveURL)
        }

        return ArchiveOperationResult(operation: .create, archiveURL: archiveURL, outputURLs: [archiveURL])
    }

    private func expandedSourceEntries(from sourceURLs: [URL], matcher: IgnoreRuleMatcher, options: ArchiveOperationOptions) throws -> [(source: URL, entryPath: String)] {
        let fileManager = FileManager.default
        var result: [(source: URL, entryPath: String)] = []

        for source in sourceURLs {
            try checkCancellation(options)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory) else { continue }
            let checkedSource = isDirectory.boolValue ? URL(fileURLWithPath: source.path, isDirectory: true) : source
            guard !matcher.shouldIgnore(checkedSource) else { continue }
            if isDirectory.boolValue {
                let rootName = source.lastPathComponent.precomposedStringWithCanonicalMapping
                result.append((source, rootName + "/"))
                let rootPath = source.resolvingSymlinksInPath().path
                let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey]
                guard let enumerator = fileManager.enumerator(
                    at: source,
                    includingPropertiesForKeys: Array(resourceKeys),
                    options: []
                ) else { continue }
                for case let child as URL in enumerator {
                    try checkCancellation(options)
                    let values = try child.resourceValues(forKeys: resourceKeys)
                    if matcher.shouldIgnore(child) {
                        if values.isDirectory == true {
                            enumerator.skipDescendants()
                        }
                        continue
                    }
                    let childPath = child.resolvingSymlinksInPath().path
                    guard childPath.hasPrefix(rootPath + "/") else { continue }
                    let relative = String(childPath.dropFirst(rootPath.count + 1)).precomposedStringWithCanonicalMapping
                    guard !relative.isEmpty else { continue }
                    if values.isDirectory == true {
                        result.append((child, rootName + "/" + relative + "/"))
                    } else if values.isRegularFile == true {
                        result.append((child, rootName + "/" + relative))
                    }
                }
            } else {
                result.append((source, source.lastPathComponent.precomposedStringWithCanonicalMapping))
            }
        }

        return result
    }

    public func statusStream() async -> AsyncStream<ArchiveEngineStatus> {
        AsyncStream { continuation in
            continuation.yield(.idle)
            continuation.finish()
        }
    }

    public func cancel() async {}

    private func entries(from list: M7ArchiveEntryList) -> [ArchiveEntry] {
        guard let entries = list.entries else { return [] }
        return (0..<Int(list.count)).map { index in
            let entry = entries[index]
            let path = entry.path.map { String(cString: $0) } ?? ""
            return ArchiveEntry(
                path: path,
                size: entry.size >= 0 ? entry.size : nil,
                modifiedAt: entry.modifiedAt >= 0 ? Date(timeIntervalSince1970: TimeInterval(entry.modifiedAt)) : nil,
                isDirectory: entry.isDirectory,
                isEncrypted: entry.isEncrypted
            )
        }
    }

    private func throwIfNeeded(_ error: UnsafeMutablePointer<CChar>?) throws {
        if let error {
            throw LibArchiveError.readFailed(String(cString: error))
        }
    }

    private func password(for archiveURL: URL, operation: ArchiveOperation, provider: ArchivePasswordProvider?) -> String? {
        guard let provider else { return nil }
        let semaphore = DispatchSemaphore(value: 0)
        final class Box: @unchecked Sendable { var value: String? }
        let box = Box()
        let request = ArchivePasswordRequest(archiveURL: archiveURL, operation: operation, attempt: 1, reason: .required)
        Task {
            box.value = await provider(request)
            semaphore.signal()
        }
        semaphore.wait()
        return box.value
    }
}

private extension Optional where Wrapped == String {
    func withOptionalCString<T>(_ body: (UnsafePointer<CChar>?) -> T) -> T {
        switch self {
        case .some(let value):
            return value.withCString(body)
        case .none:
            return body(nil)
        }
    }
}
