import SwiftUI
import AppKit
import ArchiveCore

struct GeneralSettingsView: View {
    @Bindable var settings: ArchiveSettings

    var body: some View {
        SettingsPane {
            SettingsGroup("Browsing") {
                Toggle("Show hidden files and folders", isOn: $settings.showHiddenFiles)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            SettingsGroup("Auto Extraction") {
                Toggle("Extract immediately after opening", isOn: $settings.autoExtract)
                    .toggleStyle(.switch)
                    .controlSize(.small)

                if settings.autoExtract {
                    Picker("Destination", selection: autoExtractStrategyBinding) {
                        ForEach(ArchiveSettings.AutoExtractDestinationStrategy.allCases) { strategy in
                            Text(strategy.displayLabel).tag(strategy)
                        }
                    }

                    if settings.autoExtractDestination.strategy == .customBookmark {
                        folderRow
                    }

                    Toggle("Reveal in Finder after extraction", isOn: $settings.revealInFinderAfterExtract)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
            }

            SettingsGroup("Text Encoding") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Default Encoding", selection: $settings.defaultEncoding) {
                        ForEach(ArchiveEncoding.allCases, id: \.self) { encoding in
                            Text(encoding.displayLabel).tag(encoding)
                        }
                    }

                    Text("Choose Auto to let M7Archiver detect legacy ZIP filename encodings in the order below. Disabled entries are skipped.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Auto-Detection Priority")
                                .font(.subheadline.weight(.medium))
                            Spacer()
                            Button("Restore Defaults") {
                                settings.resetAutomaticDetectionSettings()
                            }
                            .buttonStyle(.link)
                            .font(.caption)
                        }

                        encodingPriorityList
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var encodingPriorityList: some View {
        List {
            ForEach(settings.encodingPriorityOrder, id: \.self) { encoding in
                HStack(spacing: 10) {
                    Image(systemName: "line.3.horizontal")
                        .foregroundStyle(.tertiary)
                        .font(.caption)
                        .accessibilityHidden(true)

                    Toggle(isOn: automaticEncodingBinding(for: encoding)) {
                        Text(encoding.displayLabel)
                    }
                    .toggleStyle(.checkbox)

                    Spacer()
                }
                .padding(.vertical, 2)
                .contextMenu {
                    Button("Enable") { settings.setAutomaticEncoding(encoding, isEnabled: true) }
                        .disabled(settings.isAutomaticEncodingEnabled(encoding))
                    Button("Disable") { settings.setAutomaticEncoding(encoding, isEnabled: false) }
                        .disabled(!settings.isAutomaticEncodingEnabled(encoding))
                    Divider()
                    Button("Move Up") { settings.moveEncodingPriorityUp(encoding) }
                        .disabled(settings.encodingPriorityOrder.first == encoding)
                    Button("Move Down") { settings.moveEncodingPriorityDown(encoding) }
                        .disabled(settings.encodingPriorityOrder.last == encoding)
                }
            }
            .onMove(perform: moveEncodingPriority)
        }
        .listStyle(.plain)
        .scrollIndicators(.visible)
        .frame(height: 240)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var folderRow: some View {
        HStack(alignment: .center, spacing: 8) {
            Label("Folder", systemImage: "folder")
                .foregroundStyle(.secondary)

            Spacer()

            Text(settings.customAutoExtractFolderPath ?? "No folder selected")
                .lineLimit(1)
                .truncationMode(.middle)
                .font(.caption.monospaced())
                .foregroundStyle(settings.customAutoExtractFolderPath == nil ? .secondary : .primary)

            Button("Choose…") {
                chooseCustomFolder()
            }
            .controlSize(.small)
        }
    }

    private func automaticEncodingBinding(for encoding: ArchiveEncoding) -> Binding<Bool> {
        Binding(
            get: { settings.isAutomaticEncodingEnabled(encoding) },
            set: { settings.setAutomaticEncoding(encoding, isEnabled: $0) }
        )
    }

    private var autoExtractStrategyBinding: Binding<ArchiveSettings.AutoExtractDestinationStrategy> {
        Binding(
            get: { settings.autoExtractDestination.strategy },
            set: { settings.updateAutoExtractStrategy($0) }
        )
    }

    private func moveEncodingPriority(from source: IndexSet, to destination: Int) {
        settings.moveEncodingPriority(from: source, to: destination)
    }

    private func chooseCustomFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) else {
            return
        }

        settings.setCustomAutoExtractBookmark(bookmark)
    }
}
