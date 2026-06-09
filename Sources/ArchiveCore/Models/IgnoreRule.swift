public enum IgnoreRuleScope: String, Codable, CaseIterable, Sendable {
    case files
    case directories
    case all
}

public struct IgnoreRule: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var pattern: String
    public var isEnabled: Bool
    public var scope: IgnoreRuleScope

    public init(id: String? = nil, pattern: String, isEnabled: Bool = true, scope: IgnoreRuleScope = .all) {
        self.id = id ?? pattern
        self.pattern = pattern
        self.isEnabled = isEnabled
        self.scope = scope
    }

    public static let defaultMacOSRules: [IgnoreRule] = [
        IgnoreRule(pattern: ".DS_Store", scope: .files),
        IgnoreRule(pattern: "__MACOSX", scope: .directories),
        IgnoreRule(pattern: "._*", scope: .files)
    ]
}
