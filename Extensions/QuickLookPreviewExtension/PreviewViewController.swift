import AppKit
import Quartz
import UniformTypeIdentifiers
import ArchiveCore
import ArchivePresentation

final class ArchiveTreeNode: NSObject, @unchecked Sendable {
    var row: ArchiveRow
    var children: [ArchiveTreeNode] = []
    
    init(row: ArchiveRow) {
        self.row = row
        super.init()
    }
}

final class PreviewViewController: NSViewController, QLPreviewingController {

    private enum PreviewState {
        case loading
        case loaded(metadata: ArchiveMetadata)
        case encrypted(ArchiveMetadata)
        case error(String)
    }

    private var previewState: PreviewState = .loading
    private var rootNodes: [ArchiveTreeNode] = []
    private var metadata: ArchiveMetadata?
    private var archiveURL: URL?

    // MARK: Views

    private var headerIconView: NSImageView!
    private var headerTitleLabel: NSTextField!
    private var headerDetailLabel: NSTextField!
    private var openInM7Button: NSButton!
    private var outlineView: NSOutlineView!
    private var statusLabel: NSTextField!

    static let zipContainerFallbackExtensions: Set<String> = [
        "ipa", "apk", "apks", "aab",
        "jar", "war", "ear", "aar",
        "xpi", "whl", "vsix", "appx", "msix",
        "cbz", "kmz"
    ]

    // MARK: QLPreviewingController

    func preparePreviewOfFile(at url: URL) async throws {
        archiveURL = url
        setState(.loading)

        let detector = ArchiveTypeDetector()
        let format: ArchiveFormat
        do {
            if let detectedFormat = try detector.detect(fileURL: url) {
                format = detectedFormat
            } else if let fallbackFormat = Self.fallbackPreviewFormat(for: url) {
                format = fallbackFormat
            } else {
                setState(.error("Unsupported archive format."))
                return
            }
        } catch {
            setState(.error("Unable to inspect archive format: \(error.localizedDescription)"))
            return
        }

        let newState = await Task.detached(priority: .userInitiated) { () -> (PreviewState, [ArchiveTreeNode]) in
            let options = ArchiveOperationOptions()

            do {
                let entries = try await Self.listPreviewEntries(format: format, archiveURL: url, options: options)
                let hasEncrypted = entries.contains { $0.isEncrypted }
                let meta = ArchiveMetadata(
                    format: format,
                    isEncrypted: hasEncrypted,
                    entriesCount: entries.count,
                    uncompressedSize: entries.compactMap { $0.size }.reduce(0, +),
                    compressedSize: ArchiveMetadata.compressedSize(from: entries, archiveURL: url)
                )
                if hasEncrypted {
                    return (.encrypted(meta), [])
                }
                
                let nodes = Self.buildTree(from: entries)
                return (.loaded(metadata: meta), nodes)
            } catch {
                if Self.isEncryptionError(error) {
                    return (.encrypted(ArchiveMetadata(format: format, isEncrypted: true)), [])
                }
                return (.error(error.localizedDescription), [])
            }
        }.value

        rootNodes = newState.1
        setState(newState.0)
    }

    static func fallbackPreviewFormat(for url: URL) -> ArchiveFormat? {
        let ext = url.pathExtension.lowercased()
        guard zipContainerFallbackExtensions.contains(ext) else { return nil }
        return .zip
    }

    private nonisolated static func isEncryptionError(_ error: some Error) -> Bool {
        let text = String(describing: error).lowercased()
        return text.contains("password") || text.contains("encrypt")
    }

    private nonisolated static func listPreviewEntries(
        format: ArchiveFormat,
        archiveURL: URL,
        options: ArchiveOperationOptions
    ) async throws -> [ArchiveEntry] {
        let engine = try ArchiveEngineSelector(selectionPolicy: .inProcessOnly)
            .makeEngine(for: format, requestedCapabilities: [.listContents])
        do {
            return try await engine.listContents(of: archiveURL, options: options)
        } catch {
            guard format == .sevenZip else { throw error }
            return try await SevenZipEngine().listContents(of: archiveURL, options: options)
        }
    }

