import SwiftUI
import AppKit
import ArchiveCore

@MainActor
final class CompressWindowPresenter: NSObject, NSWindowDelegate {
    static let shared = CompressWindowPresenter()

    private var controller: NSWindowController?
    private var model: ArchiveWindowModel?
    private var hostingController: NSHostingController<AnyView>?

    func show(
        sources: [URL]? = nil,
        finderTarget: URL? = nil,
        model: ArchiveWindowModel? = nil,
        settings: ArchiveSettings,
        savedPasswords: SavedPasswordsStore
    ) {
        // If a window is already open, dismiss it first so a different caller's
        // model can present.  Matches the old FinderAddToArchiveWindowPresenter's
        // replace semantics; the "focus existing" reuse semantics broke the
        // per-window staging path (the new model was never bound).
        if controller?.window != nil {
            dismiss()
        }

        let activeModel = model ?? ArchiveWindowModel(settings: settings, savedPasswords: savedPasswords)
        self.model = activeModel
        
        if let sources = sources, !sources.isEmpty {
            activeModel.stageFinderCreateRequest(sources: sources, finderTarget: finderTarget)
        }

        let rootView = CompressDialogView(
            settings: settings,
            onBeginCompress: {
                activeModel.pendingCreateSubmissionInFlight = true
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
                guard let self else { return }
                // Keep the window open and swap its content to a live progress
                // view bound to the model, so large archives show real
                // percentage (7-Zip) instead of vanishing silently.
                self.hostingController?.rootView = AnyView(CompressProgressView(model: activeModel))
                await activeModel.createArchiveFromNewPanel(
                    profile: profile,
                    password: password,
                    encryptionMethod: encryptionMethod,
                    saveInKeychain: saveInKeychain
                )
                self.dismiss(matching: activeModel)
            }
        }
        
        // Use NSHostingController to allow SwiftUI to drive the window's size automatically.
        // rootView is wrapped in AnyView so the onCompress closure can swap it to
        // CompressProgressView (a different root type) without re-creating the controller.
        let hostingController = NSHostingController(rootView: AnyView(rootView))
        hostingController.sizingOptions = [.intrinsicContentSize]
        self.hostingController = hostingController

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        
        // Modern macOS 15 Window Styling
        // Title is set (but hidden) so tests can locate this window and window
        // switchers show a meaningful name; users see a clean titlebar.
        window.title = "Compress Archive"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.hasShadow = true
        window.backgroundColor = .clear // Allows SwiftUI Material to show through
        
        window.contentViewController = hostingController
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

    func dismiss(matching expectedModel: ArchiveWindowModel? = nil) {
        // Guard against stale `.onChange` else-branch calls: when show() dismisses
        // another model's dialog, that model's flag reset fires asynchronously on
        // the next runloop, by which point `self.model` is the NEW model.  Without
        // this guard the stale call would dismiss the just-opened dialog.
        if let expectedModel, model !== expectedModel { return }
        let activeController = controller
        let activeModel = model
        controller = nil
        model = nil
        hostingController = nil
        activeModel?.handleNewArchiveDialogDismissed()
        activeController?.close()
    }
}
