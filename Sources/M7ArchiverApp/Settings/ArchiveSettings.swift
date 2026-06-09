import Foundation
import Observation
import ArchiveCore

@MainActor @Observable
final class ArchiveSettings {
    enum AutoExtractDestinationStrategy: String, Codable, CaseIterable, Identifiable, Sendable {
        case sameFolder
        case downloads
        case customBookmark

        var id: Self { self }

        var displayLabel: String {
            switch self {
            case .sameFolder: return "Same folder as archive"
            case .downloads: return "Downloads"
            case .customBookmark: return "Custom folder"
            }
        }
    }

    struct AutoExtractDestination: Codable, Equatable, Sendable {
        var strategy: AutoExtractDestinationStrategy
        var customFolderBookmark: Data?

        init(
            strategy: AutoExtractDestinationStrategy = .sameFolder,
            customFolderBookmark: Data? = nil
        ) {
            self.strategy = strategy
            self.customFolderBookmark = customFolderBookmark
        }
    }

    static let defaultEncodingPriorityOrder = ArchiveEncoding.defaultAutomaticDetectionPriority

    @ObservationIgnored private let defaults: UserDefaults

    var defaultEncoding: ArchiveEncoding {
        didSet { defaults.set(defaultEncoding.rawValue, forKey: Keys.defaultEncoding) }
    }

    var encodingPriorityOrder: [ArchiveEncoding] {
        didSet { persistCodable(encodingPriorityOrder, forKey: Keys.encodingPriorityOrder) }
    }

    var disabledAutomaticEncodings: Set<ArchiveEncoding> {
        didSet {
            let values = Self.defaultEncodingPriorityOrder.filter { disabledAutomaticEncodings.contains($0) }
            persistCodable(values, forKey: Keys.disabledAutomaticEncodings)
        }
    }

    var automaticEncodingPriority: [ArchiveEncoding] {
        encodingPriorityOrder.filter { !disabledAutomaticEncodings.contains($0) }
    }

    var showHiddenFiles: Bool {
        didSet { defaults.set(showHiddenFiles, forKey: Keys.showHiddenFiles) }
    }

    var autoExtract: Bool {
        didSet { defaults.set(autoExtract, forKey: Keys.autoExtract) }
    }

    var autoExtractDestination: AutoExtractDestination {
        didSet { persistCodable(autoExtractDestination, forKey: Keys.autoExtractDestination) }
    }

    var revealInFinderAfterExtract: Bool {
        didSet { defaults.set(revealInFinderAfterExtract, forKey: Keys.revealInFinderAfterExtract) }
    }

    var revealInFinderAfterCreate: Bool {
        didSet { defaults.set(revealInFinderAfterCreate, forKey: Keys.revealInFinderAfterCreate) }
    }

    var defaultProfileID: String {
        didSet { defaults.set(defaultProfileID, forKey: Keys.defaultProfileID) }
    }

    var ignoreRules: [IgnoreRule] {
        didSet { persistCodable(ignoreRules, forKey: Keys.ignoreRules) }
    }