    private nonisolated static func buildTree(from entries: [ArchiveEntry]) -> [ArchiveTreeNode] {
        let rootNode = ArchiveTreeNode(row: ArchiveRow.directory(name: "root", path: ""))
        var nodeCache: [String: ArchiveTreeNode] = ["": rootNode]
        
        for entry in entries {
            let pathComponents = entry.path.split(separator: "/").map(String.init)
            guard !pathComponents.isEmpty else { continue }
            
            var currentPath = ""
            var parentNode = rootNode
            
            for (index, component) in pathComponents.enumerated() {
                let isLast = index == pathComponents.count - 1
                currentPath = currentPath.isEmpty ? component : "\(currentPath)/\(component)"
                
                if let existingNode = nodeCache[currentPath] {
                    if isLast {
                        existingNode.row = ArchiveRow(entry: entry)
                    }
                    parentNode = existingNode
                } else {
                    let newNodeRow: ArchiveRow
                    if isLast {
                        newNodeRow = ArchiveRow(entry: entry)
                    } else {
                        newNodeRow = ArchiveRow.directory(name: component, path: currentPath)
                    }
                    
                    let newNode = ArchiveTreeNode(row: newNodeRow)
                    parentNode.children.append(newNode)
                    nodeCache[currentPath] = newNode
                    parentNode = newNode
                }
            }
        }
        
        func sortTree(_ node: ArchiveTreeNode) {
            node.children.sort { a, b in
                if a.row.isDirectory != b.row.isDirectory {
                    return a.row.isDirectory ? true : false
                }
                return a.row.name.localizedStandardCompare(b.row.name) == .orderedAscending
            }
            for child in node.children {
                sortTree(child)
            }
        }
        
        sortTree(rootNode)
        return rootNode.children
    }

