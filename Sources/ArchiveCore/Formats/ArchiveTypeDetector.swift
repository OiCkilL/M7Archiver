import Foundation

public struct ArchiveTypeDetector: Sendable {
    private let catalog: ArchiveFormatCatalog

    public init(catalog: ArchiveFormatCatalog = .shared) {
        self.catalog = catalog
    }

    public func detect(fileURL: URL) throws -> ArchiveFormat? {
        if let compound = detectCompound(fileName: fileURL.lastPathComponent) {
            return compound.id
        }

        if let byMagic = try detectByMagicNumber(fileURL: fileURL) {
            return byMagic
        }

        return detectByExtension(fileName: fileURL.lastPathComponent)
    }

    public func detectByExtension(fileName: String) -> ArchiveFormat? {
        if let compound = detectCompound(fileName: fileName) {
            return compound.id
        }

        let ext = (fileName as NSString).pathExtension
        return catalog.definition(forExtension: ext)?.id
    }

    public func detectCompound(fileName: String) -> CompoundArchiveFormat? {
        catalog.compoundDefinition(forFileName: fileName)
    }

    public func detectByMagicNumber(fileURL: URL) throws -> ArchiveFormat? {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        let head = try handle.read(upToCount: 65_536) ?? Data()
        let fileSize = try handle.seekToEnd()
        let tailLength = UInt64(512)
        let tailOffset = fileSize > tailLength ? fileSize - tailLength : 0
        try handle.seek(toOffset: tailOffset)
        let tail = try handle.read(upToCount: Int(min(tailLength, fileSize))) ?? Data()

        for format in catalog.formats {
            for signature in format.magicSignatures {
                if matches(signature, in: head, baseOffset: 0) || matches(signature, in: tail, baseOffset: Int(tailOffset)) {
                    return format.id
                }
            }
        }

        return nil
    }

    private func matches(_ signature: MagicSignature, in data: Data, baseOffset: Int) -> Bool {
        let relativeOffset = signature.offset - baseOffset
        guard relativeOffset >= 0 else { return false }
        guard data.count >= relativeOffset + signature.bytes.count else { return false }
        return Array(data[relativeOffset..<(relativeOffset + signature.bytes.count)]) == signature.bytes
    }
}
