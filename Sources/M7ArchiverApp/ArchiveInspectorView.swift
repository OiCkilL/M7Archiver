import SwiftUI
import AppKit
import ArchiveCore
import ArchivePresentation

struct ArchiveInspectorView: View {
    @Bindable var session: ArchiveSession
    @Bindable var settings: ArchiveSettings
    @State private var selectedTab: InspectorTab = .info
    @State private var previewState: PreviewState = .idle
    @State private var previewGeneration = 0

    private enum PreviewState: Equatable {
        case idle
        case loading
        case text(String)
        case image(NSImage)
        case unavailable(String)
        case locked
        case failed(String)
    }

    private let search = ArchiveSearch()

    var body: some View {
        VStack(spacing: 0) {
            InspectorTabControl(selection: $selectedTab)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 8)

            ScrollView {
                switch selectedTab {
                case .info:
                    infoContent
                case .comment:
                    commentContent
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .task(id: previewIdentity) {
            await refreshPreview()
        }
        .onDisappear {
            previewGeneration += 1
            previewState = .idle
        }
    }

    private var previewIdentity: String {
        ArchiveInspectorPreviewSupport.previewIdentity(
            archivePath: session.archiveURL?.path ?? "",
            previewPath: singleSelectedRow?.path,
            selectedTab: selectedTab,
            isUnlocked: session.lockState == .unlocked,
            isBusy: session.progress != nil
        )
    }

    // MARK: - Info tab

    @ViewBuilder
    private var infoContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let row = singleSelectedRow {
                fileHeader(row)
                previewBlock(row)
                Divider()
                fileInformation(row)
            } else if session.currentPath.isEmpty {
                archiveOverview
            } else {
                directoryOverview
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .padding(16)
    }

    // MARK: - File preview

    @ViewBuilder
    private func fileHeader(_ row: ArchiveRow) -> some View {
        Label {
            Text(row.name)
                .font(.headline)
                .lineLimit(2)
        } icon: {
            Image(systemName: row.isDirectory ? "folder.fill" : "doc")
                .foregroundStyle(row.isDirectory ? Color.accentColor : Color.secondary)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func previewBlock(_ row: ArchiveRow) -> some View {
        Group {
            switch previewState {
            case .idle:
                previewPlaceholder(systemImage: row.isDirectory ? "folder" : "doc", text: row.isDirectory ? "Folder" : "Select a file to preview")
            case .loading:
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Loading preview…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            case .text(let excerpt):
                Text(excerpt)
                    .font(.system(.callout, design: .monospaced))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .multilineTextAlignment(.leading)
                    .lineLimit(nil)
                    .padding(14)
            case .image(let image):
                GeometryReader { proxy in
                    let mode = ArchiveInspectorPreviewSupport.imagePreviewMode(for: image.size)
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: mode == .fill ? .fill : .fit)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                }
            case .unavailable(let message):
                previewPlaceholder(systemImage: "doc.text.magnifyingglass", text: message)
            case .locked:
                previewPlaceholder(systemImage: "lock.fill", text: "Unlock the archive to preview this file")
            case .failed(let message):
                previewPlaceholder(systemImage: "exclamationmark.triangle", text: message)
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(ArchiveInspectorPreviewSupport.previewAspectRatio, contentMode: .fit)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func fileInformation(_ row: ArchiveRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("File Information")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            infoRow("Name", row.name)
            infoRow("Type", row.fileType)
            infoRow("Size", ArchiveByteFormatter.string(row.size, isDirectory: row.isDirectory))
            infoRow("Compressed", ArchiveByteFormatter.string(row.packedSize, isDirectory: row.isDirectory))
            infoRow("Modified", ArchiveDateFormatter.string(row.modifiedAt))
            infoRow("Path", row.path)
            if row.isEncrypted {
                Label("Encrypted", systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Archive overview (root, no selection)

    @ViewBuilder
    private var archiveOverview: some View {
        if let metadata = session.metadata, let url = session.archiveURL {
            VStack(alignment: .leading, spacing: 16) {
                Label {
                    Text(url.lastPathComponent).font(.headline)
                } icon: {
                    Image(systemName: "doc.zipper").foregroundStyle(.tint)
                        .accessibilityHidden(true)
                }

                infoBlock {
                    Image(systemName: "doc.zipper")
                        .font(.system(size: 36))
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    Text("\(metadata.format.displayLabel) Archive")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Archive Information")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    infoRow("Name", url.lastPathComponent)
                    infoRow("Format", metadata.format.displayLabel)
                    infoRow("Total Size", ArchiveByteFormatter.string(metadata.uncompressedSize))
                    infoRow("Compressed", ArchiveByteFormatter.string(metadata.compressedSize))
                    infoRow("Compression", compressionRatioLabel(metadata))
                    infoRow("Entries", metadata.entriesCount.map(String.init) ?? "—")
                    if metadata.isEncrypted {
                        infoRow("Encrypted", "Yes")
                    }
                    if metadata.isMultiVolume {
                        infoRow("Multi-volume", "Yes")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .top)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "info.circle")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("No archive overview yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 32)
        }
    }

    // MARK: - Directory overview (subdirectory, no selection)

    @ViewBuilder
    private var directoryOverview: some View {
        let directoryPath = session.currentPath.joined(separator: "/")
        let rows = search.rows(at: session.currentPath, in: session.entries)
        let visibleSize = rows
            .filter { !$0.isDirectory }
            .compactMap(\.size)
            .reduce(0, +)
        let lastModified = rows.compactMap(\.modifiedAt).max()

        VStack(alignment: .leading, spacing: 16) {
            Label {
                Text(session.currentPath.last ?? directoryPath).font(.headline)
            } icon: {
                Image(systemName: "folder.fill").foregroundStyle(.tint)
                    .accessibilityHidden(true)
            }

            infoBlock {
                Image(systemName: "folder.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text("Folder").font(.callout).foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Directory Information")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                infoRow("Path", directoryPath.isEmpty ? "/" : directoryPath)
                infoRow("Items", String(rows.count))
                infoRow("Visible Size", ArchiveByteFormatter.string(visibleSize > 0 ? visibleSize : nil))
                infoRow("Last Modified", ArchiveDateFormatter.string(lastModified))
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    // MARK: - Comment tab

    @ViewBuilder
    private var commentContent: some View {
        if let metadata = session.metadata,
           let comment = metadata.comment,
           !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Archive Comment")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)

                ScrollView(.horizontal, showsIndicators: true) {
                    Text(comment)
                        .font(.system(.callout, design: .monospaced))
                        .lineLimit(nil)
                        .fixedSize(horizontal: true, vertical: false)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
            .frame(maxWidth: .infinity, alignment: .top)
            .padding(16)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "quote.bubble")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("No comment")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 48)
        }
    }

    // MARK: - Preview loading

    @MainActor
    private func refreshPreview() async {
        previewGeneration += 1
        let generation = previewGeneration
        guard !Task.isCancelled else { return }

        guard ArchiveInspectorPreviewSupport.shouldLoadPreview(selectedTab: selectedTab) else {
            previewState = .idle
            return
        }

        guard let row = singleSelectedRow else {
            previewState = .idle
            return
        }

        let decision = ArchiveInspectorPreviewPolicy.decision(
            for: row,
            metadata: session.metadata,
            lockState: session.lockState,
            isBusy: session.progress != nil
        )

        switch decision {
        case .locked:
            previewState = .locked
            return
        case .unavailable(let reason):
            previewState = .unavailable(reason)
            return
        case .load(let kind):
            previewState = .loading
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("M7Archiver-preview-\(UUID().uuidString)", isDirectory: true)
            defer {
                try? FileManager.default.removeItem(at: root)
            }
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            } catch {
                previewState = .failed("Unable to prepare preview.")
                return
            }

            let outcome = await session.materializePreviewEntry(path: row.path, to: root)
            guard !Task.isCancelled, generation == previewGeneration else { return }
            switch outcome {
            case .completed:
                let fileURL = root.appendingPathComponent(row.path)
                switch kind {
                case .text:
                    let excerpt = await Task.detached(priority: .userInitiated) {
                        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil as String? }
                        defer { try? handle.close() }
                        let sample = try? handle.read(upToCount: 32 * 1_024)
                        guard let data = sample,
                              let text = ArchiveInspectorTextPreview.decodeText(from: data) else {
                            return nil
                        }
                        return ArchiveInspectorTextPreview.excerpt(from: text)
                    }.value
                    guard !Task.isCancelled, generation == previewGeneration else { return }
                    if let excerpt {
                        previewState = .text(excerpt)
                    } else {
                        previewState = .unavailable("Text preview unavailable for this file.")
                    }
                case .image:
                    if let image = await Task.detached(priority: .userInitiated, operation: {
                        NSImage(contentsOf: fileURL)
                    }).value {
                        guard !Task.isCancelled, generation == previewGeneration else { return }
                        previewState = .image(image)
                    } else {
                        guard !Task.isCancelled, generation == previewGeneration else { return }
                        previewState = .unavailable("Image preview unavailable")
                    }
                case .pdf:
                    if let image = await Task.detached(priority: .userInitiated, operation: {
                        ArchiveInspectorPreviewSupport.renderPDFFirstPage(from: fileURL)
                    }).value {
                        guard !Task.isCancelled, generation == previewGeneration else { return }
                        previewState = .image(image)
                    } else {
                        guard !Task.isCancelled, generation == previewGeneration else { return }
                        previewState = .unavailable("PDF preview unavailable")
                    }
                }
            case .locked:
                previewState = .locked
            case .missingArchive, .missingSelection:
                previewState = .unavailable("Preview unavailable for this selection.")
            case .unsupportedBackend:
                previewState = .unavailable("Preview unavailable with the current backend.")
            case .cancelled:
                previewState = .idle
            case .failed(let message):
                previewState = .failed(message)
            }
        }
    }

    // MARK: - Helpers

    private var singleSelectedRow: ArchiveRow? {
        ArchiveInspectorSelectionResolver.singleSelectedRow(
            selection: session.selection,
            currentPath: session.currentPath,
            searchQuery: session.searchQuery,
            entries: session.entries,
            showHiddenFiles: settings.showHiddenFiles
        )
    }

    private func compressionRatioLabel(_ metadata: ArchiveMetadata) -> String {
        guard let total = metadata.uncompressedSize, total > 0,
              let compressed = metadata.compressedSize, compressed >= 0 else {
            return "—"
        }
        let ratio = Double(compressed) / Double(total) * 100.0
        return ratio.formatted(.number.precision(.fractionLength(1))) + "%"
    }

    @ViewBuilder
    private func infoBlock<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 8) { content() }
            .frame(maxWidth: .infinity)
            .padding(24)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
        .font(.callout)
    }

    @ViewBuilder
    private func previewPlaceholder(systemImage: String, text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}