    // MARK: Lifecycle

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: 380))
        buildUI()
    }

    // MARK: UI Construction

    private func buildUI() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        stack.addArrangedSubview(buildHeader())
        
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(separator)
        separator.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        
        stack.addArrangedSubview(buildOutlineScroll())
        stack.addArrangedSubview(buildStatusLabel())
    }

    private func buildHeader() -> NSView {
        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        header.heightAnchor.constraint(equalToConstant: 64).isActive = true

        headerIconView = NSImageView()
        headerIconView.translatesAutoresizingMaskIntoConstraints = false
        headerIconView.imageScaling = .scaleProportionallyUpOrDown

        headerTitleLabel = NSTextField(labelWithString: "")
        headerTitleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        headerTitleLabel.lineBreakMode = .byTruncatingMiddle
        headerTitleLabel.translatesAutoresizingMaskIntoConstraints = false

        headerDetailLabel = NSTextField(labelWithString: "")
        headerDetailLabel.font = .systemFont(ofSize: 11)
        headerDetailLabel.textColor = .secondaryLabelColor
        headerDetailLabel.lineBreakMode = .byTruncatingMiddle
        headerDetailLabel.translatesAutoresizingMaskIntoConstraints = false

        openInM7Button = NSButton(title: "Open in M7Archiver", target: self, action: #selector(openInM7ArchiverClicked))
        openInM7Button.bezelStyle = .rounded
        openInM7Button.controlSize = .small
        openInM7Button.translatesAutoresizingMaskIntoConstraints = false

        header.addSubview(headerIconView)
        header.addSubview(headerTitleLabel)
        header.addSubview(headerDetailLabel)
        header.addSubview(openInM7Button)

        NSLayoutConstraint.activate([
            headerIconView.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 16),
            headerIconView.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            headerIconView.widthAnchor.constraint(equalToConstant: 48),
            headerIconView.heightAnchor.constraint(equalToConstant: 48),

            headerTitleLabel.leadingAnchor.constraint(equalTo: headerIconView.trailingAnchor, constant: 12),
            headerTitleLabel.topAnchor.constraint(equalTo: header.topAnchor, constant: 14),
            headerTitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: openInM7Button.leadingAnchor, constant: -8),

            headerDetailLabel.leadingAnchor.constraint(equalTo: headerTitleLabel.leadingAnchor),
            headerDetailLabel.topAnchor.constraint(equalTo: headerTitleLabel.bottomAnchor, constant: 2),
            headerDetailLabel.trailingAnchor.constraint(lessThanOrEqualTo: openInM7Button.leadingAnchor, constant: -8),

            openInM7Button.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -16),
            openInM7Button.centerYAnchor.constraint(equalTo: header.centerYAnchor)
        ])

        return header
    }

    private func buildOutlineScroll() -> NSScrollView {
        outlineView = NSOutlineView()
        outlineView.headerView = NSTableHeaderView()

        let nameCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameCol.title = "Name"
        nameCol.width = 330
        nameCol.minWidth = 150
        nameCol.resizingMask = .autoresizingMask
        outlineView.addTableColumn(nameCol)
        outlineView.outlineTableColumn = nameCol

        let typeCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("type"))
        typeCol.title = "Type"
        typeCol.width = 70
        typeCol.minWidth = 50
        typeCol.maxWidth = 100
        typeCol.resizingMask = .userResizingMask
        outlineView.addTableColumn(typeCol)

        let sizeCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("size"))
        sizeCol.title = "Size"
        sizeCol.width = 80
        sizeCol.minWidth = 60
        sizeCol.maxWidth = 100
        sizeCol.resizingMask = .userResizingMask
        outlineView.addTableColumn(sizeCol)

        let modifiedCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("date"))
        modifiedCol.title = "Modified"
        modifiedCol.width = 115
        modifiedCol.minWidth = 110
        modifiedCol.maxWidth = 140
        modifiedCol.resizingMask = .userResizingMask
        outlineView.addTableColumn(modifiedCol)

        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.usesAlternatingRowBackgroundColors = true
        outlineView.allowsMultipleSelection = false
        outlineView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        
        let scroll = NSScrollView()
        scroll.documentView = outlineView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        return scroll
    }

    private func buildStatusLabel() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        
        let heightConstraint = container.heightAnchor.constraint(equalToConstant: 0)
        heightConstraint.identifier = "statusHeight"
        heightConstraint.isActive = true

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = .systemFont(ofSize: 13)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .center
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])

        return container
    }

    // MARK: Actions

    @objc private func openInM7ArchiverClicked() {
        guard let url = archiveURL else { return }
        var components = URLComponents()
        components.scheme = "m7archiver"
        components.host = "open"
        components.queryItems = [
            URLQueryItem(name: "files", value: url.path),
            URLQueryItem(name: "format", value: "repeated")
        ]
        guard let schemeURL = components.url else {
            showStatus("Unable to build M7Archiver URL.", height: 80)
            return
        }

        Task { @MainActor [weak self] in
            if NSWorkspace.shared.open(schemeURL) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    if QLPreviewPanel.sharedPreviewPanelExists() {
                        QLPreviewPanel.shared().orderOut(nil)
                    }
                }
            } else {
                self?.showStatus("Unable to open in M7Archiver.", height: 80)
            }
        }
    }

    // MARK: State Update

    private func setState(_ state: PreviewState) {
        previewState = state
        switch state {
        case .loading:
            rootNodes = []
            headerTitleLabel.stringValue = "Loading..."
            headerDetailLabel.stringValue = ""
            headerIconView.image = NSWorkspace.shared.icon(for: .zip)
            metadata = nil
            outlineView.reloadData()
            showStatus("", height: 0)

        case .loaded(let meta):
            metadata = meta
            if let url = archiveURL {
                headerTitleLabel.stringValue = url.lastPathComponent
            } else {
                headerTitleLabel.stringValue = "Archive"
            }
            headerIconView.image = icon(for: meta.format)
            
            let countText = meta.entriesCount.map {
                "\($0) \($0 == 1 ? "entry" : "entries")"
            } ?? "— entries"
            let sizeStr = meta.uncompressedSize.map { ArchiveByteFormatter.string($0, isDirectory: false) } ?? "--"
            headerDetailLabel.stringValue = "\(countText) · \(sizeStr) uncompressed"
            outlineView.reloadData()
            showStatus("", height: 0)

        case .encrypted(let meta):
            rootNodes = []
            headerTitleLabel.stringValue = "Encrypted Archive"
            headerDetailLabel.stringValue = meta.format.rawValue.uppercased()
            headerIconView.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "Encrypted")
                ?? icon(for: meta.format)
            metadata = meta
            outlineView.reloadData()
            showStatus("This archive is encrypted — preview is not available.", height: 80)

        case .error(let message):
            rootNodes = []
            headerTitleLabel.stringValue = "Unable to Preview"
            headerDetailLabel.stringValue = ""
            headerIconView.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Error")
                ?? NSWorkspace.shared.icon(for: .zip)
            metadata = nil
            outlineView.reloadData()
            showStatus(message, height: 80)
        }
    }

    private func showStatus(_ text: String, height: CGFloat) {
        statusLabel.stringValue = text
        guard let container = statusLabel.superview else { return }
        if let constraint = container.constraints.first(where: { $0.identifier == "statusHeight" }) {
            constraint.constant = height
        }
    }

    private func icon(for format: ArchiveFormat) -> NSImage {
        guard let ext = ArchiveFormatCatalog.shared.definition(for: format)?.extensions.first else {
            return NSWorkspace.shared.icon(for: .zip)
        }
        if let utType = UTType(filenameExtension: ext) {
            return NSWorkspace.shared.icon(for: utType)
        }
        return NSWorkspace.shared.icon(for: .zip)
    }

    private static func icon(for row: ArchiveRow) -> NSImage {
        if row.isDirectory {
            return NSWorkspace.shared.icon(for: .folder)
        }
        let ext = (row.name as NSString).pathExtension
        let uttype = ext.isEmpty ? nil : UTType(filenameExtension: ext)
        return NSWorkspace.shared.icon(for: uttype ?? .data)
    }
}

