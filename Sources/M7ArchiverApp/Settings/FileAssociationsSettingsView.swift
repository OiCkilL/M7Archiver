import SwiftUI
import ArchiveCore

struct FileAssociationsSettingsView: View {
    @Bindable var settings: ArchiveSettings

    private let formats: [(ArchiveFormatDefinition, String)] = {
        ArchiveFormatCatalog.shared.formats
            .map { ($0, $0.extensions.joined(separator: ", ")) }
            .sorted { $0.0.name.localizedStandardCompare($1.0.name) == .orderedAscending }
    }()

    var body: some View {
        SettingsPane(minWidth: 620, idealWidth: 720, maxWidth: 760) {
            SettingsGroup("Supported Formats") {
                Text("Choose which formats appear in M7Archiver’s supported-format preferences. Finder and QuickLook availability are managed separately by macOS extensions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("\(formats.filter { settings.associatedFormats.contains($0.0.id) }.count) / \(formats.count) selected")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Select All") {
                            settings.associatedFormats = Set(formats.map(\.0.id))
                        }
                        Button("Deselect All") {
                            settings.associatedFormats = []
                        }
                    }

                    if formats.isEmpty {
                        ContentUnavailableView("No formats available", systemImage: "doc.badge.gearshape")
                            .frame(maxWidth: .infinity, minHeight: 320)
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(Array(formats.enumerated()), id: \.element.0.id) { index, item in
                                    let (format, extensions) = item
                                    HStack(spacing: 12) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(format.name)
                                                .font(.body)
                                            Text(extensions)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Toggle("", isOn: associationBinding(for: format.id))
                                            .labelsHidden()
                                            .toggleStyle(.checkbox)
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(index % 2 == 1 ? Color.secondary.opacity(0.05) : Color.clear)
                                }
                            }
                        }
                        .frame(height: 340)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 1)
                        )
                    }
                }
            }
        }
    }

    private func associationBinding(for format: ArchiveFormat) -> Binding<Bool> {
        Binding(
            get: { settings.associatedFormats.contains(format) },
            set: { on in
                if on {
                    settings.associatedFormats.insert(format)
                } else {
                    settings.associatedFormats.remove(format)
                }
            }
        )
    }
}
