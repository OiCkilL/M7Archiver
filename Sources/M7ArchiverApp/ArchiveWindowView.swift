import SwiftUI
import AppKit
import ArchiveCore
import ArchivePresentation

struct ArchiveWindowView: View {
    @Bindable var session: ArchiveSession
    @Bindable var settings: ArchiveSettings
    var savedPasswords: SavedPasswordsStore? = nil
    var mode: WindowMode = .default_
    var stagingItems: [StagingItem] = []
    var isCompressing: Bool = false
    var onUnlockSuccess: @MainActor () async -> Void = {}
    var onOpenFile: ((URL) -> Void)? = nil
    var onOpenNestedArchive: ((ArchiveRow) -> Void)? = nil
    var onNewArchive: (() -> Void)? = nil
    var onOpenArchive: (() -> Void)? = nil
    var onAddFiles: (() -> Void)? = nil
    var onStageFiles: (([URL]) -> Void)? = nil
    var onRemoveFromStaging: ((Set<UUID>) -> Void)? = nil
    var onClearStaging: (() -> Void)? = nil
    var onCompressStaging: (() -> Void)? = nil

    @State private var sortOrder: [KeyPathComparator<ArchiveRow>] = [
        KeyPathComparator(\ArchiveRow.name)
    ]
    
    @State private var isSearchExpanded = false

    var body: some View {
        NavigationStack {
            contentCore
        }
        .toolbar { toolbarContent }
        .navigationTitle(mode == .viewing ? session.displayName : mode == .staging ? "New Archive" : "M7Archiver")
        .modifier(DocumentProxyModifier(url: session.hasArchive ? session.archiveURL : nil))
        .inspector(isPresented: $session.inspectorVisible) {
            ArchiveInspectorView(session: session, settings: settings)
                .inspectorColumnWidth(min: 240, ideal: 300, max: 500)
        }
    }

