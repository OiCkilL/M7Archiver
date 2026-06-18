import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ArchiveCore
import ArchivePresentation

// MARK: - Pending operation state

struct PendingAutoExtractRequest: Equatable {
    var archiveURL: URL
    var finderTarget: URL?
    var extractToSubfolder: Bool  // false = extractHere, true = extractToFolder
    init(archiveURL: URL, finderTarget: URL? = nil, extractToSubfolder: Bool = true) {
        self.archiveURL = archiveURL.standardizedFileURL
        self.finderTarget = finderTarget?.standardizedFileURL
        self.extractToSubfolder = extractToSubfolder
    }
}

struct PendingAutoExtractState {
    private(set) var request: PendingAutoExtractRequest?
    mutating func stage(_ request: PendingAutoExtractRequest) { self.request = request }
    mutating func clear() { request = nil }
    mutating func consumeIfReady(openArchiveURL: URL?, lockState: ArchiveSession.LockState) -> PendingAutoExtractRequest? {
        guard let request, lockState == .unlocked else { return nil }
        guard openArchiveURL?.standardizedFileURL == request.archiveURL else { return nil }
        self.request = nil
        return request
    }
}

struct PendingPromptedExtractRequest: Equatable {
    var archiveURL: URL
    var finderTarget: URL?
    init(archiveURL: URL, finderTarget: URL? = nil) {
        self.archiveURL = archiveURL.standardizedFileURL
        self.finderTarget = finderTarget?.standardizedFileURL
    }
}

struct PendingPromptedExtractState {
    private(set) var request: PendingPromptedExtractRequest?
    mutating func stage(_ request: PendingPromptedExtractRequest) { self.request = request }
    mutating func clear() { request = nil }
    mutating func consumeIfReady(openArchiveURL: URL?, lockState: ArchiveSession.LockState) -> PendingPromptedExtractRequest? {
        guard let request, lockState == .unlocked else { return nil }
        guard openArchiveURL?.standardizedFileURL == request.archiveURL else { return nil }
        self.request = nil
        return request
    }
}

struct PendingTestArchiveRequest: Equatable {
    var archiveURL: URL
    init(archiveURL: URL) { self.archiveURL = archiveURL.standardizedFileURL }
}

struct PendingTestArchiveState {
    private(set) var request: PendingTestArchiveRequest?
    mutating func stage(_ request: PendingTestArchiveRequest) { self.request = request }
    mutating func clear() { request = nil }
    mutating func consumeIfReady(openArchiveURL: URL?, lockState: ArchiveSession.LockState) -> PendingTestArchiveRequest? {
        guard let request, lockState == .unlocked else { return nil }
        guard openArchiveURL?.standardizedFileURL == request.archiveURL else { return nil }
        self.request = nil
        return request
    }
}

enum PendingCreateSource: Equatable {
    case staging
    case finder
}

struct PendingCreateArchiveRequest: Equatable {
    var sources: [URL]
    var finderTarget: URL?
    var source: PendingCreateSource

    init(sources: [URL], finderTarget: URL? = nil, source: PendingCreateSource) {
        self.sources = sources.map(\.standardizedFileURL)
        self.finderTarget = finderTarget?.standardizedFileURL
        self.source = source
    }
}

enum PendingCreateOutcome {
    case cancel
    case failure
    case success
}

// MARK: - Staging

/// A file or folder staged for new-archive creation.
struct StagingItem: Identifiable {
    let id = UUID()
    let url: URL
    var name: String { url.lastPathComponent }
    var size: Int64?
    var isDirectory: Bool
}

// MARK: - Window Mode

enum WindowMode {
    case default_    // no archive open, staging empty
    case staging     // no archive open, staging has files
    case viewing     // archive is open
}

// MARK: - Window Model (reference type — shared between factory callers and SwiftUI)

/// Per-window state owned by a reference type so that factory callers and
/// the SwiftUI view tree operate on the same instance.  Methods that mutate
/// `@State`-like properties must live here, not on the View struct.
@MainActor
@Observable
final class ArchiveWindowModel {
    var session = ArchiveSession()
    var pendingAutoExtract = PendingAutoExtractState()
    var pendingPromptedExtract = PendingPromptedExtractState()
    var pendingTestArchive = PendingTestArchiveState()
    var pendingCreateRequest: PendingCreateArchiveRequest?
    var newArchiveDialogPresented = false
    var pendingCreateSubmissionInFlight = false

    /// Files staged for creating a new archive.
    var stagingSources: [StagingItem] = []
    private var stagingExplicit = false


