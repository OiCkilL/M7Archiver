import SwiftUI
import AppKit
import ArchiveCore

@MainActor
final class FinderAddToArchiveWindowPresenter: NSObject, NSWindowDelegate {
    static let shared = FinderAddToArchiveWindowPresenter()

    private var controller: NSWindowController?
    private var model: ArchiveWindowModel?

    func show(sources: [URL], finderTarget: URL?, settings: ArchiveSettings, savedPasswords: SavedPasswordsStore) {
        guard !sources.isEmpty else { return }
        dismiss()

        let model = ArchiveWindowModel(settings: settings, savedPasswords: savedPasswords)
        self.model = model
        model.stageFinderCreateRequest(sources: sources, finderTarget: finderTarget)

        let rootView = CompressDialogView(
            settings: settings,
            onBeginCompress: {
                model.pendingCreateSubmissionInFlight = true
            },
            onOpenCompressionSettings: {
                SettingsWindowPresenter.shared.show(
                    settings: settings,
                    savedPasswords: savedPasswords,
                    selectedTab: .compression
                )
            },
            onCancel: { [weak self] in
                self?.dismiss()
            }
        ) { [weak self] profile, password, encryptionMethod, saveInKeychain in
            Task { @MainActor in
                self?.controller?.close()
                self?.controller = nil
                self?.model = nil
                await model.createArchiveFromNewPanel(
                    profile: profile,
                    password: password,
                    encryptionMethod: encryptionMethod,
                    saveInKeychain: saveInKeychain
                )
            }
        }

        let hostingView = NSHostingView(rootView: rootView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Compress Archive"
        window.contentView = hostingView
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        let controller = NSWindowController(window: window)
        self.controller = controller
    }

    func windowWillClose(_ notification: Notification) {
        dismiss()
    }

    private func dismiss() {
        let activeController = controller
        let activeModel = model
        controller = nil
        model = nil
        activeModel?.handleNewArchiveDialogDismissed()
        activeController?.close()
    }
}
