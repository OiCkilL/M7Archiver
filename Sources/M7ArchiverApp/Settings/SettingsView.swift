import SwiftUI
import AppKit
import Combine

enum SettingsTab: String, CaseIterable {
    case general
    case compression
    case formats
    case passwords
    case about

    var label: String {
        switch self {
        case .general: return "General"
        case .compression: return "Compression"
        case .formats: return "Formats"
        case .passwords: return "Passwords"
        case .about: return "About"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .compression: return "archivebox"
        case .formats: return "doc.badge.gearshape"
        case .passwords: return "key"
        case .about: return "info.circle"
        }
    }
}

@MainActor
final class SettingsSelectionModel: ObservableObject {
    @Published var selectedTab: SettingsTab = .general
}

struct SettingsView: View {
    @Bindable var settings: ArchiveSettings
    @Bindable var savedPasswords: SavedPasswordsStore
    @ObservedObject var selectionModel: SettingsSelectionModel

    init(
        settings: ArchiveSettings,
        savedPasswords: SavedPasswordsStore,
        selectionModel: SettingsSelectionModel = SettingsSelectionModel()
    ) {
        self.settings = settings
        self.savedPasswords = savedPasswords
        self.selectionModel = selectionModel
    }

    var body: some View {
        content(for: selectionModel.selectedTab)
            .frame(minWidth: 760, idealWidth: 800, minHeight: 520)
    }

    @ViewBuilder
    private func content(for tab: SettingsTab) -> some View {
        switch tab {
        case .general:
            GeneralSettingsView(settings: settings)
        case .compression:
            CompressionSettingsView(settings: settings)
        case .formats:
            FileAssociationsSettingsView(settings: settings)
        case .passwords:
            PasswordsSettingsView(store: savedPasswords)
        case .about:
            AboutSettingsView()
                .frame(minWidth: 560, idealWidth: 620, maxWidth: 680)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
        }
    }
}

@MainActor
final class SettingsToolbarCoordinator: NSObject, NSToolbarDelegate {
    private let selectionModel: SettingsSelectionModel

    init(selectionModel: SettingsSelectionModel) {
        self.selectionModel = selectionModel
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsTab.allCases.map { NSToolbarItem.Identifier($0.rawValue) }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarAllowedItemIdentifiers(toolbar)
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarAllowedItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard let tab = SettingsTab(rawValue: itemIdentifier.rawValue) else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = tab.label
        item.paletteLabel = tab.label
        item.image = NSImage(systemSymbolName: tab.icon, accessibilityDescription: tab.label)
        item.target = self
        item.action = #selector(selectToolbarItem(_:))
        return item
    }

    @objc private func selectToolbarItem(_ sender: NSToolbarItem) {
        guard let tab = SettingsTab(rawValue: sender.itemIdentifier.rawValue) else { return }
        selectionModel.selectedTab = tab
        sender.toolbar?.selectedItemIdentifier = sender.itemIdentifier
    }
}