    var mode: WindowMode {
        if session.hasArchive { return .viewing }
        if stagingExplicit || !stagingSources.isEmpty { return .staging }
        return .default_
    }

    /// True when this window is busy (archive loaded, staging, or loading).
    var isOccupied: Bool { session.hasArchive || mode != .default_ }

    /// Set to `true` while an async open is in-flight; prevents batch-URL
    /// handling and menu actions from routing a second open onto the same shell.
    var isOpening = false

    /// Temp directories created for nested archive extraction; cleaned up
    /// when the window/tab closes.
    var tempRoots: [URL] = []

    func cleanupTempRoots() {
        for root in tempRoots {
            try? FileManager.default.removeItem(at: root)
        }
        tempRoots = []
    }

    let settings: ArchiveSettings
    let savedPasswords: SavedPasswordsStore

    init(settings: ArchiveSettings, savedPasswords: SavedPasswordsStore) {
        self.settings = settings
        self.savedPasswords = savedPasswords
        session.applyDefaultEncoding(settings.defaultEncoding)
        session.applyAutomaticEncodingPriority(settings.automaticEncodingPriority)
    }

    // Temp roots are cleaned by onDisappear before deinit.
    // Stale registry entries are harmless (weak refs).

    // MARK: - CA-safe helpers

    /// Yields past the current CA::Transaction::commit so that subsequent
    /// `@Observable` mutations don't entangle during a commit phase.
    func afterAppKitTransaction() async {
        await withCheckedContinuation { c in
            DispatchQueue.main.async {
                DispatchQueue.main.async { c.resume() }
            }
        }
    }

    // MARK: - URL handling

    func handleOpenURL(_ url: URL, autoExtract: Bool) {
        if url.scheme == AppUrlParser.scheme {
            guard let parsed = AppUrlParser.parse(url),
                  let validated = AppUrlParser.validated(parsed) else { return }
            handleValidatedAppURL(validated, autoExtract: autoExtract)
            return
        }
        guard url.isFileURL else { return }
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        isOpening = true
        Task {
            if autoExtract {
                await openArchiveAndMaybeAutoExtract(url)
            } else {
                clearPendingExtractRequests()
                pendingTestArchive.clear()
                await openSessionWithSavedPassword(session: session, savedPasswords: savedPasswords, archiveURL: url)
            }
            isOpening = false
        }
    }

    // MARK: - Staging

    /// Transition to staging mode.  Does not clear existing staging items —
    /// call `clearStaging()` explicitly if a fresh start is needed.
    func enterStagingMode() {
        stagingExplicit = true
    }

    func addToStaging(_ urls: [URL]) {
        var existingURLs = Set(stagingSources.map { $0.url.standardizedFileURL })
        let fileManager = FileManager.default
        for url in urls {
            let standardized = url.standardizedFileURL
            guard !existingURLs.contains(standardized) else { continue }
            var isDir: ObjCBool = false
            let exists = fileManager.fileExists(atPath: standardized.path, isDirectory: &isDir)
            guard exists else { continue }
            existingURLs.insert(standardized)
            let size: Int64? = isDir.boolValue ? nil : {
                if let values = try? standardized.resourceValues(forKeys: [.fileSizeKey]) {
                    return Int64(values.fileSize ?? 0)
                }
                return nil
            }()
            stagingSources.append(StagingItem(
                url: standardized,
                size: size,
                isDirectory: isDir.boolValue
            ))
        }
    }

    func removeFromStaging(_ ids: Set<UUID>) {
        stagingSources.removeAll { ids.contains($0.id) }
    }

    func clearStaging() {
        stagingExplicit = false
        stagingSources = []
    }

    var isCompressing = false

    func presentStagingCompress() {
        let sources = stagingSources.map(\.url)
        guard !sources.isEmpty else { return }
        pendingCreateRequest = PendingCreateArchiveRequest(sources: sources, source: .staging)
        newArchiveDialogPresented = true
    }

    func stageFinderCreateRequest(sources: [URL], finderTarget: URL?) {
        guard !sources.isEmpty else { return }
        pendingCreateRequest = PendingCreateArchiveRequest(sources: sources, finderTarget: finderTarget, source: .finder)
        newArchiveDialogPresented = true
    }

    // MARK: - New Archive panel

