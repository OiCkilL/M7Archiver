import CoreFoundation
import Foundation

struct FilenameEncodingDetector {
    struct Candidate: Equatable {
        let archiveEncoding: ArchiveEncoding
        let foundationEncoding: String.Encoding
    }

    struct DetectionResult: Equatable {
        let encoding: ArchiveEncoding
        let convertedString: String
    }

    static let defaultCandidates: [Candidate] = [
        Candidate(archiveEncoding: .shiftJIS, foundationEncoding: .shiftJIS),
        Candidate(archiveEncoding: .eucKR, foundationEncoding: stringEncoding(.EUC_KR)),
        Candidate(archiveEncoding: .big5, foundationEncoding: stringEncoding(.big5)),
        Candidate(archiveEncoding: .gb18030, foundationEncoding: stringEncoding(.GB_18030_2000)),
        Candidate(archiveEncoding: .cp437, foundationEncoding: stringEncoding(.dosLatinUS)),
        Candidate(archiveEncoding: .windows1252, foundationEncoding: .windowsCP1252),
        Candidate(archiveEncoding: .cp850, foundationEncoding: stringEncoding(.dosLatin1))
    ]

    private let candidates: [Candidate]

    init(candidates: [Candidate] = Self.defaultCandidates) {
        self.candidates = candidates
    }

    init(priority: [ArchiveEncoding]) {
        self.init(candidates: Self.candidates(for: priority))
    }

    private static func candidates(for priority: [ArchiveEncoding]) -> [Candidate] {
        let defaultByEncoding = Dictionary(uniqueKeysWithValues: defaultCandidates.map { ($0.archiveEncoding, $0) })
        return ArchiveEncoding.automaticDetectionCandidates(in: priority).compactMap { defaultByEncoding[$0] }
    }

    func detect(_ rawBytes: Data) -> DetectionResult? {
        guard !rawBytes.isEmpty else { return nil }
        guard String(data: rawBytes, encoding: .utf8) == nil else { return nil }

        var remainingCandidates = candidates
        while !remainingCandidates.isEmpty {
            var converted: NSString?
            var usedLossyConversion = ObjCBool(false)
            let detectedEncoding = NSString.stringEncoding(
                for: rawBytes,
                encodingOptions: [
                    .suggestedEncodingsKey: remainingCandidates.map { NSNumber(value: $0.foundationEncoding.rawValue) },
                    .useOnlySuggestedEncodingsKey: true,
                    .allowLossyKey: false
                ],
                convertedString: &converted,
                usedLossyConversion: &usedLossyConversion
            )

            guard let index = remainingCandidates.firstIndex(where: { $0.foundationEncoding.rawValue == detectedEncoding }) else {
                return nil
            }

            let candidate = remainingCandidates[index]
            if Self.isLatinCandidate(candidate), Self.hasLatinAmbiguity(in: candidates) {
                guard let latinCandidate = Self.latinTiebreakCandidate(for: rawBytes, candidates: candidates),
                      let string = String(data: rawBytes, encoding: latinCandidate.foundationEncoding),
                      string.data(using: latinCandidate.foundationEncoding) == rawBytes else {
                    return nil
                }
                return DetectionResult(encoding: latinCandidate.archiveEncoding, convertedString: string)
            }

            if let converted,
               !usedLossyConversion.boolValue {
                let string = String(converted)
                if string.data(using: candidate.foundationEncoding) == rawBytes {
                    return DetectionResult(encoding: candidate.archiveEncoding, convertedString: string)
                }
            }

            remainingCandidates.remove(at: index)
        }

        return nil
    }

    func detectEncoding(_ rawBytes: Data) -> ArchiveEncoding? {
        detect(rawBytes)?.encoding
    }

    private static func isLatinCandidate(_ candidate: Candidate) -> Bool {
        switch candidate.archiveEncoding {
        case .cp437, .windows1252, .cp850:
            return true
        default:
            return false
        }
    }

    private static func hasLatinAmbiguity(in candidates: [Candidate]) -> Bool {
        candidates.filter(isLatinCandidate).count >= 2
    }

    private static func latinTiebreakCandidate(for rawBytes: Data, candidates: [Candidate]) -> Candidate? {
        guard rawBytes.filter({ $0 > 0x7F }).count >= 8 else { return nil }

        let scored = candidates.compactMap { candidate -> (candidate: Candidate, score: Int)? in
            guard isLatinCandidate(candidate) else { return nil }
            let score = rawBytes.reduce(0) { total, byte in
                switch candidate.archiveEncoding {
                case .cp437:
                    return total + cp437SignalScore(byte)
                case .windows1252:
                    return total + cp1252SignalScore(byte)
                case .cp850:
                    return total + cp850SignalScore(byte)
                default:
                    return total
                }
            }
            return (candidate, score)
        }

        guard let best = scored.max(by: { $0.score < $1.score }), best.score > 0 else { return nil }
        guard scored.filter({ $0.score == best.score }).count == 1 else { return nil }
        if best.candidate.archiveEncoding == .cp850, best.score < 10 { return nil }
        return best.candidate
    }

    private static func cp1252SignalScore(_ byte: UInt8) -> Int {
        switch byte {
        case 0x80, 0x82...0x85, 0x88, 0x8B, 0x91...0x98, 0x9A:
            return 3
        case 0x89, 0x8A, 0x8C, 0x8E, 0x99, 0x9B...0x9F, 0xA0:
            return 1
        default:
            return 0
        }
    }

    private static func cp437SignalScore(_ byte: UInt8) -> Int {
        switch byte {
        case 0x81, 0x87, 0x8A, 0xA1, 0xA2, 0xA4, 0xE1:
            return 3
        case 0x82, 0x83, 0x85, 0x88, 0x89, 0x93, 0x94, 0x95, 0x96, 0x97,
             0xA0, 0xA3:
            return 1
        default:
            return 0
        }
    }

    private static func cp850SignalScore(_ byte: UInt8) -> Int {
        switch byte {
        case 0x9D:
            return 5
        default:
            return 0
        }
    }

    private static func stringEncoding(_ encoding: CFStringEncodings) -> String.Encoding {
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(encoding.rawValue)))
    }
}
