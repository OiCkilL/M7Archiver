import Foundation

public struct IgnoreRuleMatcher: Sendable {
    public var rules: [IgnoreRule]

    public init(rules: [IgnoreRule] = IgnoreRule.defaultMacOSRules) {
        self.rules = rules
    }

    public func shouldIgnore(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        let path = url.path
        let isDirectory = url.hasDirectoryPath

        return rules.contains { rule in
            guard rule.isEnabled else { return false }
            guard rule.scope == .all || (rule.scope == .directories && isDirectory) || (rule.scope == .files && !isDirectory) else { return false }
            return matches(rule.pattern, name: name, path: path)
        }
    }

    private func matches(_ pattern: String, name: String, path: String) -> Bool {
        if pattern == name || path.hasSuffix("/" + pattern) { return true }
        if pattern.hasSuffix("*") {
            return name.hasPrefix(String(pattern.dropLast()))
        }
        if pattern.hasPrefix("*") {
            return name.hasSuffix(String(pattern.dropFirst()))
        }
        return false
    }
}