    func presentNewArchivePanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Select files and folders to add to the new archive."
        guard panel.runModal() == .OK else { return }
        addToStaging(panel.urls)
    }

    // MARK: - Open Archive panel

    func presentOpenArchivePanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        let archiveTypes: [UTType] = [.zip, .archive]
            + ArchiveFormatCatalog.shared.formats
                .flatMap(\.extensions)
                .compactMap { UTType(filenameExtension: $0) }
        panel.allowedContentTypes = Array(Set(archiveTypes))
        guard panel.runModal() == .OK, let url = panel.url else { return }
        clearStaging()
        isOpening = true
        Task {
            clearPendingExtractRequests()
            pendingTestArchive.clear()
            await openSessionWithSavedPassword(session: session, savedPasswords: savedPasswords, archiveURL: url)
            isOpening = false
        }
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }

    // MARK: - Dropped file

    /// Open a dropped archive URL.  Callers pre-filter for archives.
    func handleDroppedArchive(_ url: URL) async {
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        // If this window is staging, don't steal it — open archive elsewhere.
        if mode == .staging {
            M7ArchiverApp.openArchiveInNewWindow(url: url, settings: settings, savedPasswords: savedPasswords)
            return
        }

        guard session.hasArchive else {
            clearPendingExtractRequests()
            pendingTestArchive.clear()
            isOpening = true
            await openSessionWithSavedPassword(session: session, savedPasswords: savedPasswords, archiveURL: url)
            isOpening = false
            return
        }
        // Drop on an open archive: open in new window.
        M7ArchiverApp.openArchiveInNewWindow(url: url, settings: settings, savedPasswords: savedPasswords)
    }

    // MARK: - Create archive

    func clearPendingCreateRequest(_ shouldClearStaging: Bool = false) {
        pendingCreateRequest = nil
        if shouldClearStaging {
            stagingExplicit = false
            stagingSources = []
        }
    }

    func handlePendingCreateOutcome(_ outcome: PendingCreateOutcome) {
        guard let request = pendingCreateRequest else { return }
        // Single convergence point for all dialog outcomes (cancel/failure/success,
        // including NSSavePanel cancel).  Reset the presented flag here so the
        // standalone NSWindow flow can re-open on the next staging/Finder request;
        // under the old .sheet binding SwiftUI cleared this automatically.
        newArchiveDialogPresented = false
        switch request.source {
        case .staging:
            switch outcome {
            case .cancel, .failure:
                break
            case .success:
                clearPendingCreateRequest(true)
            }
        case .finder:
            clearPendingCreateRequest()
        }
    }

    func handleNewArchiveDialogDismissed() {
        guard !pendingCreateSubmissionInFlight else { return }
        handlePendingCreateOutcome(.cancel)
    }

    func createArchiveFromNewPanel(profile: CompressionProfile, password: String?, encryptionMethod: String?, saveInKeychain: Bool) async {
        guard let request = pendingCreateRequest else { return }
        let sources = request.sources
        guard !sources.isEmpty else { return }
        let suggestedName = AddToArchive.suggestedStem(for: sources) + "." + profile.format.rawValue
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = suggestedName
        panel.directoryURL = AddToArchive.preferredDestinationDirectory(for: sources, finderTarget: request.finderTarget)
        guard panel.runModal() == .OK, let destination = panel.url else {
            pendingCreateSubmissionInFlight = false
            handlePendingCreateOutcome(.cancel)
            return
        }
        await afterAppKitTransaction()
        isCompressing = true
        let dockToken = DockProgressController.shared.observe { [weak self] in
            self?.session.progress?.fraction
        }
        let outcome = await session.createArchive(
            from: sources, to: destination, profile: profile,
            password: password, encryptionMethod: encryptionMethod
        )
        isCompressing = false
        _ = dockToken  // released below after report; report clears sources
        pendingCreateSubmissionInFlight = false
        switch outcome {
        case .completed(let outputs, _):
            if let first = outputs.first {
                if saveInKeychain, let pwd = password {
                    savedPasswords.save(password: pwd, for: first)
                }
                await afterAppKitTransaction()
                if settings.revealInFinderAfterCreate {
                    NSWorkspace.shared.activateFileViewerSelecting([first])
                }
                if settings.openArchiveAfterCreate {
                    M7ArchiverApp.openArchiveInNewWindow(url: first, settings: settings, savedPasswords: savedPasswords)
                }
            }
            handlePendingCreateOutcome(.success)
            DockProgressController.shared.report(.success, title: "Compression Finished", body: destination.lastPathComponent)
        case .failed(let message):
            handlePendingCreateOutcome(.failure)
            alert("Compression Failed", message)
            DockProgressController.shared.report(.failure, title: "Compression Failed", body: message)
        case .missingSelection:
            handlePendingCreateOutcome(.failure)
            alert("Compression Failed", "Select at least one item to compress.")
        }
    }

    // MARK: - App URL handler

    func handleValidatedAppURL(_ appUrl: AppUrl, autoExtract: Bool) {
        let files = appUrl.files
        guard !files.isEmpty else { return }
        let action = appUrl.action
        let target = appUrl.target
        isOpening = true
        Task {
            switch action {
            case .extractHere:
                for file in files {
                    await openArchiveAndMaybeAutoExtract(file, finderTarget: target, extractToSubfolder: false)
                    if session.shouldStopMultiFileOperation { break }
                }
            case .extractToFolder:
                for file in files {
                    await openArchiveAndMaybeAutoExtract(file, finderTarget: target)
                    if session.shouldStopMultiFileOperation { break }
                }
            case .extractFiles:
                for file in files {
                    await openArchiveAndMaybePromptedExtract(file, finderTarget: target)
                    if session.shouldStopMultiFileOperation { break }
                }
            case .open:
                if autoExtract {
                    for file in files {
                        await openArchiveAndMaybeAutoExtract(file)
                        if session.shouldStopMultiFileOperation { break }
                    }
                } else {
                    clearPendingExtractRequests()
                    pendingTestArchive.clear()
                    NSDocumentController.shared.noteNewRecentDocumentURL(files[0])
                    await openSessionWithSavedPassword(session: session, savedPasswords: savedPasswords, archiveURL: files[0])
                }
            case .addToArchive:
                clearPendingExtractRequests()
                pendingTestArchive.clear()
                stageFinderCreateRequest(sources: files, finderTarget: target)
            case .addTo7z:
                await QuickCompressAction.run(format: .sevenZip, sources: files, finderTarget: target, settings: settings)
            case .addToZip:
                await QuickCompressAction.run(format: .zip, sources: files, finderTarget: target, settings: settings)
            case .testArchive:
                for file in files {
                    await openArchiveAndMaybeTestArchive(file)
                    if session.shouldStopMultiFileOperation { break }
                }
            }
            isOpening = false
        }
    }

    private func handleAppURL(_ appUrl: AppUrl, autoExtract: Bool) {
        handleValidatedAppURL(appUrl, autoExtract: autoExtract)
    }

    // MARK: - Auto / prompted extract

    private func openArchiveAndMaybeAutoExtract(_ archiveURL: URL, finderTarget: URL? = nil, extractToSubfolder: Bool = true) async {
        pendingPromptedExtract.clear()
        pendingTestArchive.clear()
        pendingAutoExtract.stage(PendingAutoExtractRequest(archiveURL: archiveURL, finderTarget: finderTarget, extractToSubfolder: extractToSubfolder))
        await openSessionWithSavedPassword(session: session, savedPasswords: savedPasswords, archiveURL: archiveURL)
        await resumePendingOperationsIfNeeded()
    }

    private func openArchiveAndMaybePromptedExtract(_ archiveURL: URL, finderTarget: URL? = nil) async {
        pendingAutoExtract.clear()
        pendingTestArchive.clear()
        pendingPromptedExtract.stage(PendingPromptedExtractRequest(archiveURL: archiveURL, finderTarget: finderTarget))
        await openSessionWithSavedPassword(session: session, savedPasswords: savedPasswords, archiveURL: archiveURL)
        await resumePendingOperationsIfNeeded()
    }

    private func openArchiveAndMaybeTestArchive(_ archiveURL: URL) async {
        clearPendingExtractRequests()
        pendingTestArchive.stage(PendingTestArchiveRequest(archiveURL: archiveURL))
        await openSessionWithSavedPassword(session: session, savedPasswords: savedPasswords, archiveURL: archiveURL)
        await resumePendingOperationsIfNeeded()
    }

    private func clearPendingExtractRequests() {
        pendingAutoExtract.clear()
        pendingPromptedExtract.clear()
    }

    func resumePendingOperationsIfNeeded() async {
        await resumePendingAutoExtractIfNeeded()
        await resumePendingPromptedExtractIfNeeded()
        await resumePendingTestArchiveIfNeeded()
    }

    private func resumePendingAutoExtractIfNeeded() async {
        guard let request = pendingAutoExtract.consumeIfReady(openArchiveURL: session.archiveURL, lockState: session.lockState) else { return }
        await AutoExtract.run(session: session, settings: settings, archiveURL: request.archiveURL, finderTarget: request.finderTarget, extractToSubfolder: request.extractToSubfolder)
    }

    private func resumePendingPromptedExtractIfNeeded() async {
        guard let request = pendingPromptedExtract.consumeIfReady(openArchiveURL: session.archiveURL, lockState: session.lockState) else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Extract"
        panel.title = "Extract Files"
        panel.directoryURL = preferredPromptedExtractDirectory(for: request)
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let dockToken = DockProgressController.shared.observe { [weak self] in
            self?.session.progress?.fraction
        }
        let outcome = await session.extract(to: destination)
        _ = dockToken  // held until report clears the source
        switch outcome {
        case .completed:
            if settings.revealInFinderAfterExtract {
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            }
            DockProgressController.shared.report(.success, title: "Extraction Finished", body: destination.lastPathComponent)
        case .cancelled:
            DockProgressController.shared.report(.cancelled, title: "Extraction Cancelled", body: destination.lastPathComponent)
        default:
            presentPromptedExtractionFailure(outcome)
            DockProgressController.shared.report(.failure, title: "Extraction Failed", body: destination.lastPathComponent)
        }
    }

    private func resumePendingTestArchiveIfNeeded() async {
        guard let request = pendingTestArchive.consumeIfReady(openArchiveURL: session.archiveURL, lockState: session.lockState) else { return }
        await AutoVerify.run(session: session, archiveURL: request.archiveURL)
    }

    // MARK: - Nested archive tab

    func openNestedArchive(_ row: ArchiveRow) async {
        guard let hostWindow = NSApp.keyWindow else { return }

        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("M7Archiver-nested-", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        } catch { return }

        let outcome = await session.extractEntry(path: row.path, to: tempRoot)
        guard case .completed = outcome else {
            try? FileManager.default.removeItem(at: tempRoot)
            return
        }

        // Compute exact output path (handles nested archives inside subdirectories).
        let nestedURL = tempRoot.appendingPathComponent(row.path)
        guard (try? ArchiveTypeDetector().detect(fileURL: nestedURL)) != nil else {
            try? FileManager.default.removeItem(at: tempRoot)
            return
        }

        // Transfer temp root ownership to the nested window's model.
        let nestedModel = M7ArchiverApp.openNestedArchiveInTab(
            url: nestedURL,
            settings: settings,
            savedPasswords: savedPasswords,
            sourceWindow: hostWindow
        )
        nestedModel.tempRoots.append(tempRoot)
    }

    // MARK: - Helpers

    private func preferredPromptedExtractDirectory(for request: PendingPromptedExtractRequest) -> URL {
        if let finderTarget = request.finderTarget {
            var isDir: ObjCBool = false
            let isDirPath = FileManager.default.fileExists(atPath: finderTarget.path, isDirectory: &isDir) && isDir.boolValue
            return isDirPath ? finderTarget : finderTarget.deletingLastPathComponent()
        }
        return request.archiveURL.deletingLastPathComponent()
    }

    private func presentPromptedExtractionFailure(_ outcome: ArchiveSession.ExtractionOutcome) {
        let message: String
        switch outcome {
        case .completed: return
        case .unsupportedBackend(let format): message = "\(format.displayLabel) extraction is not available with the current backend."
        case .locked: message = "Unlock the archive before extracting files."
        case .missingArchive: message = "No archive is open."
        case .missingSelection: message = "Select at least one item to extract."
        case .cancelled: return
        case .failed(let details): message = details
        }
        alert("Extraction Failed", message)
    }

    private func alert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

