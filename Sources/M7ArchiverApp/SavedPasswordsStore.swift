import Foundation
import Observation

public struct SavedPasswordEntry: Equatable, Sendable, Identifiable {
    public var path: String
    public var savedAt: Date

    public init(path: String, savedAt: Date) {
        self.path = path
        self.savedAt = savedAt
    }

    public var id: String { path }
}

/// Storage backend for archive passwords. Two implementations live in the
/// app target: a `KeychainSavedPasswordsBackend` for production and an
/// `InMemorySavedPasswordsBackend` for tests/previews.
public protocol SavedPasswordsBackend: Sendable {
    func save(password: String, for path: String) throws
    func lookup(for path: String) -> String?
    func delete(for path: String) throws
    func allEntries() throws -> [SavedPasswordEntry]
    func clearAll() throws
}

public final class InMemorySavedPasswordsBackend: SavedPasswordsBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: (password: String, savedAt: Date)] = [:]

    public init() {}

    public func save(password: String, for path: String) throws {
        lock.lock(); defer { lock.unlock() }
        storage[path] = (password, Date())
    }

    public func lookup(for path: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return storage[path]?.password
    }

    public func delete(for path: String) throws {
        lock.lock(); defer { lock.unlock() }
        storage.removeValue(forKey: path)
    }

    public func allEntries() throws -> [SavedPasswordEntry] {
        lock.lock(); defer { lock.unlock() }
        return storage.map { SavedPasswordEntry(path: $0.key, savedAt: $0.value.savedAt) }
    }

    public func clearAll() throws {
        lock.lock(); defer { lock.unlock() }
        storage.removeAll()
    }
}

/// Observable wrapper that mediates access to a `SavedPasswordsBackend` and
/// exposes the current entry list to the Settings UI. Path keys are derived
/// from `archiveURL.standardizedFileURL.path`, so identical archives at
/// different locations are treated as distinct entries.
@Observable
@MainActor
public final class SavedPasswordsStore {
    private let backend: any SavedPasswordsBackend
    public private(set) var entries: [SavedPasswordEntry] = []

    public init(backend: any SavedPasswordsBackend) {
        self.backend = backend
        refresh()
    }

    public func save(password: String, for archiveURL: URL) {
        let path = SavedPasswordsStore.key(for: archiveURL)
        try? backend.save(password: password, for: path)
        refresh()
    }

    public func lookup(for archiveURL: URL) -> String? {
        let path = SavedPasswordsStore.key(for: archiveURL)
        return backend.lookup(for: path)
    }

    public func delete(_ entry: SavedPasswordEntry) {
        try? backend.delete(for: entry.path)
        refresh()
    }

    public func delete(for archiveURL: URL) {
        let path = SavedPasswordsStore.key(for: archiveURL)
        try? backend.delete(for: path)
        refresh()
    }

    public func clearAll() {
        try? backend.clearAll()
        refresh()
    }

    public func refresh() {
        let next = (try? backend.allEntries()) ?? []
        entries = next.sorted { $0.savedAt > $1.savedAt }
    }

    static func key(for archiveURL: URL) -> String {
        archiveURL.standardizedFileURL.path
    }
}
