import Foundation
import CLibArchiveBridge

struct ZipRawNameScanner {
    static let utf8Flag: UInt16 = 0x0800

    struct RawName: Equatable {
        let bytes: Data
        let flags: UInt16
        let unicodePathBytes: Data?

        var hasUTF8Flag: Bool { (flags & ZipRawNameScanner.utf8Flag) != 0 }
        var hasValidUnicodePath: Bool { unicodePathBytes != nil }
    }

    enum ScanError: Error, Equatable {
        case scannerFailed(String)
    }

    static func rawNames(in archiveURL: URL) throws -> [RawName] {
        let list = archiveURL.path.withCString { archivePath in
            m7_zip_read_raw_names(archivePath)
        }
        defer { m7_zip_raw_name_list_free(list) }

        if list.hasError {
            if let errorPtr = list.error {
                throw ScanError.scannerFailed(String(cString: errorPtr))
            } else {
                throw ScanError.scannerFailed("Scanner encountered an internal error")
            }
        }

        guard let names = list.names else { return [] }
        return (0..<Int(list.count)).map { index in
            let raw = names[index]
            let bytes: Data
            if let pointer = raw.bytes, raw.byteCount > 0 {
                bytes = Data(bytes: pointer, count: Int(raw.byteCount))
            } else {
                bytes = Data()
            }

            let unicodePathBytes: Data?
            if raw.hasValidUnicodePath,
               let pointer = raw.unicodePathBytes,
               raw.unicodePathByteCount > 0 {
                unicodePathBytes = Data(bytes: pointer, count: Int(raw.unicodePathByteCount))
            } else {
                unicodePathBytes = nil
            }

            return RawName(bytes: bytes, flags: raw.flags, unicodePathBytes: unicodePathBytes)
        }
    }

    static func rawNamesIfAvailable(in archiveURL: URL) -> [RawName]? {
        try? rawNames(in: archiveURL)
    }

    static func legacyDetectionSample(from names: [RawName]) -> Data? {
        let sampleNames = names
            .filter { !$0.hasUTF8Flag && !$0.hasValidUnicodePath && !$0.bytes.isValidUTF8 }
            .map(\.bytes)
            .filter { $0.contains { $0 > 0x7F } }

        guard !sampleNames.isEmpty else { return nil }

        var sample = Data()
        for (index, bytes) in sampleNames.enumerated() {
            if index > 0 { sample.append(0x0A) }
            sample.append(bytes)
        }
        return sample
    }
}

private extension Data {
    var isValidUTF8: Bool {
        String(data: self, encoding: .utf8) != nil
    }
}