// MARK: - Shell (thin SwiftUI View wrapper around the model)

/// Thin SwiftUI view that binds to an `ArchiveWindowModel`. All mutable
/// state lives on the model (reference type), so factory callers receive
/// the same instance that the hosted view tree observes.
struct ArchiveWindowShell: View {
    @Bindable var model: ArchiveWindowModel

    var body: some View {
        ArchiveWindowView(
            session: model.session,
            settings: model.settings,
            savedPasswords: model.savedPasswords,
            mode: model.mode,
            stagingItems: model.stagingSources,
            isCompressing: model.isCompressing,
            onUnlockSuccess: { await model.resumePendingOperationsIfNeeded() },
            onOpenFile: { url in Task { await model.handleDroppedArchive(url) } },
            onOpenNestedArchive: { row in Task { await model.openNestedArchive(row) } },
            onNewArchive: {
                if model.isOccupied {
                    M7ArchiverApp.createEmptyWindow(
                        settings: model.settings,
                        savedPasswords: model.savedPasswords
                    ).enterStagingMode()
                } else {
                    model.clearStaging()
                    model.enterStagingMode()
                }
            },
            onOpenArchive: { model.presentOpenArchivePanel() },
            onAddFiles: { model.presentNewArchivePanel() },
            onStageFiles: { model.addToStaging($0) },
            onRemoveFromStaging: { model.removeFromStaging($0) },
            onClearStaging: { model.clearStaging() },
            onCompressStaging: { model.presentStagingCompress() }
        )
        .onChange(of: model.newArchiveDialogPresented) { _, isPresented in
            if isPresented {
                CompressWindowPresenter.shared.show(
                    model: model,
                    settings: model.settings,
                    savedPasswords: model.savedPasswords
                )
            } else {
                CompressWindowPresenter.shared.dismiss(matching: model)
            }
        }
        .background(WindowCapturingView { window in
            WindowRegistry.shared.register(for: window, model: model)
        })
        .onChange(of: model.settings.defaultEncoding) { _, newValue in
            model.session.applyDefaultEncoding(newValue)
        }
        .onChange(of: model.settings.encodingPriorityOrder) { _, _ in
            model.session.applyAutomaticEncodingPriority(model.settings.automaticEncodingPriority)
        }
        .onChange(of: model.settings.disabledAutomaticEncodings) { _, _ in
            model.session.applyAutomaticEncodingPriority(model.settings.automaticEncodingPriority)
        }
        .onDisappear {
            model.cleanupTempRoots()
        }
    }

}

