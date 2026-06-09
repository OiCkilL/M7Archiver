import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ArchiveCore
import ArchivePresentation

struct ArchiveListView: View {
    @Bindable var session: ArchiveSession
    @Bindable var settings: ArchiveSettings
    @Binding var sortOrder: [KeyPathComparator<ArchiveRow>]
    var onOpenNestedArchive: ((ArchiveRow) -> Void)?

    private let search = ArchiveSearch()
    private let nestedArchiveExtensions: Set<String> = {
        var exts = Set(ArchiveFormatCatalog.shared.formats.flatMap(\.extensions))
        exts.insert("tgz"); exts.insert("tbz"); exts.insert("tbz2")
        exts.insert("txz"); exts.insert("tlz")
        return exts
    }()

    /// Tracks temp directories that hold files opened with external apps.
    /// Stored as a reference type so mutations persist across view re-renders.
    private final class TempDirTracker {
        var dirs: [URL] = []
    }

    @State private var tempTracker = TempDirTracker()
    @State private var openingFiles: Set<ArchiveRow.ID> = []

    var body: some View {
        Group {
            if isSearching {
                searchTable
            } else {
                browseTable
            }
        }
        .onDisappear {
            // Clean up temp directories when view disappears
            for dir in tempTracker.dirs {
                try? FileManager.default.removeItem(at: dir)
            }
            tempTracker.dirs.removeAll()
        }
    }

    // MARK: - Tables

    private var browseTable: some View {
        Table(visibleRows, selection: $session.selection, sortOrder: $sortOrder) {
            nameColumn
            typeColumn
            sizeColumn
            modifiedColumn
        }
        .contextMenu(forSelectionType: ArchiveRow.ID.self) { ids in
            Button("Open") { open(ids) }
        } primaryAction: { ids in
            open(ids)
        }
        .onChange(of: session.currentPath) { _, _ in
            session.selection.removeAll()
        }
    }

    private var searchTable: some View {
        Table(visibleRows, selection: $session.selection, sortOrder: $sortOrder) {
            nameColumn
            typeColumn
            sizeColumn
            modifiedColumn
            TableColumn("Path") { row in
                Text(row.path)
                    .lineLimit(1)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .width(min: 100, ideal: 200)
        }
        .contextMenu(forSelectionType: ArchiveRow.ID.self) { ids in
            Button("Open") { open(ids) }
        } primaryAction: { ids in
            open(ids)
        }
    }

    // MARK: - Columns

    private var nameColumn: TableColumn<ArchiveRow, KeyPathComparator<ArchiveRow>, some View, Text> {
        TableColumn("Name", value: \ArchiveRow.name) { row in
            Label {
                Text(row.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } icon: {
                Image(nsImage: icon(for: row))
                    .resizable()
                    .frame(width: 18, height: 18)
            }
        }
        .width(min: 160, ideal: 300)
    }

    private var typeColumn: TableColumn<ArchiveRow, KeyPathComparator<ArchiveRow>, some View, Text> {
        TableColumn("Type", value: \ArchiveRow.fileType) { row in
            Text(row.fileType)
                .lineLimit(1)
                .foregroundStyle(.secondary)
        }
        .width(min: 50)
    }

    private var sizeColumn: TableColumn<ArchiveRow, KeyPathComparator<ArchiveRow>, some View, Text> {
        TableColumn("Size", value: \ArchiveRow.sizeOrZero) { row in
            Text(ArchiveByteFormatter.string(row.size, isDirectory: row.isDirectory))
                .foregroundStyle(.secondary)
        }
        .width(min: 60)
    }

    private var modifiedColumn: TableColumn<ArchiveRow, KeyPathComparator<ArchiveRow>, some View, Text> {
        TableColumn("Modified", value: \ArchiveRow.modifiedAtSortKey) { row in
            Text(ArchiveDateFormatter.string(row.modifiedAt))
                .foregroundStyle(.secondary)
        }
        .width(min: 100)
    }

    // MARK: - Derived state

    private var visibleRows: [ArchiveRow] {
        let rows: [ArchiveRow]
        if isSearching {
            rows = search.search(session.entries, query: session.searchQuery)
        } else {
            rows = search.rows(at: session.currentPath, in: session.entries)
        }
        let filtered = rows.filter(includeHiddenRows)
        let parents = filtered.filter { $0.id == ArchiveRow.parentDirectoryID }
        let rest = filtered.filter { $0.id != ArchiveRow.parentDirectoryID }
        let directories = rest.filter { $0.isDirectory }
        let files = rest.filter { !$0.isDirectory }
        return parents + directories.sorted(using: sortOrder) + files.sorted(using: sortOrder)
    }

    private var isSearching: Bool {
        !session.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func includeHiddenRows(_ row: ArchiveRow) -> Bool {
        ArchiveRowVisibility.includes(row, showHiddenFiles: settings.showHiddenFiles)
    }

    // MARK: - Actions

    private func open(_ ids: Set<ArchiveRow.ID>) {
        guard let id = ids.first,
              let row = visibleRows.first(where: { $0.id == id }) else { return }
        if row.id == ArchiveRow.parentDirectoryID {
            session.goUp()
        } else if row.isDirectory {
            if isSearching {
                let segments = row.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
                session.searchQuery = ""
                session.navigate(to: segments)
            } else {
                session.descend(into: row.name)
            }
        } else if isArchiveCandidate(row) {
            onOpenNestedArchive?(row)
        } else {
            // Regular file: extract to temp and open with default app (with debounce)
            guard !openingFiles.contains(row.id) else { return }
            openingFiles.insert(row.id)
            Task {
                await openFileWithDefaultApp(row)
                openingFiles.remove(row.id)
            }
        }
    }

    @MainActor
    private func openFileWithDefaultApp(_ row: ArchiveRow) async {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("M7Archiver")
            .appendingPathComponent(UUID().uuidString)

        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            tempTracker.dirs.append(tempDir)

            let result = await session.materializePreviewEntry(path: row.path, to: tempDir)

            if case .completed(let destination, _) = result {
                let extractedURL = destination.appendingPathComponent(row.path)
                if FileManager.default.fileExists(atPath: extractedURL.path) {
                    NSWorkspace.shared.open(extractedURL)

                    // Cleanup after 5 minutes
                    Task {
                        try? await Task.sleep(for: .seconds(300))
                        cleanupTempDir(tempDir)
                    }
                } else {
                    session.operationError = "Extracted file not found: \(row.name)"
                    cleanupTempDir(tempDir)
                }
            } else {
                session.operationError = "Failed to extract: \(row.name)"
                cleanupTempDir(tempDir)
            }
        } catch {
            session.operationError = "Extraction error: \(error.localizedDescription)"
            cleanupTempDir(tempDir)
        }
    }

    private func cleanupTempDir(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
        tempTracker.dirs.removeAll { $0 == dir }
    }

    private func isArchiveCandidate(_ row: ArchiveRow) -> Bool {
        guard !row.isDirectory else { return false }
        let ext = (row.name as NSString).pathExtension.lowercased()
        return nestedArchiveExtensions.contains(ext)
    }

    // MARK: - Helpers

    private func icon(for row: ArchiveRow) -> NSImage {
        if row.isDirectory {
            return NSWorkspace.shared.icon(for: .folder)
        }
        let ext = (row.name as NSString).pathExtension
        let uttype = ext.isEmpty ? nil : UTType(filenameExtension: ext)
        return NSWorkspace.shared.icon(for: uttype ?? .data)
    }
}
