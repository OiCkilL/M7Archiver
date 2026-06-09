import Foundation

/// Action codes carried by `m7archiver://` URLs from the Finder Sync extension.
public enum AppUrlAction: String, CaseIterable, Sendable {
    case open
    case extractFiles
    case extractHere
    case extractToFolder
    case addToArchive
    case addTo7z
    case addToZip
    case testArchive
}

/// Parsed `m7archiver://` payload.
public struct AppUrl: Equatable, Sendable {
    public var action: AppUrlAction
    public var files: [URL]
    public var target: URL?

    public init(action: AppUrlAction, files: [URL], target: URL? = nil) {
        self.action = action
        self.files = files
        self.target = target
    }
}

/// Pure parser for `m7archiver://` URLs. No filesystem or app side effects.
///
/// Only supports the "repeated" query format where each file path is its own
/// `files=` parameter.  Legacy comma-separated single-parameter encoding was
/// removed — all callers use the repeated format today.
public enum AppUrlParser {
    public static let scheme = "m7archiver"

    public static func parse(_ url: URL) -> AppUrl? {
        guard url.scheme == scheme else { return nil }
        guard let host = url.host(percentEncoded: false),
              let action = AppUrlAction(rawValue: host) else { return nil }

        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems else { return nil }

        let filePaths = queryItems
            .filter { $0.name == "files" }
            .compactMap { $0.value }
            .filter { !$0.isEmpty }
            .map { URL(fileURLWithPath: $0) }

        guard !filePaths.isEmpty else { return nil }

        let target: URL? = queryItems
            .first { $0.name == "target" }
            .flatMap { $0.value }
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }

        return AppUrl(action: action, files: filePaths, target: target)
    }

    /// Returns the same `AppUrl` but with non-existent or suspicious file
    /// paths filtered out, and `nil` if no valid files remain.
    /// - Rejects paths with `..` traversal components.
    /// - Rejects paths outside common user-writable locations (home,
    ///   /Volumes, /tmp).  Sandbox provides a second layer of defense,
    ///   but this catches obviously malicious URLs early.
    /// - Resolves symlinks to prevent path-ambiguity attacks.
    /// Call this before routing an `m7archiver://` URL from an external source.
    public static func validated(_ parsed: AppUrl) -> AppUrl? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path
        let valid = parsed.files.filter { url in
            let resolved = url.resolvingSymlinksInPath()
            guard fm.fileExists(atPath: resolved.path) else { return false }
            // Block path traversal attempts (belt-and-suspenders — resolvingSymlinksInPath already removes ..)
            guard !resolved.path.contains("/../") else { return false }
            guard isAllowedPath(resolved.path, home: home) else { return false }
            return true
        }
        guard !valid.isEmpty else { return nil }
        if let target = parsed.target {
            let targetResolved = target.resolvingSymlinksInPath()
            if !fm.fileExists(atPath: targetResolved.path)
                || targetResolved.path.contains("/../")
                || !isAllowedPath(targetResolved.path, home: home) {
                return AppUrl(action: parsed.action, files: valid, target: nil)
            }
        }
        return AppUrl(action: parsed.action, files: valid, target: parsed.target)
    }

    /// Check whether a standardized path is within a reasonable scope.
    private static func isAllowedPath(_ path: String, home: String) -> Bool {
        // Always allow home directory, /tmp, /private/tmp, and /Volumes
        let allowedPrefixes = [home, "/tmp/", "/private/tmp/", "/Volumes/"]
        for prefix in allowedPrefixes {
            let trimmed = prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if path == trimmed || path == prefix || path.hasPrefix(prefix + "/") {
                return true
            }
        }
        return false
    }

    public static func makeURL(action: AppUrlAction, files: [URL], target: URL? = nil) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = action.rawValue

        var query = files.map { URLQueryItem(name: "files", value: $0.path) }
        query.append(URLQueryItem(name: "format", value: "repeated"))
        if let target {
            query.append(URLQueryItem(name: "target", value: target.path))
        }
        components.queryItems = query
        return components.url
    }
}