// MARK: - Window Registry

/// Tracks model ↔ NSWindow associations so menu actions can dispatch to
/// the correct session and tabs can be created.
@MainActor
final class WindowRegistry {
    static let shared = WindowRegistry()

    private struct Entry {
        weak var model: ArchiveWindowModel?
        weak var window: NSWindow?
    }
    private var entries: [Entry] = []

    func register(for window: NSWindow, model: ArchiveWindowModel) {
        // Keep `isReleasedWhenClosed = false` so ARC doesn't dealloc the window
        // while it's still on screen (factory windows have no external strong ref).
        window.isReleasedWhenClosed = false
        entries.removeAll { $0.window == nil }
        entries.removeAll { $0.window === window }
        entries.append(Entry(model: model, window: window))
    }

    var activeModel: ArchiveWindowModel? {
        entries.removeAll { $0.window == nil }
        guard let keyWindow = NSApp.keyWindow ?? NSApp.mainWindow else {
            return entries.last(where: { $0.model != nil })?.model
        }
        return entries.first(where: { $0.window === keyWindow })?.model
    }

    /// All currently-live window models (windows that have not yet closed).
    /// Used by the Dock progress controller to observe any in-flight operation
    /// across multiple windows.
    var allModels: [ArchiveWindowModel] {
        entries.removeAll { $0.window == nil }
        return entries.compactMap { $0.model }
    }
    func isTransientEmptyWindow(_ window: NSWindow) -> Bool {
        entries.removeAll { $0.window == nil }
        guard let entry = entries.first(where: { $0.window === window }),
              let model = entry.model else {
            return false
        }
        return model.mode == .default_ && !model.isOpening && !model.session.hasArchive
    }

}