    var associatedFormats: Set<ArchiveFormat> {
        didSet {
            let rawValues = associatedFormats.map(\.rawValue).sorted()
            defaults.set(rawValues, forKey: Keys.associatedFormats)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let defaultProfileID = defaults.string(forKey: Keys.defaultProfileID) ?? BuiltInCompressionProfiles.fastZIP.id
        self.defaultEncoding = Self.loadRawRepresentable(ArchiveEncoding.self, from: defaults, key: Keys.defaultEncoding) ?? .automatic
        self.encodingPriorityOrder = Self.normalizedEncodingPriorityOrder(
            Self.loadCodable([ArchiveEncoding].self, from: defaults, key: Keys.encodingPriorityOrder)
                ?? Self.defaultEncodingPriorityOrder
        )
        let disabledAutomaticEncodings = Self.loadCodable([ArchiveEncoding].self, from: defaults, key: Keys.disabledAutomaticEncodings) ?? []
        self.disabledAutomaticEncodings = Self.normalizedDisabledAutomaticEncodings(Set(disabledAutomaticEncodings))
        self.showHiddenFiles = defaults.object(forKey: Keys.showHiddenFiles) as? Bool ?? false
        self.autoExtract = defaults.object(forKey: Keys.autoExtract) as? Bool ?? false
        self.autoExtractDestination = Self.loadCodable(AutoExtractDestination.self, from: defaults, key: Keys.autoExtractDestination)
            ?? AutoExtractDestination()
        self.revealInFinderAfterExtract = defaults.object(forKey: Keys.revealInFinderAfterExtract) as? Bool ?? true
        self.revealInFinderAfterCreate = defaults.object(forKey: Keys.revealInFinderAfterCreate) as? Bool ?? true
        self.defaultProfileID = BuiltInCompressionProfiles.all.contains(where: { $0.id == defaultProfileID })
            ? defaultProfileID
            : BuiltInCompressionProfiles.fastZIP.id
        self.ignoreRules = Self.loadCodable([IgnoreRule].self, from: defaults, key: Keys.ignoreRules) ?? IgnoreRule.defaultMacOSRules
        if let rawValues = defaults.stringArray(forKey: Keys.associatedFormats) {
            self.associatedFormats = Set(rawValues.compactMap(ArchiveFormat.init(rawValue:)))
        } else {
            self.associatedFormats = Self.loadCodable(Set<ArchiveFormat>.self, from: defaults, key: Keys.associatedFormats) ?? []
        }
    }

    var customAutoExtractFolderPath: String? {
        guard let bookmark = autoExtractDestination.customFolderBookmark else { return nil }
        var isStale = false
        let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: [.withoutUI, .withoutMounting],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        return url?.path
    }

    func moveEncodingPriorityUp(_ encoding: ArchiveEncoding) {
        guard let index = encodingPriorityOrder.firstIndex(of: encoding), index > 0 else { return }
        encodingPriorityOrder.swapAt(index, index - 1)
    }

    func moveEncodingPriorityDown(_ encoding: ArchiveEncoding) {
        guard let index = encodingPriorityOrder.firstIndex(of: encoding), index < encodingPriorityOrder.count - 1 else { return }
        encodingPriorityOrder.swapAt(index, index + 1)
    }

    func moveEncodingPriority(from source: IndexSet, to destination: Int) {
        encodingPriorityOrder.move(fromOffsets: source, toOffset: destination)
        encodingPriorityOrder = Self.normalizedEncodingPriorityOrder(encodingPriorityOrder)
    }

    func resetEncodingPriorityOrder() {
        encodingPriorityOrder = Self.defaultEncodingPriorityOrder
    }

    func resetAutomaticDetectionSettings() {
        encodingPriorityOrder = Self.defaultEncodingPriorityOrder
        disabledAutomaticEncodings = []
    }

    func isAutomaticEncodingEnabled(_ encoding: ArchiveEncoding) -> Bool {
        !disabledAutomaticEncodings.contains(encoding)
    }

    func setAutomaticEncoding(_ encoding: ArchiveEncoding, isEnabled: Bool) {
        guard encoding.isAutomaticDetectionCandidate else { return }
        if isEnabled {
            disabledAutomaticEncodings.remove(encoding)
        } else {
            disabledAutomaticEncodings.insert(encoding)
        }
    }

    func updateAutoExtractStrategy(_ strategy: AutoExtractDestinationStrategy) {
        autoExtractDestination = AutoExtractDestination(
            strategy: strategy,
            customFolderBookmark: autoExtractDestination.customFolderBookmark
        )
    }

    func setCustomAutoExtractBookmark(_ bookmark: Data?) {
        autoExtractDestination = AutoExtractDestination(
            strategy: .customBookmark,
            customFolderBookmark: bookmark
        )
    }

    func addIgnoreRule() {
        ignoreRules.append(IgnoreRule(id: UUID().uuidString, pattern: "", isEnabled: true, scope: .all))
    }

    func removeIgnoreRule(id: String) {
        ignoreRules.removeAll { $0.id == id }
    }

    func restoreDefaultIgnoreRules() {
        ignoreRules = IgnoreRule.defaultMacOSRules
    }

    private func persistCodable<T: Codable>(_ value: T, forKey key: String) {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    private static func loadCodable<T: Codable>(_ type: T.Type, from defaults: UserDefaults, key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func loadRawRepresentable<T: RawRepresentable>(_ type: T.Type, from defaults: UserDefaults, key: String) -> T?
    where T.RawValue == String {
        guard let rawValue = defaults.string(forKey: key) else { return nil }
        return T(rawValue: rawValue)
    }

    private static func normalizedEncodingPriorityOrder(_ values: [ArchiveEncoding]) -> [ArchiveEncoding] {
        ArchiveEncoding.normalizedAutomaticDetectionOrder(values)
    }

    private static func normalizedDisabledAutomaticEncodings(_ values: Set<ArchiveEncoding>) -> Set<ArchiveEncoding> {
        Set(values.filter(\.isAutomaticDetectionCandidate))
    }

    private enum Keys {
        static let defaultEncoding = "settings.defaultEncoding"
        static let encodingPriorityOrder = "settings.encodingPriorityOrder"
        static let disabledAutomaticEncodings = "settings.disabledAutomaticEncodings"
        static let showHiddenFiles = "settings.showHiddenFiles"
        static let autoExtract = "settings.autoExtract"
        static let autoExtractDestination = "settings.autoExtractDestination"
        static let revealInFinderAfterExtract = "settings.revealInFinderAfterExtract"
        static let revealInFinderAfterCreate = "settings.revealInFinderAfterCreate"
        static let defaultCompressionLevel = "settings.defaultCompressionLevel"
        static let defaultProfileID = "settings.defaultProfileID"
        static let ignoreRules = "settings.ignoreRules"
        static let associatedFormats = "settings.associatedFormats"
    }
}
