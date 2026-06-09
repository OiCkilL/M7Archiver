import SwiftUI
import ArchiveCore

struct M7StatusBar: View {
    let mode: WindowMode
    @Bindable var session: ArchiveSession
    var stagingItems: [StagingItem] = []
    var isCompressing: Bool = false

    @State private var showSkippedPopover = false
    @State private var showVerifyPopover = false
    @State private var showPermissionPopover = false
    @State private var showErrorPopover = false

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            
            HStack(spacing: 12) {
                // 1. 左侧区域
                Group {
                    if mode == .viewing {
                        interactiveBreadcrumbs
                    } else if mode == .staging {
                        Text("New Archive Staging")
                            .foregroundStyle(.tertiary)
                    } else {
                        Label("Ready", systemImage: "checkmark.circle")
                            .foregroundStyle(.tertiary)
                    }
                }
                .layoutPriority(1)
                
                Spacer(minLength: 16)

                // 2. 右侧动态 Slot
                dynamicRightSlot
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .frame(height: 28)
        }
    }

    @ViewBuilder
    private var dynamicRightSlot: some View {
        let isBusy = currentProgress != nil
        let isVerifying = currentProgress?.operation == .testArchive

        HStack(spacing: 8) {
            if isBusy, let progress = currentProgress {
                progressView(progress)

                Button("Cancel", systemImage: "xmark.circle.fill") {
                    session.cancelCurrentOperation()
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Cancel \(isVerifying ? "verification" : isCompressing ? "compression" : "extraction")")
            } else if let permError = session.permissionError {
                HStack(spacing: 4) {
                    Image(systemName: "lock.trianglebadge.exclamationmark.fill")
                        .foregroundStyle(.orange)
                    Text("Permission denied")
                        .foregroundStyle(.orange)
                    
                    Button {
                        showPermissionPopover = true
                    } label: {
                        Text("Fix").underline()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.orange)
                    .popover(isPresented: $showPermissionPopover, arrowEdge: .bottom) {
                        permissionGrantView(permError)
                    }

                    Button("Dismiss", systemImage: "xmark") {
                        session.dismissPermissionError()
                    }
                    .labelStyle(.iconOnly)
                    .imageScale(.small)
                    .buttonStyle(.plain)
                    .padding(.leading, 4)
                }
            } else if let result = session.lastExtractionResult, result.hasWarnings {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("\(result.skippedEntries.count) files skipped")
                        .foregroundStyle(.orange)
                    
                    Button {
                        showSkippedPopover = true
                    } label: {
                        Text("Review").underline()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.orange)
                    .popover(isPresented: $showSkippedPopover, arrowEdge: .bottom) {
                        M7DetailPopover(
                            title: "Extraction Warnings",
                            type: .warning,
                            details: result.skippedEntries.map { "\($0.path): \($0.reason)" },
                            onCopy: { copyToClipboard(result.skippedEntries.map { "\($0.path): \($0.reason)" }.joined(separator: "\n")) },
                            onDismiss: { showSkippedPopover = false }
                        )
                    }

                    Button("Clear", systemImage: "xmark") {
                        session.lastExtractionResult = nil
                    }
                    .labelStyle(.iconOnly)
                    .imageScale(.small)
                    .buttonStyle(.plain)
                    .padding(.leading, 4)
                }
            } else if let result = session.verifyResult {
                HStack(spacing: 4) {
                    Image(systemName: result.success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(result.success ? .green : .red)
                    Text(result.success ? "Verification passed" : "Verification failed")
                        .foregroundStyle(result.success ? .green : .red)
                    
                    if !result.success {
                        Button {
                            showVerifyPopover = true
                        } label: {
                            Text("Details").underline()
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.red)
                        .popover(isPresented: $showVerifyPopover, arrowEdge: .bottom) {
                            M7DetailPopover(
                                title: "Verification Failed",
                                type: .error,
                                details: result.details,
                                onCopy: { copyToClipboard(result.details.joined(separator: "\n")) },
                                onDismiss: { showVerifyPopover = false }
                            )
                        }
                    }

                    Button("Clear", systemImage: "xmark") {
                        session.verifyResult = nil
                    }
                    .labelStyle(.iconOnly)
                    .imageScale(.small)
                    .buttonStyle(.plain)
                    .padding(.leading, 4)
                }
                .onAppear {
                    if result.success {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                            if session.verifyResult == result { session.verifyResult = nil }
                        }
                    }
                }
            } else if let error = session.operationError {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.octagon.fill")
                        .foregroundStyle(.red)
                    Text(error)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                    
                    Button {
                        showErrorPopover = true
                    } label: {
                        Text("Details").underline()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                    .popover(isPresented: $showErrorPopover, arrowEdge: .bottom) {
                        M7DetailPopover(
                            title: "Operation Error",
                            type: .error,
                            details: [error],
                            onCopy: { copyToClipboard(error) },
                            onDismiss: { showErrorPopover = false }
                        )
                    }

                    Button("Clear", systemImage: "xmark") {
                        session.operationError = nil
                    }
                    .labelStyle(.iconOnly)
                    .imageScale(.small)
                    .buttonStyle(.plain)
                    .padding(.leading, 4)
                }
            } else if let lastResult = session.lastExtractionResult, !isBusy {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Extraction completed")
                        .foregroundStyle(.green)
                }
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                        if session.lastExtractionResult == lastResult { session.lastExtractionResult = nil }
                    }
                }
            } else {
                Text(statusLabel)
                    .lineLimit(1)

                if mode == .viewing && session.hasArchive {
                    encodingPicker
                }
            }
        }
    }

    // MARK: - 辅助组件

    @ViewBuilder
    private func permissionGrantView(_ error: ArchiveSession.ArchivePermissionError) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.title)
                    .foregroundStyle(.orange)
                Text("Sandbox Access Required")
                    .font(.headline)
            }
            Text("M7Archiver needs write access to this location. Choose the folder to grant access and restore owner write permission when possible.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text("Requested Path:").font(.caption).fontWeight(.bold)
                Text(error.path.path).font(.system(.caption, design: .monospaced))
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 4))
            }
            HStack {
                Spacer()
                Button("Cancel") { showPermissionPopover = false }
                Button("Grant Access & Retry\u{2026}") {
                    let panel = NSOpenPanel()
                    panel.directoryURL = error.path
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    if panel.runModal() == .OK, let selectedURL = panel.url {
                        showPermissionPopover = false
                        Task { await session.resolvePermissionError(with: selectedURL) }
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(width: 340)
    }

    private var currentProgress: ArchiveSession.Progress? {
        if mode == .viewing { return session.progress }
        else if isCompressing { return session.progress }
        return nil
    }

    @ViewBuilder
    private func progressView(_ progress: ArchiveSession.Progress) -> some View {
        HStack(spacing: 8) {
            Text(progress.message).font(.caption).lineLimit(1)
            if let fraction = progress.fraction {
                ProgressView(value: max(0, min(1, fraction)))
                    .progressViewStyle(.linear).frame(width: 150)
            } else {
                ProgressView().progressViewStyle(.linear).controlSize(.small).frame(width: 150)
            }
        }
    }

    private var statusLabel: String {
        switch mode {
        case .default_: return "No archive selected"
        case .staging:
            let total = stagingItems.count
            let bytes = stagingItems.compactMap(\.size).reduce(0, +)
            return "\(total) items · \(formattedSize(bytes))"
        case .viewing:
            switch session.lockState {
            case .unlocked: break
            case .unlocking: return "Unlocking…"
            case .locked: return "Locked"
            case .failed(message: let message, details: _): return message
            case .empty: return ""
            }
            let total = session.entries.filter { !$0.isDirectory }.count
            let bytes = session.entries.compactMap(\.size).reduce(0, +)
            var label = "\(total) items · \(formattedSize(bytes))"
            if !session.selection.isEmpty { label += "  ·  \(session.selection.count) selected" }
            return label
        }
    }

    @ViewBuilder
    private var interactiveBreadcrumbs: some View {
        HStack(spacing: 4) {
            Image(systemName: "archivebox").imageScale(.small).foregroundStyle(.tertiary)
            Button { session.navigate(to: []) } label: {
                Text(truncateFilename(session.archiveURL?.lastPathComponent ?? "Archive", isRoot: true, isCurrent: session.currentPath.isEmpty))
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .foregroundStyle(session.currentPath.isEmpty ? .primary : .secondary)
            ForEach(Array(session.currentPath.enumerated()), id: \.offset) { index, folder in
                Image(systemName: "chevron.compact.right").foregroundStyle(.tertiary)
                Button { session.navigate(to: Array(session.currentPath.prefix(index + 1))) } label: {
                    Text(truncateFilename(folder, isRoot: false, isCurrent: index == session.currentPath.count - 1))
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .foregroundStyle(index == session.currentPath.count - 1 ? .primary : .secondary)
            }
        }
    }

    /// 截断长文件名：根目录且无子级时显示较长，其他目录中间截断
    private func truncateFilename(_ name: String, isRoot: Bool, isCurrent: Bool) -> String {
        // 一级目录(没有进入任何子文件夹)时显示超长长度，进入子层级后缩短。当前层级给稍长一点的空间。
        let maxLength = (isRoot && isCurrent) ? 50 : (isCurrent ? 26 : 16)
        
        guard name.count > maxLength else { return name }

        guard let lastDot = name.lastIndex(of: ".") else {
            let half = maxLength / 2
            let head = name.prefix(half)
            let tail = name.suffix(half - 1)
            return "\(head)…\(tail)"
        }

        let base = name[..<lastDot]
        let ext = name[lastDot...]

        if base.count <= 6 { return name }

        let availableForBase = maxLength - ext.count - 1
        if availableForBase < 4 {
            return "\(base.prefix(3))…\(ext)"
        }

        let headCount = availableForBase / 2 + availableForBase % 2
        let tailCount = availableForBase / 2

        let head = base.prefix(headCount)
        let tail = base.suffix(tailCount)

        return "\(head)…\(tail)\(ext)"
    }

    @ViewBuilder
    private var encodingPicker: some View {
        Divider().frame(height: 12)
        Menu {
            Picker(selection: Binding(get: { session.encoding }, set: { session.setEncoding($0) }), label: EmptyView()) {
                ForEach(ArchiveEncoding.allCases, id: \.self) { Text($0.displayLabel).tag($0) }
            }
            .pickerStyle(.inline).labelsHidden()
        } label: { Text(session.encoding.displayLabel) }
        .menuStyle(.borderlessButton).fixedSize()
    }

    private func formattedSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
