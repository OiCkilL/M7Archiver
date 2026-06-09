import SwiftUI
import AppKit
import ArchiveCore
import ArchivePresentation

struct StagingTableView: View {
    var sources: [StagingItem]
    @Binding var selection: Set<UUID>
    var onRemove: ((Set<UUID>) -> Void)?

    var body: some View {
        Table(sources, selection: $selection) {
            TableColumn("Name") { item in
                Label {
                    Text(item.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } icon: {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                        .resizable()
                        .frame(width: 18, height: 18)
                }
            }
            .width(min: 160, ideal: 300)

            TableColumn("Type") { item in
                Text(item.isDirectory ? "Folder" : fileType(for: item.name))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 50, ideal: 80)

            TableColumn("Size") { item in
                Text(ArchiveByteFormatter.string(item.size, isDirectory: item.isDirectory))
                    .foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 80)
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            Button("Remove") { onRemove?(ids) }
            Divider()
            if ids.count == 1, let id = ids.first, let item = sources.first(where: { $0.id == id }) {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([item.url])
                }
            }
        }
    }

    private func fileType(for name: String) -> String {
        let ext = (name as NSString).pathExtension
        return ext.isEmpty ? "File" : ext.uppercased()
    }
}
