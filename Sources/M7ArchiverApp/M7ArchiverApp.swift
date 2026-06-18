import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ArchiveCore

// MARK: - App Context (shared state)

@MainActor
@Observable
final class AppContext {
    var settings = ArchiveSettings()
    var savedPasswords = SavedPasswordsStore(backend: KeychainSavedPasswordsBackend())
}

// MARK: - Helpers

@MainActor
func openSessionWithSavedPassword(
    session: ArchiveSession,
    savedPasswords: SavedPasswordsStore,
    archiveURL: URL
) async {
    await session.open(url: archiveURL)
    if case .locked = session.lockState,
       let saved = savedPasswords.lookup(for: archiveURL) {
        await session.unlock(password: saved)
        if session.lockState == .locked(reason: .wrongPassword) {
            savedPasswords.delete(for: archiveURL)
        }
    }
}

// MARK: - App Delegate (menu bar for both .app and swift run)

@MainActor
final class M7ArchiverAppDelegate: NSObject, NSApplicationDelegate {
    let context = AppContext()
    var quickCompressRunner: (ArchiveFormat, [URL], URL?, ArchiveSettings) async -> Void = { format, sources, finderTarget, settings in
        await QuickCompressAction.run(format: format, sources: sources, finderTarget: finderTarget, settings: settings)
    }
    var headlessExtractRunner: (URL, URL?, Bool, ArchiveSettings, SavedPasswordsStore) async -> Void = { archiveURL, finderTarget, extractToSubfolder, settings, savedPasswords in
        await HeadlessExtractAction.run(
            archiveURL: archiveURL,
            finderTarget: finderTarget,
            extractToSubfolder: extractToSubfolder,
            settings: settings,
            savedPasswords: savedPasswords
        )
    }
    var allowsTransientQuickActionTermination = true

    private var isBuildingMenu = false
    private var pendingURLs: [URL] = []
    private var receivedExternalURL = false
    private var coalesceTimer: Timer?
    private weak var openRecentMenu: NSMenu?