    @ViewBuilder
    private var contentCore: some View {
        VStack(spacing: 0) {
            mainArea
                .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)

            M7StatusBar(
                mode: mode,
                session: session,
                stagingItems: stagingItems,
                isCompressing: isCompressing
            )
        }
        .dropDestination(for: URL.self) { urls, _ in
            let fileURLs = urls.filter { $0.isFileURL }
            guard !fileURLs.isEmpty else { return false }
            switch mode {
            case .staging:
                onStageFiles?(fileURLs)
            case .default_:
                let detector = ArchiveTypeDetector()
                let archives = fileURLs.filter { (try? detector.detect(fileURL: $0)) != nil }
                let regularFiles = fileURLs.filter { (try? detector.detect(fileURL: $0)) == nil }
                if regularFiles.isEmpty {
                    for url in archives { onOpenFile?(url) }
                } else {
                    onStageFiles?(fileURLs)
                }
            case .viewing:
                let droppedArchives = fileURLs.filter {
                    (try? ArchiveTypeDetector().detect(fileURL: $0)) != nil
                }
                guard droppedArchives.count == fileURLs.count else { return false }
                for url in droppedArchives { onOpenFile?(url) }
                return !droppedArchives.isEmpty
            }
            return true
        }
    }

    @ViewBuilder
    private var mainArea: some View {
        switch mode {
        case .default_:
            ContentUnavailableView {
                Label("No Archive Open", systemImage: "doc.zipper")
            } description: {
                Text("Open an archive, create a new one, or drag files here to begin.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .staging:
            ArchiveStagingView(
                stagingSources: stagingItems,
                onAddFiles: { onAddFiles?() },
                onStageFiles: { onStageFiles?($0) },
                onRemove: onRemoveFromStaging
            )
        case .viewing:
            switch session.lockState {
            case .empty:
                ContentUnavailableView {
                    Label("No Archive Open", systemImage: "doc.zipper")
                } description: {
                    Text("Open an archive, create a new one, or drag files here to begin.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .unlocking:
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Opening archive…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .locked:
                ArchiveLockView(
                    session: session,
                    savedPasswords: savedPasswords,
                    onUnlockSuccess: onUnlockSuccess
                )
            case .unlocked:
                ArchiveListView(session: session, settings: settings, sortOrder: $sortOrder, onOpenNestedArchive: onOpenNestedArchive)
            case .failed(message: let message, details: let details):
                VStack(spacing: 20) {
                    ContentUnavailableView {
                        Label("Cannot Read Archive", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(message)
                    } actions: {
                        HStack(spacing: 16) {
                            if let details = details {
                                ErrorDetailsButton(details: details)
                            }
                            
                            Button("Close") {
                                session.clear()
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Subcomponents
    
    private struct ErrorDetailsButton: View {
        let details: String
        @State private var isPresented = false
        
        var body: some View {
            Button("Technical Details\u{2026}") {
                isPresented = true
            }
            .buttonStyle(.bordered)
            .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Technical Details")
                        .font(.headline)
                    
                    ScrollView {
                        Text(details)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(Color.primary.opacity(0.05))
                            .cornerRadius(4)
                    }
                    .frame(maxHeight: 300)
                    
                    HStack {
                        Spacer()
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(details, forType: .string)
                        }
                        Button("Dismiss") {
                            isPresented = false
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding()
                .frame(width: 400)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button {
                onNewArchive?()
            } label: {
                Label("New Archive", systemImage: "plus")
            }
            .help("Create a new archive")

            Button {
                onOpenArchive?()
            } label: {
                Label("Open", systemImage: "folder")
            }
            .help("Open an archive")
        }

        ToolbarItemGroup(placement: .principal) {
            switch mode {
            case .staging:
                Button {
                    onAddFiles?()
                } label: {
                    Label("Add Files", systemImage: "document.badge.plus")
                }
                .help("Add files to the new archive")

                Button {
                    onClearStaging?()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .disabled(stagingItems.isEmpty)

            case .viewing:
                let isBusy = session.progress != nil || session.lockState != .unlocked
                ControlGroup {
                    Button {
                        extractSelected()
                    } label: {
                        Label("Extract", systemImage: "doc.badge.arrow.up")
                    }
                    .disabled(session.selection.isEmpty || isBusy)

                    Button {
                        guard let archiveURL = session.archiveURL else { return }
                        Task {
                            await AutoExtract.run(
                                session: session,
                                settings: settings,
                                archiveURL: archiveURL
                            )
                        }
                    } label: {
                        Label("Extract All", systemImage: "shippingbox.fill")
                    }
                    .disabled(isBusy)
                }

                Button {
                    Task {
                        _ = await session.verifyCurrentArchive()
                    }
                } label: {
                    Label("Verify", systemImage: "shield.checkered")
                }
                .help("Verify archive integrity")
                .disabled(isBusy)

            case .default_:
                EmptyView()
            }
        }

        if mode == .staging {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    onCompressStaging?()
                } label: {
                    if isCompressing {
                        ProgressView()
                            .scaleEffect(0.6)
                            .frame(width: 16, height: 16)
                    } else {
                        Label("Compress", systemImage: "square.and.arrow.down")
                    }
                }
                .help("Create the archive")
                .disabled(stagingItems.isEmpty || isCompressing)
                .buttonStyle(.borderedProminent)
            }
        }

        if mode != .staging {
            ToolbarItem {
                Button {
                    session.inspectorVisible.toggle()
                } label: {
                    Label("Inspector", systemImage: "sidebar.right")
                }
                .help("Toggle Inspector")
            }

            ToolbarItem {
                if isSearchExpanded {
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)

                        TextField("Search archive", text: $session.searchQuery)
                            .textFieldStyle(.roundedBorder)
                            .frame(minWidth: 120, idealWidth: 180, maxWidth: 250)

                        Button("Clear search", systemImage: "xmark.circle.fill") {
                            withAnimation {
                                isSearchExpanded = false
                                session.searchQuery = ""
                            }
                        }
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.secondary)
                        .buttonStyle(.plain)
                    }
                } else {
                    Button {
                        withAnimation {
                            isSearchExpanded = true
                        }
                    } label: {
                        Label("Search", systemImage: "magnifyingglass")
                    }
                    .help("Search")
                }
            }
        }
    }

    private func extractSelected() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Extract"

        guard panel.runModal() == .OK, let destination = panel.url else { return }

        Task {
            let outcome = await session.extractSelected(to: destination)
            if case .completed(let folder, _) = outcome {
                if settings.revealInFinderAfterExtract {
                    NSWorkspace.shared.activateFileViewerSelecting([folder])
                }
            }
        }
    }
}

struct DocumentProxyModifier: ViewModifier {
    let url: URL?

    func body(content: Content) -> some View {
        if let targetURL = url {
            content.navigationDocument(targetURL)
        } else {
            content
        }
    }
}
