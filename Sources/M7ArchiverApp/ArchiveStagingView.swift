import SwiftUI
import AppKit
import ArchiveCore

struct ArchiveStagingView: View {
    var stagingSources: [StagingItem]
    var onAddFiles: (() -> Void)?
    var onStageFiles: (([URL]) -> Void)?
    var onRemove: ((Set<UUID>) -> Void)?

    @State private var selection: Set<UUID> = []

    var body: some View {
        VStack(spacing: 0) {
            if stagingSources.isEmpty {
                emptyDropZone
            } else {
                stagingTable
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter { $0.isFileURL }
            if !files.isEmpty { onStageFiles?(files) }
            return true
        }
        .onDeleteCommand {
            onRemove?(selection)
            selection = []
        }
    }

    // MARK: - Empty drop zone

    private var emptyDropZone: some View {
        ContentUnavailableView {
            Label("Drag files and folders here", systemImage: "doc.zipper")
        } description: {
            Text("or select sources to create a new archive")
        } actions: {
            Button("Add Files\u{2026}") {
                onAddFiles?()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Staging Table

    private var stagingTable: some View {
        StagingTableView(sources: stagingSources, selection: $selection, onRemove: onRemove)
    }
}
