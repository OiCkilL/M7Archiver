import AppKit
import FinderSync
import Foundation

/// Thin Finder Sync extension that builds `m7archiver://` URLs from the user's
/// selection and hands them off to the main M7Archiver app via NSWorkspace.
/// All real archive work happens in the main app — this extension never opens,
/// extracts, tests, or asks for passwords.
final class M7ArchiverFinderSync: FIFinderSync {
    private let archiveExtensions: Set<String> = [
        "7z", "zip", "rar", "tar", "gz", "tgz", "bz2", "tbz", "xz", "txz",
        "lzma", "zst", "cab", "iso", "jar"
    ]
    private let archiveCompoundExtensions: Set<String> = [
        "tar.gz", "tar.bz2", "tar.xz", "tar.zst", "tar.lzma"
    ]

    override init() {
        super.init()
        let home = FileManager.default.homeDirectoryForCurrentUser
        FIFinderSyncController.default().directoryURLs = Set([
            home,
            URL(fileURLWithPath: "/Users/\(ProcessInfo.processInfo.userName)")
        ])
    }

    // MARK: - Toolbar

    override var toolbarItemName: String { "M7Archiver" }
    override var toolbarItemToolTip: String { "M7Archiver actions" }

    // MARK: - Menu

    override func menu(for menuKind: FIMenuKind) -> NSMenu {
        let selected = FIFinderSyncController.default().selectedItemURLs() ?? []
        return makeMenu(for: menuKind, selected: selected)
    }

    func makeMenu(for menuKind: FIMenuKind, selected: [URL]) -> NSMenu {
        let actionsMenu = makeActionsMenu(for: selected)

        if menuKind == .toolbarItemMenu {
            return actionsMenu
        }

        let menu = NSMenu(title: "")
        let rootItem = NSMenuItem(title: "M7Archiver", action: nil, keyEquivalent: "")
        menu.setSubmenu(actionsMenu, for: rootItem)
        menu.addItem(rootItem)
        return menu
    }

    private func makeActionsMenu(for selected: [URL]) -> NSMenu {
        let menu = NSMenu(title: "M7Archiver")
        if selected.isEmpty {
            let placeholder = NSMenuItem(title: "No item selected", action: nil, keyEquivalent: "")
            placeholder.isEnabled = false
            menu.addItem(placeholder)
            return menu
        }

        if shouldShowArchiveActions(for: selected) {
            return makeArchiveActionsMenu(for: selected)
        }
        return makeCompressionActionsMenu()
    }

    private func makeArchiveActionsMenu(for selected: [URL]) -> NSMenu {
        let menu = NSMenu(title: "M7Archiver")
        let count = selected.count
        let archiveLabel = count == 1 ? "Open in M7Archiver" : "Open \(count) Archives in M7Archiver"
        menu.addItem(makeMenuItem(archiveLabel, selector: #selector(openArchive(_:)), systemImage: "folder"))
        menu.addItem(makeMenuItem("Extract Files…", selector: #selector(extractFiles(_:)), systemImage: "doc.badge.arrow.up"))
        menu.addItem(makeMenuItem("Extract Here", selector: #selector(extractHere(_:)), systemImage: "shippingbox.fill"))
        menu.addItem(makeMenuItem(extractToFolderLabel(for: selected), selector: #selector(extractToFolder(_:)), systemImage: "shippingbox.fill"))
        menu.addItem(makeMenuItem("Test Archive", selector: #selector(testArchive(_:)), systemImage: "shield.checkered"))
        return menu
    }

    private func makeCompressionActionsMenu() -> NSMenu {
        let menu = NSMenu(title: "M7Archiver")
        menu.addItem(makeMenuItem("Add to Archive…", selector: #selector(addToArchive(_:)), systemImage: "document.badge.plus"))
        menu.addItem(makeMenuItem("Compress in ZIP", selector: #selector(addToZip(_:)), systemImage: "doc.zipper"))
        menu.addItem(makeMenuItem("Compress in 7z", selector: #selector(addTo7z(_:)), systemImage: "archivebox"))
        return menu
    }

    private func makeMenuItem(_ title: String, selector: Selector, systemImage: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        item.image = menuImage(systemImage: systemImage, accessibilityDescription: title)
        item.representedObject = systemImage
        return item
    }

    private func menuImage(systemImage: String, accessibilityDescription: String) -> NSImage? {
        let image = NSImage(systemSymbolName: systemImage, accessibilityDescription: accessibilityDescription)
        image?.isTemplate = true
        return image
    }

    private func shouldShowArchiveActions(for selected: [URL]) -> Bool {
        !selected.isEmpty && selected.allSatisfy(isArchive)
    }

    private func isArchive(_ url: URL) -> Bool {
        // Filesystem-backed directory check — more reliable than hasDirectoryPath
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
            guard !isDir.boolValue else { return false }
        }

        let fileName = url.lastPathComponent.lowercased()
        if isSevenZipSplitVolume(fileName) {
            return true
        }
        if archiveCompoundExtensions.contains(where: { fileName.hasSuffix(".\($0)") }) {
            return true
        }
        return archiveExtensions.contains(url.pathExtension.lowercased())
    }

    private func isSevenZipSplitVolume(_ fileName: String) -> Bool {
        guard fileName.contains(".7z."),
              let suffix = fileName.split(separator: ".").last,
              suffix.count == 3,
              suffix.allSatisfy({ $0.isNumber }),
              let value = Int(suffix) else {
            return false
        }
        return value > 0 && fileName.hasSuffix(".7z.\(suffix)")
    }

    private func extractToFolderLabel(for items: [URL]) -> String {
        switch items.count {
        case 1:
            let folder = items[0].deletingPathExtension().deletingPathExtension().lastPathComponent
            return "Extract to \"\(folder)\""
        default:
            return "Extract to */"
        }
    }

    // MARK: - Actions

    @objc func openArchive(_ sender: Any?) { dispatch(action: .open) }
    @objc func extractFiles(_ sender: Any?) { dispatch(action: .extractFiles) }
    @objc func extractHere(_ sender: Any?) { dispatch(action: .extractHere) }
    @objc func extractToFolder(_ sender: Any?) { dispatch(action: .extractToFolder) }
    @objc func addToArchive(_ sender: Any?) { dispatch(action: .addToArchive) }
    @objc func addToZip(_ sender: Any?) { dispatch(action: .addToZip) }
    @objc func addTo7z(_ sender: Any?) { dispatch(action: .addTo7z) }
    @objc func testArchive(_ sender: Any?) { dispatch(action: .testArchive) }

    // MARK: - URL handoff

    private enum FinderAction: String {
        case open, extractFiles, extractHere, extractToFolder, addToArchive, addToZip, addTo7z, testArchive
    }

    private func dispatch(action: FinderAction) {
        let items = FIFinderSyncController.default().selectedItemURLs() ?? []
        guard !items.isEmpty else { return }
        let target = FIFinderSyncController.default().targetedURL()

        var components = URLComponents()
        components.scheme = "m7archiver"
        components.host = action.rawValue
        var queryItems = [URLQueryItem(name: "format", value: "repeated")]
        queryItems.append(contentsOf: items.map { URLQueryItem(name: "files", value: $0.path) })
        if let target {
            queryItems.append(URLQueryItem(name: "target", value: target.path))
        }
        components.queryItems = queryItems

        guard let url = components.url else { return }
        NSWorkspace.shared.open(url)
    }
}
