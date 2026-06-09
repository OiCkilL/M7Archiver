import ArchiveCore

extension CompressDialogView {
    nonisolated static let quickSplitVolumeSizesMB = [100, 700, 1024, 4095]

    enum EncryptionMethod: String, CaseIterable, Identifiable {
        case aes256, aes128, zipCrypto

        var id: String { rawValue }

        var displayLabel: String {
            switch self {
            case .aes256: return "AES-256 (Recommended)"
            case .aes128: return "AES-128"
            case .zipCrypto: return "ZipCrypto (Legacy)"
            }
        }

        func isSupported(by format: ArchiveFormat) -> Bool {
            switch self {
            case .zipCrypto, .aes128: return format == .zip
            case .aes256: return format == .zip || format == .sevenZip
            }
        }

        var archiveToken: String {
            switch self {
            case .aes256: return "aes256"
            case .aes128: return "aes128"
            case .zipCrypto: return "traditional"
            }
        }
    }

    struct CompressionDraft {
        var format: ArchiveFormat
        var level: CompressionLevel
        var solid: Bool
        var splitVolumeMB: String
        var encoding: ArchiveEncoding

        var useEncryption: Bool
        var encryptFileNames: Bool
        var method: EncryptionMethod
        var password: String
        var confirm: String
        var saveInKeychain: Bool

        var applyDefaultIgnoreRules: Bool
        var capturedIgnoreRules: [IgnoreRule]
    }

    /// Default task-level draft. Does not read `settings.defaultProfileID` —
    /// the plan removes user-facing presets entirely. Captures Settings ignore
    /// rules at dialog-open time so later Settings edits do not mutate the
    /// in-flight task.
    static func draft(for settings: ArchiveSettings) -> CompressionDraft {
        let captured = enabledNormalizedIgnoreRules(from: settings.ignoreRules)
        let initialEncoding = settings.defaultEncoding == .automatic ? .utf8 : settings.defaultEncoding
        return CompressionDraft(
            format: .sevenZip,
            level: .normal,
            solid: true,
            splitVolumeMB: "",
            encoding: initialEncoding,
            useEncryption: false,
            encryptFileNames: false,
            method: .aes256,
            password: "",
            confirm: "",
            saveInKeychain: false,
            applyDefaultIgnoreRules: !captured.isEmpty,
            capturedIgnoreRules: captured
        )
    }

    /// Trim patterns, drop disabled rules, drop empty patterns.
    /// Independent of `IgnoreRulesDraft.normalized(_:)` because that helper
    /// also keeps disabled-but-non-empty rows for the Settings editor.
    nonisolated static func enabledNormalizedIgnoreRules(from rules: [IgnoreRule]) -> [IgnoreRule] {
        rules.compactMap { rule in
            guard rule.isEnabled else { return nil }
            let trimmed = rule.pattern.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return IgnoreRule(id: rule.id, pattern: trimmed, isEnabled: true, scope: rule.scope)
        }
    }

    func applyFormatChange(_ value: ArchiveFormat) {
        Self.applyFormatChange(value, to: &draft)
    }

    func applyLevelChange(_ value: CompressionLevel) {
        draft.level = value
    }

    func applySolidChange(_ value: Bool) {
        draft.solid = value
    }

    func applySplitVolumeChange(_ value: Int) {
        applySplitVolumeChange(String(value))
    }

    func applySplitVolumeChange(_ value: String) {
        draft.splitVolumeMB = value
    }

    func applyEncodingChange(_ value: ArchiveEncoding) {
        draft.encoding = value
    }

    func applyEncryptionChange(_ value: Bool) {
        Self.applyEncryptionChange(value, to: &draft)
    }

    func applyEncryptFileNamesChange(_ value: Bool) {
        draft.encryptFileNames = value
    }

    static func applyFormatChange(_ value: ArchiveFormat, to draft: inout CompressionDraft) {
        draft.format = value
        if value == .zip && draft.encoding == .automatic {
            draft.encoding = .utf8
        }
        // Format-compatible encryption method: 7z only supports aes256.
        if !draft.method.isSupported(by: value) { draft.method = .aes256 }
        if value != .sevenZip {
            draft.encryptFileNames = false
        } else if draft.useEncryption {
            draft.encryptFileNames = true
        }
    }

    static func applyEncryptionChange(_ value: Bool, to draft: inout CompressionDraft) {
        draft.useEncryption = value
        if !value {
            draft.encryptFileNames = false
            draft.saveInKeychain = false
        } else if draft.format == .sevenZip {
            draft.encryptFileNames = true
        }
    }

    nonisolated static func isValidSplitVolumeMB(_ value: String) -> Bool {
        volumeSizeBytes(from: value) != nil
    }

    /// Build a `CompressionProfile` directly from the draft, hardcoding the
    /// per-format rules from the plan. No `BuiltInCompressionProfiles`
    /// lookup. Wave 2 now exposes ZIP compression level directly, so ZIP keeps
    /// `draft.level` instead of forcing `.normal`.
    nonisolated static func makeProfile(from draft: CompressionDraft) -> CompressionProfile {
        let effectiveLevel = draft.level
        let method: String?
        let dictionarySize: Int64?
        let solid: Bool?

        switch draft.format {
        case .zip:
            method = nil // engine default (deflate)
            dictionarySize = nil
            solid = nil
        case .sevenZip:
            method = draft.level == .store ? nil : "lzma2"
            dictionarySize = draft.level == .ultra ? 256 * 1024 * 1024 : nil
            solid = draft.solid
        default:
            method = nil
            dictionarySize = nil
            solid = nil
        }

        let volumeSize: Int64?
        if draft.format == .sevenZip {
            volumeSize = volumeSizeBytes(from: draft.splitVolumeMB) ?? nil
        } else {
            volumeSize = nil
        }

        let encryptFileNames = draft.useEncryption && draft.format == .sevenZip
            ? draft.encryptFileNames
            : false

        let ignoreRules = draft.applyDefaultIgnoreRules ? draft.capturedIgnoreRules : []

        return CompressionProfile(
            id: "task",
            name: "Task",
            format: draft.format,
            level: effectiveLevel,
            method: method,
            solid: solid,
            dictionarySize: dictionarySize,
            volumeSize: volumeSize,
            encryptFileNames: encryptFileNames,
            ignoreRules: ignoreRules,
            filenameEncoding: draft.encoding == .automatic ? nil : draft.encoding
        )
    }

    func makeProfile() -> CompressionProfile {
        Self.makeProfile(from: draft)
    }

    nonisolated private static func volumeSizeBytes(from value: String) -> Int64?? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .some(nil) }
        guard let megabytes = Int64(trimmed), megabytes > 0 else { return nil }
        guard megabytes <= Int64.max / 1_048_576 else { return nil }
        return .some(megabytes * 1_048_576)
    }

    nonisolated static func splitVolumeString(for volumeSize: Int64?) -> String {
        guard let volumeSize else { return "" }
        return String(volumeSize / (1024 * 1024))
    }
}