    func application(_ application: NSApplication, open urls: [URL]) {
        receivedExternalURL = true
        pendingURLs.append(contentsOf: urls)
        coalesceTimer?.invalidate()
        coalesceTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.processPendingURLs()
            }
        }
    }

    private func processPendingURLs() {
        guard !pendingURLs.isEmpty else { return }
        let urls = pendingURLs
        pendingURLs = []
        openURLs(urls, context: context)
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return true }
        M7ArchiverApp.createEmptyWindow(settings: context.settings, savedPasswords: context.savedPasswords)
        return false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        makeSwiftRunExecutableForegroundApp()
        ensureMainMenu()
        DockProgressController.shared.start()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.ensureMainMenu(deferred: true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.openInitialWindowIfNeeded()
        }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.ensureMainMenu(deferred: true) }
        }
    }

    private func openInitialWindowIfNeeded() {
        guard !receivedExternalURL else { return }
        guard pendingURLs.isEmpty else { return }
        guard WindowRegistry.shared.activeModel == nil else { return }
        guard NSApp.windows.filter(\.isVisible).isEmpty else { return }
        M7ArchiverApp.createEmptyWindow(settings: context.settings, savedPasswords: context.savedPasswords)
    }

    func ensureMainMenu(deferred: Bool = false) {
        guard !isBuildingMenu else { return }
        isBuildingMenu = true
        if deferred {
            DispatchQueue.main.async { self._rebuildMenu() }
        } else {
            _rebuildMenu()
        }
    }

    private func _rebuildMenu() {
        buildMainMenu()
        isBuildingMenu = false
    }

    private func openURLs(_ urls: [URL], context: AppContext) {
        let fileURLs = urls.filter { $0.isFileURL }
        let schemeURLs = urls.filter { $0.scheme == AppUrlParser.scheme }

        for url in schemeURLs { openURL(url, context: context) }
        guard !fileURLs.isEmpty else { return }

        let detector = ArchiveTypeDetector()
        var archives: [URL] = []
        var regularFiles: [URL] = []
        for url in fileURLs {
            if (try? detector.detect(fileURL: url)) != nil { archives.append(url) }
            else { regularFiles.append(url) }
        }

        if regularFiles.isEmpty {
            for archiveURL in archives {
                let model: ArchiveWindowModel
                if let active = WindowRegistry.shared.activeModel, !active.isOccupied, !active.isOpening {
                    model = active
                } else {
                    model = M7ArchiverApp.createEmptyWindow(settings: context.settings, savedPasswords: context.savedPasswords)
                }
                model.handleOpenURL(archiveURL, autoExtract: context.settings.autoExtract)
            }
        } else {
            let allFiles = regularFiles + archives
            let model: ArchiveWindowModel
            if let active = WindowRegistry.shared.activeModel, active.mode == .staging || (!active.isOccupied && !active.isOpening) {
                model = active
            } else {
                model = M7ArchiverApp.createEmptyWindow(settings: context.settings, savedPasswords: context.savedPasswords)
            }
            if model.mode != .staging { model.enterStagingMode() }
            model.addToStaging(allFiles)
        }
    }

    private func openURL(_ url: URL, context: AppContext) {
        guard url.scheme == AppUrlParser.scheme else { return }
        guard let parsed = AppUrlParser.parse(url),
              let validated = AppUrlParser.validated(parsed) else { return }
        handleValidatedAppURL(validated, context: context)
    }

    func handleValidatedAppURL(_ validated: AppUrl, context: AppContext) {
        switch validated.action {
        case .addToZip:
            Task { @MainActor in
                await runQuickCompressFromURL(.zip, appUrl: validated, context: context)
            }
        case .addTo7z:
            Task { @MainActor in
                await runQuickCompressFromURL(.sevenZip, appUrl: validated, context: context)
            }
        case .extractHere:
            Task { @MainActor in
                for file in validated.files {
                    await headlessExtractRunner(file, validated.target, false, context.settings, context.savedPasswords)
                }
                scheduleTransientEmptyWindowCleanup()
            }
        case .extractToFolder:
            Task { @MainActor in
                for file in validated.files {
                    await headlessExtractRunner(file, validated.target, true, context.settings, context.savedPasswords)
                }
                scheduleTransientEmptyWindowCleanup()
            }
        case .addToArchive:
            CompressWindowPresenter.shared.show(
                sources: validated.files,
                finderTarget: validated.target,
                settings: context.settings,
                savedPasswords: context.savedPasswords
            )
            scheduleTransientEmptyWindowCleanup()
        default:
            let model: ArchiveWindowModel
            if let active = WindowRegistry.shared.activeModel, !active.isOccupied, !active.isOpening {
                model = active
            } else {
                model = M7ArchiverApp.createEmptyWindow(settings: context.settings, savedPasswords: context.savedPasswords)
            }
            model.handleValidatedAppURL(validated, autoExtract: context.settings.autoExtract)
        }
    }

    private func runQuickCompressFromURL(_ format: ArchiveFormat, appUrl: AppUrl, context: AppContext) async {
        await quickCompressRunner(format, appUrl.files, appUrl.target, context.settings)
        scheduleTransientEmptyWindowCleanup(shouldTerminate: true)
    }

    private func scheduleTransientEmptyWindowCleanup(shouldTerminate: Bool = false) {
        runTransientEmptyWindowCleanup(shouldTerminate: shouldTerminate)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.runTransientEmptyWindowCleanup(shouldTerminate: shouldTerminate)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.runTransientEmptyWindowCleanup(shouldTerminate: shouldTerminate)
        }
    }

    private func runTransientEmptyWindowCleanup(shouldTerminate: Bool) {
        closeTransientEmptyWindowsIfNeeded()
        if shouldTerminate {
            terminateIfOnlyTransientWindowsRemain()
        }
    }

    private func closeTransientEmptyWindowsIfNeeded() {
        for window in NSApp.windows where WindowRegistry.shared.isTransientEmptyWindow(window) {
            window.close()
        }
    }

    private func terminateIfOnlyTransientWindowsRemain() {
        guard allowsTransientQuickActionTermination, !isRunningUnderTests else { return }
        let visibleWindows = NSApp.windows.filter { $0.isVisible }
        guard visibleWindows.isEmpty || visibleWindows.allSatisfy({ WindowRegistry.shared.isTransientEmptyWindow($0) }) else {
            return
        }
        NSApp.terminate(nil)
    }

    private var isRunningUnderTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || Bundle.main.bundlePath.hasSuffix(".xctest")
    }

    private func makeSwiftRunExecutableForegroundApp() {
        guard NSApp.activationPolicy() != .regular else { return }
        NSApp.setActivationPolicy(.regular)
    }

    // MARK: - Menu construction

    private func buildMainMenu() {
        let mainMenu = NSMenu()
        let menuItems = [
            makeAppMenuItem(),
            makeFileMenuItem(),
            makeEditMenuItem(),
            makeWindowMenuItem(),
            makeHelpMenuItem()
        ]
        for item in menuItems {
            mainMenu.addItem(item)
        }
        NSApp.mainMenu = mainMenu
    }

    private func makeAppMenuItem() -> NSMenuItem {
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About M7Archiver", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(actionItem(title: "Settings\u{2026}", action: #selector(handlePreferences), keyEquivalent: ","))
        appMenu.addItem(.separator())
        let servicesItem = NSMenuItem()
        servicesItem.title = "Services"
        servicesItem.submenu = NSMenu()
        appMenu.addItem(servicesItem)
        NSApp.servicesMenu = servicesItem.submenu
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide M7Archiver", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthersItem = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit M7Archiver", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menuItem(submenu: appMenu)
    }

    private func makeFileMenuItem() -> NSMenuItem {
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(actionItem(title: "New Archive\u{2026}", action: #selector(handleNewArchive), keyEquivalent: "n"))
        fileMenu.addItem(actionItem(title: "Open\u{2026}", action: #selector(handleOpen), keyEquivalent: "o"))
        fileMenu.addItem(makeOpenRecentMenuItem())
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        return menuItem(submenu: fileMenu)
    }

    private func makeOpenRecentMenuItem() -> NSMenuItem {
        let recentItem = NSMenuItem()
        recentItem.title = "Open Recent"
        let recentMenu = NSMenu()
        populateOpenRecentMenu(recentMenu)
        openRecentMenu = recentMenu
        recentItem.submenu = recentMenu
        return recentItem
    }

    private func populateOpenRecentMenu(_ recentMenu: NSMenu) {
        recentMenu.removeAllItems()
        for url in NSDocumentController.shared.recentDocumentURLs where url.isFileURL {
            let item = actionItem(title: url.lastPathComponent, action: #selector(handleOpenRecent), keyEquivalent: "")
            item.representedObject = url
            recentMenu.addItem(item)
        }
        if !recentMenu.items.isEmpty {
            recentMenu.addItem(.separator())
        }
        let clearItem = NSMenuItem(
            title: "Clear Menu",
            action: #selector(handleClearRecent),
            keyEquivalent: ""
        )
        clearItem.target = self
        recentMenu.addItem(clearItem)
    }

    private func makeEditMenuItem() -> NSMenuItem {
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        return menuItem(submenu: editMenu)
    }

    private func makeWindowMenuItem() -> NSMenuItem {
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        NSApp.windowsMenu = windowMenu
        return menuItem(submenu: windowMenu)
    }

    private func makeHelpMenuItem() -> NSMenuItem {
        let helpMenu = NSMenu(title: "Help")
        helpMenu.addItem(actionItem(title: "M7Archiver Help", action: #selector(handleHelp), keyEquivalent: ""))
        return menuItem(submenu: helpMenu)
    }

    private func menuItem(submenu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem()
        item.title = submenu.title
        item.submenu = submenu
        return item
    }

    private func actionItem(title: String, action: Selector, keyEquivalent: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }

    // MARK: - Menu actions

    @objc private func handleNewArchive() {
        if let active = WindowRegistry.shared.activeModel, active.isOccupied {
            M7ArchiverApp.createEmptyWindow(settings: context.settings, savedPasswords: context.savedPasswords).enterStagingMode()
        } else {
            let model = WindowRegistry.shared.activeModel ?? M7ArchiverApp.createEmptyWindow(settings: context.settings, savedPasswords: context.savedPasswords)
            model.clearStaging()
            model.enterStagingMode()
        }
    }

    @objc private func handleOpen() {
        resolveModel().presentOpenArchivePanel()
    }

    @objc private func handleOpenRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        guard FileManager.default.fileExists(atPath: url.path) else {
            NSSound.beep()
            return
        }
        let model = resolveModel()
        model.clearStaging()
        model.handleOpenURL(url, autoExtract: false)
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        ensureMainMenu(deferred: true)
    }

    @objc private func handleClearRecent(_ sender: Any?) {
        NSDocumentController.shared.clearRecentDocuments(sender)
        if let openRecentMenu {
            populateOpenRecentMenu(openRecentMenu)
        }
        ensureMainMenu(deferred: true)
    }

    @objc private func handlePreferences() {
        SettingsWindowPresenter.shared.show(settings: context.settings, savedPasswords: context.savedPasswords)
    }

    @objc private func handleHelp() {
        if let url = URL(string: "https://github.com/user/m7archiver") {
            NSWorkspace.shared.open(url)
        }
    }

    private func resolveModel() -> ArchiveWindowModel {
        if let model = WindowRegistry.shared.activeModel, !model.isOpening { return model }
        return M7ArchiverApp.createEmptyWindow(settings: context.settings, savedPasswords: context.savedPasswords)
    }
}

// MARK: - Settings Window Presenter

@MainActor
final class SettingsWindowPresenter {
    static let shared = SettingsWindowPresenter()

    private var controller: NSWindowController?
    private var toolbarCoordinator: SettingsToolbarCoordinator?
    private let selectionModel = SettingsSelectionModel()

    func show(settings: ArchiveSettings, savedPasswords: SavedPasswordsStore, selectedTab: SettingsTab? = nil) {
        if let selectedTab {
            selectionModel.selectedTab = selectedTab
        }
        if let window = controller?.window {
            window.toolbar?.selectedItemIdentifier = NSToolbarItem.Identifier(selectionModel.selectedTab.rawValue)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let rootView = SettingsView(settings: settings, savedPasswords: savedPasswords, selectionModel: selectionModel)
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.autoresizingMask = [.width, .height] as NSView.AutoresizingMask
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.minSize = NSSize(width: 760, height: 520)
        window.maxSize = NSSize(width: 1000, height: 900)
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.toolbarStyle = .preference
        window.title = "Settings"
        let toolbar = NSToolbar(identifier: "M7ArchiverSettingsToolbar")
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        let coordinator = SettingsToolbarCoordinator(selectionModel: selectionModel)
        toolbar.delegate = coordinator
        toolbar.selectedItemIdentifier = NSToolbarItem.Identifier(selectionModel.selectedTab.rawValue)
        window.toolbar = toolbar
        toolbarCoordinator = coordinator

        window.contentView = hostingView
        window.isReleasedWhenClosed = false
        window.center()

        let ctrl = NSWindowController(window: window)
        self.controller = ctrl
        ctrl.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - App

@main
struct M7ArchiverApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: M7ArchiverAppDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }

    // MARK: - Window factory

    @discardableResult
    static func createEmptyWindow(settings: ArchiveSettings, savedPasswords: SavedPasswordsStore, frameAutosaveName: String = "M7ArchiverMain") -> ArchiveWindowModel {
        let model = ArchiveWindowModel(settings: settings, savedPasswords: savedPasswords)
        let shell = ArchiveWindowShell(model: model)
        let hostingView = NSHostingView(rootView: shell)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.title = "M7Archiver"
        window.toolbarStyle = .unified
        window.titlebarAppearsTransparent = true
        window.contentView = hostingView
        window.tabbingMode = .preferred
        window.setFrameAutosaveName(frameAutosaveName)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        WindowRegistry.shared.register(for: window, model: model)
        return model
    }

    @discardableResult
    static func openArchiveInNewWindow(url: URL, settings: ArchiveSettings, savedPasswords: SavedPasswordsStore) -> ArchiveWindowModel {
        let model = ArchiveWindowModel(settings: settings, savedPasswords: savedPasswords)
        let shell = ArchiveWindowShell(model: model)
        let hostingView = NSHostingView(rootView: shell)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.title = url.lastPathComponent
        window.toolbarStyle = .unified
        window.titlebarAppearsTransparent = true
        window.contentView = hostingView
        window.tabbingMode = .preferred
        window.setFrameAutosaveName("M7Archiver-" + url.lastPathComponent)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        WindowRegistry.shared.register(for: window, model: model)
        model.isOpening = true
        Task {
            await openSessionWithSavedPassword(session: model.session, savedPasswords: savedPasswords, archiveURL: url)
            model.isOpening = false
        }
        return model
    }

    @discardableResult
    static func openNestedArchiveInTab(url: URL, settings: ArchiveSettings, savedPasswords: SavedPasswordsStore, sourceWindow: NSWindow) -> ArchiveWindowModel {
        let model = ArchiveWindowModel(settings: settings, savedPasswords: savedPasswords)
        let shell = ArchiveWindowShell(model: model)
        let hostingView = NSHostingView(rootView: shell)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.title = url.lastPathComponent
        window.toolbarStyle = .unified
        window.titlebarAppearsTransparent = true
        window.contentView = hostingView
        window.tabbingMode = .preferred
        sourceWindow.addTabbedWindow(window, ordered: .above)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        WindowRegistry.shared.register(for: window, model: model)
        model.isOpening = true
        Task {
            await openSessionWithSavedPassword(session: model.session, savedPasswords: savedPasswords, archiveURL: url)
            model.isOpening = false
        }
        return model
    }
}
