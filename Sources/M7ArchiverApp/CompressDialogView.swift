import SwiftUI
import ArchiveCore

/// Native sheet for the toolbar Save / Compress action, with optional encryption.
struct CompressDialogView: View {
    private enum PasswordStrength {
        case weak, medium, strong
        var label: String {
            switch self {
            case .weak: return "Weak"
            case .medium: return "Medium"
            case .strong: return "Strong"
            }
        }
        var tint: Color {
            switch self {
            case .weak: return .red
            case .medium: return .yellow
            case .strong: return .green
            }
        }
        var ratio: Double {
            switch self {
            case .weak: return 1.0 / 3.0
            case .medium: return 2.0 / 3.0
            case .strong: return 1.0
            }
        }
    }

    nonisolated private static var sliderLevels: [CompressionLevel] { CompressionLevel.allCases }

    @Environment(\.dismiss) private var dismiss

    @Bindable var settings: ArchiveSettings
    @State var draft: CompressionDraft

    var onCompress: ((CompressionProfile, String?, String?, Bool) -> Void)?
    var onBeginCompress: (() -> Void)?
    var onOpenCompressionSettings: (() -> Void)?
    var onCancel: (() -> Void)?

    init(
        settings: ArchiveSettings,
        onBeginCompress: (() -> Void)? = nil,
        onOpenCompressionSettings: (() -> Void)? = nil,
        onCancel: (() -> Void)? = nil,
        onCompress: ((CompressionProfile, String?, String?, Bool) -> Void)? = nil
    ) {
        self.settings = settings
        self.onBeginCompress = onBeginCompress
        self.onOpenCompressionSettings = onOpenCompressionSettings
        self.onCancel = onCancel
        self.onCompress = onCompress
        _draft = State(initialValue: Self.draft(for: settings))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            mainPanel

            footer
        }
        .frame(width: 520)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Compress Archive", systemImage: "doc.zipper")
                .font(.title3.weight(.semibold))
            Text("Choose the format, compression strength, and optional protection for this archive.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel", role: .cancel) {
                onCancel?()
                dismiss()
            }
            Button("Compress") { startCompress() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canCreateArchive)
        }
        .padding(16)
    }

    private var mainPanel: some View {
        Form {
            Section {
                formatRow
                if Self.showsCompressionLevelControl(for: draft.format) {
                    compressionLevelRow
                }
            }
            
            Section {
                if Self.showsFilenameEncodingControl(for: draft.format) {
                    encodingRow
                }
                if Self.showsSolidControl(for: draft.format) {
                    solidRow
                }
                if Self.showsSplitVolumeControls(for: draft.format) {
                    splitVolumeRow
                }
                if !draft.capturedIgnoreRules.isEmpty {
                    ignoreRulesRow
                }
            }

            Section {
                encryptionRow
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .scrollContentBackground(.hidden)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var formatRow: some View {
        HStack {
            Text("Format")
            Spacer()
            Picker("Format", selection: $draft.format) {
                ForEach(creatableFormats, id: \.self) { format in
                    Text(format.displayLabel).tag(format)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .onChange(of: draft.format) { _, newValue in applyFormatChange(newValue) }
        }
    }

    private var encodingRow: some View {
        HStack {
            Text("Encoding")
            Spacer()
            Picker("Encoding", selection: $draft.encoding) {
                ForEach(ArchiveEncoding.allCases.filter { $0 != .automatic }, id: \.self) { encoding in
                    Text(encoding.displayLabel).tag(encoding)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
        }
    }

    private var compressionLevelRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Compression Level")
                Spacer()
                Text(label(for: draft.level))
                    .foregroundStyle(.secondary)
            }

            Slider(
                value: compressionLevelSliderValue,
                in: 0...Double(Self.sliderLevels.count - 1),
                step: 1
            )
            .labelsHidden()
            .frame(maxWidth: .infinity)

            HStack {
                Text("Store")
                Spacer()
                Text("Normal")
                Spacer()
                Text("Ultra")
            }
            .frame(maxWidth: .infinity)
            .font(.system(size: 9))
            .foregroundStyle(.tertiary)
            .padding(.top, -4)

            Text(draft.format == .sevenZip ? "LZMA2 compression engine" : "Deflate compression engine")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

    }

    private var solidRow: some View {
        HStack {
            Text("Solid archive")
            Spacer()
            Toggle("Solid archive", isOn: $draft.solid)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .onChange(of: draft.solid) { _, newValue in applySolidChange(newValue) }
        }

    }

    private var splitVolumeRow: some View {
        Group {
            HStack {
                Text("Split archive")
                Spacer()
                Toggle("Split archive", isOn: Binding(
                    get: { !draft.splitVolumeMB.isEmpty },
                    set: { newValue in
                        withAnimation(.easeOut(duration: 0.2)) {
                            if newValue {
                                if draft.splitVolumeMB.isEmpty { 
                                    draft.splitVolumeMB = "100" 
                                }
                            } else {
                                draft.splitVolumeMB = ""
                            }
                        }
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            }

            if !draft.splitVolumeMB.isEmpty {
                HStack {
                    HStack(spacing: 4) {
                        ForEach(Self.quickSplitVolumeSizesMB, id: \.self) { size in
                            Button(quickSizeLabel(for: size)) { applySplitVolumeChange(size) }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                    }

                    Spacer()

                    HStack(spacing: 4) {
                        TextField("", text: $draft.splitVolumeMB)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                            .lineLimit(1)
                            .onChange(of: draft.splitVolumeMB) { _, newValue in applySplitVolumeChange(newValue) }

                        Text("MB")
                            .foregroundStyle(.secondary)
                            .padding(.leading, 2)
                    }
                }

                if !Self.isValidSplitVolumeMB(draft.splitVolumeMB) {
                    HStack {
                        Spacer()
                        Label("Use a positive whole number.", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
    }

    private var ignoreRulesRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Apply ignore rules")
                Spacer()
                if onOpenCompressionSettings != nil {
                    Button(action: { onOpenCompressionSettings?() }) {
                        Image(systemName: "gearshape")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                Toggle("Apply ignore rules", isOn: $draft.applyDefaultIgnoreRules)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            Text(ignoredItemsSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
        }

    }

    private var encryptionRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Enable Encryption")
                Spacer()
                Toggle("Enable Encryption", isOn: $draft.useEncryption)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .onChange(of: draft.useEncryption) { _, newValue in applyEncryptionChange(newValue) }
            }

            if draft.useEncryption {
                VStack(alignment: .leading, spacing: 10) {
                    if Self.showsEditableEncryptionMethodPicker(for: draft.format) {
                        HStack {
                            Text("Method")
                            Spacer()
                            Picker("Method", selection: $draft.method) {
                                ForEach(EncryptionMethod.allCases.filter { $0.isSupported(by: draft.format) }) { item in
                                    Text(item.displayLabel).tag(item)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                        }
                    }

                    if Self.showsFixedEncryptionMethod(for: draft.format) {
                        HStack {
                            Text("Method")
                            Spacer()
                            Text("AES-256")
                                .foregroundStyle(.secondary)
                        }
                    }

                    SecureField("Password", text: $draft.password)
                        .textFieldStyle(.roundedBorder)
                    SecureField("Verify", text: $draft.confirm)
                        .textFieldStyle(.roundedBorder)

                    if !draft.password.isEmpty {
                        strengthMeter
                    }
                    if !draft.password.isEmpty, !draft.confirm.isEmpty, draft.password != draft.confirm {
                        Label("Passwords do not match.", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    if Self.showsEncryptFileNamesControl(for: draft) {
                        HStack {
                            Text("Encrypt file names")
                            Spacer()
                            Toggle("Encrypt file names", isOn: $draft.encryptFileNames)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .onChange(of: draft.encryptFileNames) { _, newValue in
                                    applyEncryptFileNamesChange(newValue)
                                }
                        }
                    }

                    if Self.showsSaveInKeychain(for: draft) {
                        HStack {
                            Text("Save password in Keychain")
                            Spacer()
                            Toggle("Save password in Keychain", isOn: $draft.saveInKeychain)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.small)
                        }
                    }
                }
                .padding(.leading, 12)
                .padding(.top, 4)
            }
        }

    }

    var ignoredItemsSummary: String {
        Self.ignoredItemsSummary(for: draft.capturedIgnoreRules)
    }

    static func ignoredItemsSummary(for rules: [IgnoreRule]) -> String {
        let patterns = rules.map(\.pattern)
        guard !patterns.isEmpty else { return "Ignore default patterns" }
        let head = patterns.prefix(2).map { "“\($0)”" }.joined(separator: ", ")
        return patterns.count > 2 ? "Ignore \(head), …" : "Ignore \(head)"
    }

    nonisolated static func showsSevenZipOnlyControls(for format: ArchiveFormat) -> Bool {
        format == .sevenZip
    }

    nonisolated static func showsCompressionLevelControl(for format: ArchiveFormat) -> Bool {
        format == .zip || format == .sevenZip
    }

    nonisolated static func showsSolidControl(for format: ArchiveFormat) -> Bool {
        format == .sevenZip
    }

    nonisolated static func showsSplitVolumeControls(for format: ArchiveFormat) -> Bool {
        format == .sevenZip
    }

    nonisolated static func showsFilenameEncodingControl(for format: ArchiveFormat) -> Bool {
        format == .zip
    }

    nonisolated static func showsEditableEncryptionMethodPicker(for format: ArchiveFormat) -> Bool {
        format == .zip
    }

    nonisolated static func showsFixedEncryptionMethod(for format: ArchiveFormat) -> Bool {
        format == .sevenZip
    }

    nonisolated static func showsEncryptFileNamesControl(for draft: CompressionDraft) -> Bool {
        draft.useEncryption && draft.format == .sevenZip
    }

    nonisolated static func showsSaveInKeychain(for draft: CompressionDraft) -> Bool {
        draft.useEncryption
    }

    nonisolated static func compressionLevelIndex(for level: CompressionLevel) -> Int {
        sliderLevels.firstIndex(of: level) ?? firstCompressionLevelIndex
    }

    nonisolated static func compressionLevel(forSliderValue value: Double) -> CompressionLevel {
        let clamped = max(0, min(Int(value.rounded()), sliderLevels.count - 1))
        return sliderLevels[clamped]
    }

    nonisolated private static var firstCompressionLevelIndex: Int { 0 }

    nonisolated static func canCreateArchive(with draft: CompressionDraft) -> Bool {
        let splitVolumeReady = draft.format != .sevenZip || Self.isValidSplitVolumeMB(draft.splitVolumeMB)
        let encryptionReady = !draft.useEncryption || (!draft.password.isEmpty && draft.password == draft.confirm)
        let encryptionMethodReady = !draft.useEncryption || draft.method.isSupported(by: draft.format)
        return splitVolumeReady && encryptionReady && encryptionMethodReady
    }

    private var creatableFormats: [ArchiveFormat] { [.zip, .sevenZip] }

    private var compressionLevelSliderValue: Binding<Double> {
        Binding(
            get: { Double(Self.compressionLevelIndex(for: draft.level)) },
            set: { newValue in
                applyLevelChange(Self.compressionLevel(forSliderValue: newValue))
            }
        )
    }

    var canCreateArchive: Bool {
        Self.canCreateArchive(with: draft)
    }

    // MARK: - Password strength

    private var strengthMeter: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Strength").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(strength.label).font(.caption).foregroundStyle(strength.tint)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.secondary.opacity(0.2))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(strength.tint)
                        .frame(width: proxy.size.width * strength.ratio)
                }
            }
            .frame(height: 4)
        }
    }

    private var strength: PasswordStrength {
        switch draft.password.count {
        case 0...5: return .weak
        case 6...11: return .medium
        default: return .strong
        }
    }

    // MARK: - Actions

    private func startCompress() {
        guard canCreateArchive else { return }
        let profile = makeProfile()
        let pwd = draft.useEncryption && !draft.password.isEmpty ? draft.password : nil
        let token = draft.useEncryption ? draft.method.archiveToken : nil
        let doSaveKeychain = draft.useEncryption && draft.saveInKeychain
        let begin = onBeginCompress
        let callback = onCompress
        begin?()
        dismiss()
        DispatchQueue.main.async {
            DispatchQueue.main.async {
                callback?(profile, pwd, token, doSaveKeychain)
            }
        }
    }

    private func label(for level: CompressionLevel) -> String {
        switch level {
        case .store: return "Store"
        case .fastest: return "Fastest"
        case .fast: return "Fast"
        case .normal: return "Normal"
        case .maximum: return "Maximum"
        case .ultra: return "Ultra"
        }
    }

    private func quickSizeLabel(for size: Int) -> String {
        switch size {
        case 1024: return "1 GB"
        case 4095: return "4 GB"
        default: return "\(size) MB"
        }
    }
}