// MARK: - NSOutlineViewDataSource

extension PreviewViewController: NSOutlineViewDataSource {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil {
            return rootNodes.count
        }
        guard let node = item as? ArchiveTreeNode else { return 0 }
        return node.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? ArchiveTreeNode else { return false }
        return node.row.isDirectory && !node.children.isEmpty
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil {
            return rootNodes[index]
        }
        let node = item as! ArchiveTreeNode
        return node.children[index]
    }
}

// MARK: - NSOutlineViewDelegate

extension PreviewViewController: NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let column = tableColumn, let node = item as? ArchiveTreeNode else { return nil }
        let row = node.row

        let text: String
        switch column.identifier.rawValue {
        case "name":
            text = row.name
        case "type":
            text = row.fileType
        case "size":
            text = ArchiveByteFormatter.string(row.size, isDirectory: row.isDirectory)
        case "date":
            text = ArchiveDateFormatter.string(row.modifiedAt)
        default:
            text = ""
        }

        if column.identifier.rawValue == "name" {
            let cell = NSTableCellView()
            let iconView = NSImageView()
            iconView.image = Self.icon(for: row)
            iconView.image?.size = NSSize(width: 16, height: 16)
            iconView.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(iconView)

            let field = NSTextField(labelWithString: text)
            field.font = .systemFont(ofSize: 12)
            field.lineBreakMode = .byTruncatingMiddle
            field.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(field)

            NSLayoutConstraint.activate([
                iconView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                iconView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                iconView.widthAnchor.constraint(equalToConstant: 16),
                iconView.heightAnchor.constraint(equalToConstant: 16),
                
                field.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                field.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -2)
            ])
            return cell
        }

        let cell = NSTableCellView()
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 12)
        field.lineBreakMode = .byTruncatingTail
        
        if column.identifier.rawValue == "size" {
            field.alignment = .right
        }
        
        field.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(field)
        
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        
        return cell
    }
}
