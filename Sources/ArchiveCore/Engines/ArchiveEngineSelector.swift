public enum ArchiveEngineSelectionError: Error, Equatable, Sendable {
    case unsupportedFormat(ArchiveFormat)
    case unsupportedCapabilities(Set<ArchiveCapability>, ArchiveFormat)
    case externalRarNotConfigured
}

public enum ArchiveEngineSelectionPolicy: Equatable, Sendable {
    case automatic
    case inProcessOnly
}

public struct ArchiveEngineSelector: Sendable {
    private let catalog: ArchiveFormatCatalog
    private let externalRarConfigured: Bool
    private let selectionPolicy: ArchiveEngineSelectionPolicy

    public init(
        catalog: ArchiveFormatCatalog = .shared,
        externalRarConfigured: Bool = false,
        selectionPolicy: ArchiveEngineSelectionPolicy = .automatic
    ) {
        self.catalog = catalog
        self.externalRarConfigured = externalRarConfigured
        self.selectionPolicy = selectionPolicy
    }

    public func engineType(for format: ArchiveFormat, requestedCapabilities: Set<ArchiveCapability> = []) throws -> ArchiveEngineType {
        let engines = catalog.engineDefinitions(for: format)
        guard !engines.isEmpty else {
            throw ArchiveEngineSelectionError.unsupportedFormat(format)
        }

        if selectionPolicy == .inProcessOnly {
            return try inProcessOnlyEngineType(
                for: format,
                engines: engines,
                requestedCapabilities: requestedCapabilities
            )
        }

        if format == .rar, requestedCapabilities.contains(.externalCreate), !externalRarConfigured {
            throw ArchiveEngineSelectionError.externalRarNotConfigured
        }

        if shouldUseSevenZip(requestedCapabilities) {
            if supports(.sevenZip, in: engines, requestedCapabilities: requestedCapabilities) {
                return .sevenZip
            }
            throw ArchiveEngineSelectionError.unsupportedCapabilities(requestedCapabilities, format)
        }

        if requestedCapabilities.contains(.externalCreate) {
            if externalRarConfigured, supports(.externalRar, in: engines, requestedCapabilities: requestedCapabilities) {
                return .externalRar
            }
            throw ArchiveEngineSelectionError.externalRarNotConfigured
        }

        // 7z routing: prefer SevenZipEngine for all 7z operations.
        // libarchive can handle basic 7z list/extract but not encryption,
        // and we can't distinguish encrypted from non-encrypted before opening.
        if format == .sevenZip,
           supports(.sevenZip, in: engines, requestedCapabilities: requestedCapabilities) {
            return .sevenZip
        }

        if supports(.libarchive, in: engines, requestedCapabilities: requestedCapabilities) {
            return .libarchive
        }

        if supports(.sevenZip, in: engines, requestedCapabilities: requestedCapabilities) {
            return .sevenZip
        }

        if requestedCapabilities.isEmpty,
           let defaultEngine = engines.first(where: { $0.isDefault })?.type {
            return defaultEngine
        }

        throw ArchiveEngineSelectionError.unsupportedCapabilities(requestedCapabilities, format)
    }

    public func makeEngine(for format: ArchiveFormat, requestedCapabilities: Set<ArchiveCapability> = []) throws -> any ArchiveEngine {
        switch try engineType(for: format, requestedCapabilities: requestedCapabilities) {
        case .libarchive:
            return LibArchiveEngine()
        case .sevenZip:
            return SevenZipEngine()
        case .externalRar:
            return ExternalRarEngine(isConfigured: externalRarConfigured)
        }
    }

    private func shouldUseSevenZip(_ capabilities: Set<ArchiveCapability>) -> Bool {
        !capabilities.isDisjoint(with: [.advanced7z, .readComment, .encryptFileNames, .createVolumes, .writeComment])
    }

    private func inProcessOnlyEngineType(
        for format: ArchiveFormat,
        engines: [ArchiveEngineDefinition],
        requestedCapabilities: Set<ArchiveCapability>
    ) throws -> ArchiveEngineType {
        if supports(.libarchive, in: engines, requestedCapabilities: requestedCapabilities) {
            return .libarchive
        }
        throw ArchiveEngineSelectionError.unsupportedCapabilities(requestedCapabilities, format)
    }

    private func supports(_ type: ArchiveEngineType, in engines: [ArchiveEngineDefinition], requestedCapabilities: Set<ArchiveCapability>) -> Bool {
        guard let engine = engines.first(where: { $0.type == type }) else { return false }
        return requestedCapabilities.isEmpty || engine.capabilities.isSuperset(of: requestedCapabilities)
    }
}
