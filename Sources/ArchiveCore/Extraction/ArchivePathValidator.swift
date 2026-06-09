import Foundation

public enum ArchivePathValidationError: Error, Equatable, Sendable {
    case emptyPath
    case absolutePath(String)
    case parentTraversal(String)
    case destinationEscape(String)
}

public struct ArchivePathValidator: Sendable {
    public init() {}

    public static func validatedOutputURL(for entryPath: String, in destination: URL) throws -> URL {
        guard !entryPath.isEmpty else { throw ArchivePathValidationError.emptyPath }
        guard !entryPath.hasPrefix("/") else { throw ArchivePathValidationError.absolutePath(entryPath) }

        let components = entryPath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.contains("..") else { throw ArchivePathValidationError.parentTraversal(entryPath) }

        let destination = destination.standardizedFileURL
        let output = destination.appendingPathComponent(entryPath).standardizedFileURL
        let destinationPath = destination.path.hasSuffix("/") ? destination.path : destination.path + "/"
        guard output.path == destination.path || output.path.hasPrefix(destinationPath) else {
            throw ArchivePathValidationError.destinationEscape(entryPath)
        }
        return output
    }
}
