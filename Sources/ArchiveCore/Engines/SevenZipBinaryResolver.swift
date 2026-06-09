import Foundation

/// Resolves the path to the official 7-Zip CLI binary (`7zz`, with `7z`
/// fallback). M7Archiver shells out to this binary for advanced 7z features
/// (archive comments, header encryption, split volumes, custom dictionary
/// sizes, etc.) that libarchive does not expose.
///
/// Lookup priority:
///   1. `Vendor/7zip/bin/7zz` next to the running binary or repo root —
///      the project-vendored copy built from `Vendor/7zip/build-7zz.sh`.
///      This is what production app bundles will ship.
///   2. The current bundle's auxiliary executable directory (e.g.
///      `Contents/MacOS/Helpers/7zz` once the Xcode project lands).
///   3. Homebrew / system paths — opt-in dev fallback only. Production
///      resolution uses bundled locations so unvetted system binaries are
///      not executed implicitly.
public enum SevenZipBinaryResolver {
    /// Default candidates, ordered by preference.
    /// `7zz` is the official ip7z binary name; `7z` is the legacy/p7zip
    /// alias still seen on some systems and acceptable as a fallback.
    public static let defaultCandidatePaths: [String] = [
        "/opt/homebrew/bin/7zz",
        "/usr/local/bin/7zz",
        "/opt/homebrew/bin/7z",
        "/usr/local/bin/7z",
        "/usr/bin/7zz",
        "/usr/bin/7z"
    ]

    /// Project-relative locations to check before falling back to system
    /// paths. The list is consulted relative to a list of candidate
    /// "anchor" directories (CWD, repo root inferred via SPM build dir,
    /// `Bundle.main.bundleURL`).
    public static let projectRelativePaths: [String] = [
        "Vendor/7zip/bin/7zz",
        "Contents/MacOS/Helpers/7zz",
        "Contents/Resources/7zz"
    ]

    /// Return the first candidate that points at an executable file, or
    /// `nil` if no allowed 7-Zip CLI exists on disk.
    public static func resolve(
        candidates: [String] = defaultCandidatePaths,
        bundledLocations: [URL]? = nil,
        allowSystemFallback: Bool = false,
        fileManager: FileManager = .default
    ) -> URL? {
        for url in bundledLocations ?? Self.computeBundledLocations() {
            if fileManager.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        guard allowSystemFallback else { return nil }
        for path in candidates where fileManager.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    /// Best-effort default — falls back to the vendored location callers expect,
    /// not a system path that would bypass the explicit fallback opt-in.
    public static func defaultURL(
        candidates: [String] = defaultCandidatePaths,
        bundledLocations: [URL]? = nil,
        fileManager: FileManager = .default
    ) -> URL {
        if let resolved = resolve(candidates: candidates, bundledLocations: bundledLocations, fileManager: fileManager) {
            return resolved
        }
        return URL(fileURLWithPath: fileManager.currentDirectoryPath)
            .appendingPathComponent(projectRelativePaths[0])
    }

    /// Build the list of bundled-binary locations to probe. Anchored at:
    ///   - the running executable's parent directory (and ancestors),
    ///   - `Bundle.main.bundleURL` (for built `.app` bundles),
    ///   - the current working directory (handy in `swift run` / tests).
    private static func computeBundledLocations() -> [URL] {
        var anchors: [URL] = []

        // Walk a few levels up from the executable so SwiftPM's
        // `.build/.../debug/M7ArchiverApp` still finds `Vendor/7zip/bin/7zz`
        // at the repo root.
        let exec = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
        var dir = exec.deletingLastPathComponent()
        for _ in 0..<6 {
            anchors.append(dir)
            let parent = dir.deletingLastPathComponent()
            if parent == dir { break }
            dir = parent
        }

        anchors.append(Bundle.main.bundleURL)
        anchors.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath))

        var probed: [URL] = []
        var seen: Set<String> = []
        for anchor in anchors {
            for relative in projectRelativePaths {
                let url = anchor.appendingPathComponent(relative).standardizedFileURL
                if seen.insert(url.path).inserted {
                    probed.append(url)
                }
            }
        }
        return probed
    }
}