/// Wraps `ArchiveWindowShell`, owning the `ArchiveWindowModel` as `@State`
/// so it survives SwiftUI body re-evaluations.  Used by `WindowGroup`.
struct ArchiveWindowBridge: View {
    let settings: ArchiveSettings
    let savedPasswords: SavedPasswordsStore
    var onAppear: () -> Void = {}

    @State private var model: ArchiveWindowModel?

    var body: some View {
        Group {
            if let model {
                ArchiveWindowShell(model: model)
            }
        }
        .onAppear {
            if model == nil {
                model = ArchiveWindowModel(settings: settings, savedPasswords: savedPasswords)
            }
            onAppear()
        }
    }
}

// MARK: - Window Capture

final class RegistryCaptureView: NSView {
    var onWindowFound: ((NSWindow) -> Void)?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window = self.window, let handler = onWindowFound {
            onWindowFound = nil  // run once
            handler(window)
        }
    }
}

struct WindowCapturingView: NSViewRepresentable {
    let onWindowFound: (NSWindow) -> Void

    func makeNSView(context: Context) -> RegistryCaptureView {
        let view = RegistryCaptureView()
        view.onWindowFound = onWindowFound
        return view
    }

    func updateNSView(_ nsView: RegistryCaptureView, context: Context) {}
}
