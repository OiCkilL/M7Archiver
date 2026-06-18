import Foundation
import AppKit
import UniformTypeIdentifiers
import ArchiveCore

@MainActor
enum QuickCompressAction {
    private static var isCompressing = false
    static func fixedProfile(format: ArchiveFormat, settings: ArchiveSettings) -> CompressionProfile {
        let ignoreRules = CompressDialogView.enabledNormalizedIgnoreRules(from: settings.ignoreRules)
        switch format {
        case .zip:
            return CompressionProfile(
                name: "Quick ZIP",
                format: .zip,
                level: .normal,
                method: nil,
                solid: nil,
                dictionarySize: nil,
                volumeSize: nil,
                encryptFileNames: false,
                ignoreRules: ignoreRules,
                filenameEncoding: nil
            )
        case .sevenZip:
            return CompressionProfile(
                name: "Quick 7z",
                format: .sevenZip,
                level: .normal,
                method: "lzma2",
                solid: true,
                dictionarySize: nil,
                volumeSize: nil,
                encryptFileNames: false,
                ignoreRules: ignoreRules,
                filenameEncoding: nil
            )
        default:
            return CompressionProfile(name: "Quick", format: format, ignoreRules: ignoreRules)
        }
    }

    static func quickActionDestination(sources: [URL], finderTarget: URL?, format: ArchiveFormat) -> URL? {
        let standardizedSources = sources.map(\.standardizedFileURL)
        guard !standardizedSources.isEmpty else { return nil }

        let directory = preferredDestinationDirectory(sources: standardizedSources, finderTarget: finderTarget)
        guard let directory else { return nil }
        let stem = AddToArchive.suggestedStem(for: standardizedSources)
        return directory.appendingPathComponent(stem).appendingPathExtension(format.rawValue)
    }

    static func preferredDestinationDirectory(sources: [URL], finderTarget: URL?) -> URL? {
        let standardizedSources = sources.map(\.standardizedFileURL)
        guard !standardizedSources.isEmpty else { return nil }

        if standardizedSources.count == 1 {
            return standardizedSources[0].deletingLastPathComponent()
        }

        let selectedPaths = Set(standardizedSources.map(\.path))
        if let finderTarget = finderTarget?.standardizedFileURL,
           !selectedPaths.contains(finderTarget.path) {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: finderTarget.path, isDirectory: &isDir), isDir.boolValue {
                return finderTarget
            }
        }

        let parents = Set(standardizedSources.map { $0.deletingLastPathComponent().standardizedFileURL.path })
        if parents.count == 1, let path = parents.first {
            return URL(fileURLWithPath: path, isDirectory: true)
        }

        return nil
    }

    static func run(format: ArchiveFormat, sources: [URL], finderTarget: URL?, settings: ArchiveSettings) async {
        guard !sources.isEmpty else { return }
        guard !isCompressing else { return }
        isCompressing = true
        defer { isCompressing = false }

        let profile = fixedProfile(format: format, settings: settings)
        let proposedDestination = quickActionDestination(sources: sources, finderTarget: finderTarget, format: format)
        let destination: URL
        let destinationAllowsExistingFile: Bool
        if let proposedDestination,
           isUsableDestination(proposedDestination) {
            destination = proposedDestination
            destinationAllowsExistingFile = false
        } else {
            guard let chosen = fallbackSavePanel(
                format: format,
                sources: sources,
                finderTarget: finderTarget,
                suggestedURL: proposedDestination
            ) else { return }
            destination = chosen
            destinationAllowsExistingFile = true
        }

        guard destinationAllowsExistingFile ? isWritableDestinationDirectory(destination) : isUsableDestination(destination) else {
            presentAlert(title: "Compression Failed", message: "Choose a different destination.")
            return
        }

        let session = ArchiveSession(defaultEncoding: settings.defaultEncoding)
        let dockToken = DockProgressController.shared.observe { [session] in
            session.progress?.fraction
        }
        let outcome = await session.createArchive(from: sources, to: destination, profile: profile)
        _ = dockToken  // held until report clears the source
        switch outcome {
        case .completed(let outputURLs, _):
            if settings.revealInFinderAfterCreate, let first = outputURLs.first {
                NSWorkspace.shared.activateFileViewerSelecting([first])
            }
            DockProgressController.shared.report(.success, title: "Compression Finished", body: destination.lastPathComponent, hasWindow: false)
        case .failed(let message):
            presentAlert(title: "Compression Failed", message: message)
            DockProgressController.shared.report(.failure, title: "Compression Failed", body: message, hasWindow: false)
        case .missingSelection:
            presentAlert(title: "Compression Failed", message: "Select at least one item to compress.")
        }
    }

    static func isUsableDestination(_ destination: URL) -> Bool {
        guard isWritableDestinationDirectory(destination) else { return false }
        return !FileManager.default.fileExists(atPath: destination.path)
    }

    static func isWritableDestinationDirectory(_ destination: URL) -> Bool {
        let directory = destination.deletingLastPathComponent().standardizedFileURL
        return isWritableDirectory(directory)
    }

    static func isWritableDirectory(_ directory: URL) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDir), isDir.boolValue else { return false }
        let probe = directory.appendingPathComponent(".m7archiver-write-probe-\(UUID().uuidString)")
        do {
            try Data().write(to: probe, options: .atomic)
            try FileManager.default.removeItem(at: probe)
            return true
        } catch {
            try? FileManager.default.removeItem(at: probe)
            return false
        }
    }

    private static func fallbackSavePanel(
        format: ArchiveFormat,
        sources: [URL],
        finderTarget: URL?,
        suggestedURL: URL?
    ) -> URL? {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.title = "Compress to \(format.displayLabel)"
        panel.nameFieldStringValue = suggestedURL?.lastPathComponent ?? "\(AddToArchive.suggestedStem(for: sources)).\(format.rawValue)"
        panel.directoryURL = suggestedURL?.deletingLastPathComponent() ?? preferredDestinationDirectory(sources: sources, finderTarget: finderTarget)
        if let type = UTType(filenameExtension: format.rawValue) {
            panel.allowedContentTypes = [type]
        }
        guard panel.runModal() == .OK, let chosen = panel.url else { return nil }
        let finalURL = ensureExtension(for: chosen, format: format)
        if finalURL != chosen,
           FileManager.default.fileExists(atPath: finalURL.path) {
            presentAlert(title: "Compression Failed", message: "Choose a different destination.")
            return nil
        }
        return finalURL
    }

    private static func ensureExtension(for url: URL, format: ArchiveFormat) -> URL {
        guard url.pathExtension.isEmpty else { return url }
        return url.appendingPathExtension(format.rawValue)
    }

    private static func presentAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
