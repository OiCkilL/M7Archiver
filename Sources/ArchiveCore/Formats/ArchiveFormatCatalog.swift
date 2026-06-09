import Foundation

public final class ArchiveFormatCatalog: Sendable {
    public static let shared = ArchiveFormatCatalog()

    private let formatsById: [ArchiveFormat: ArchiveFormatDefinition]
    private let formatsByExtension: [String: ArchiveFormatDefinition]
    private let compoundFormats: [CompoundArchiveFormat]

    public init(bundle: Bundle? = nil) {
        guard let url = Self.catalogURL(bundle: bundle) else {
            self.formatsById = [:]
            self.formatsByExtension = [:]
            self.compoundFormats = []
            return
        }

        do {
            let data = try Data(contentsOf: url)
            let catalog = try JSONDecoder().decode(ArchiveFormatCatalogDTO.self, from: data)
            self.compoundFormats = catalog.compounds
            self.formatsById = Dictionary(uniqueKeysWithValues: catalog.formats.map { ($0.id, $0) })
            self.formatsByExtension = Dictionary(
                catalog.formats.flatMap { format in
                    format.extensions.map { ($0.lowercased(), format) }
                },
                uniquingKeysWith: { first, _ in first }
            )
        } catch {
            self.formatsById = [:]
            self.formatsByExtension = [:]
            self.compoundFormats = []
        }
    }

    private static func catalogURL(bundle: Bundle?) -> URL? {
        if let bundle {
            return bundle.url(forResource: "ArchiveFormatCatalog", withExtension: "json")
        }

        let mainBundle = Bundle.main
        if let url = mainBundle.url(forResource: "ArchiveFormatCatalog", withExtension: "json") {
            return url
        }

        // Look for the resource bundle inside the app/extension bundle
        let bundleName = "M7Archiver_ArchiveCore.bundle"
        let bundleRoots = [
            mainBundle.resourceURL,
            mainBundle.bundleURL.appendingPathComponent("Contents/Resources"),
            mainBundle.bundleURL,
        ].compactMap { $0 }

        for root in bundleRoots {
            let url = root
                .appendingPathComponent(bundleName, isDirectory: true)
                .appendingPathComponent("ArchiveFormatCatalog.json")
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }

        #if DEBUG
        // Development/test fallback: look next to the source file.
        // Not available in release builds — resource bundle must be properly embedded.
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("ArchiveFormatCatalog.json")
        if FileManager.default.fileExists(atPath: sourceURL.path) {
            return sourceURL
        }
        #endif

        return nil
    }

    public var formats: [ArchiveFormatDefinition] {
        Array(formatsById.values)
    }

    public var compounds: [CompoundArchiveFormat] {
        compoundFormats
    }

    public func definition(for format: ArchiveFormat) -> ArchiveFormatDefinition? {
        if let definition = formatsById[format] {
            return definition
        }

        guard let compound = compoundFormats.first(where: { $0.id == format }) else {
            return nil
        }

        return formatsById[compound.container]
    }

    public func definition(forExtension pathExtension: String) -> ArchiveFormatDefinition? {
        formatsByExtension[pathExtension.lowercased()]
    }

    public func compoundDefinition(forFileName fileName: String) -> CompoundArchiveFormat? {
        let lowercased = fileName.lowercased()
        return compoundFormats.first { compound in
            compound.extensions.contains { lowercased.hasSuffix("." + $0.lowercased()) }
        }
    }

    public func engineDefinitions(for format: ArchiveFormat) -> [ArchiveEngineDefinition] {
        definition(for: format)?.engines ?? []
    }
}
