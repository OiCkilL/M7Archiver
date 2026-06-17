import SwiftUI
import ArchiveCore

struct CompressionSettingsView: View {
    @Bindable var settings: ArchiveSettings

    var body: some View {
        SettingsPane(minWidth: 620, idealWidth: 700, maxWidth: 760) {
            SettingsGroup("After Compression") {
                Toggle("Reveal in Finder after creating an archive", isOn: $settings.revealInFinderAfterCreate)
                Toggle("Open the archive after creating it", isOn: $settings.openArchiveAfterCreate)
            }

            IgnoreRulesSettingsSection(settings: settings)
        }
    }
}

/// Normalization used by the persistent ignore-rule editor: trim whitespace
/// and drop empty patterns, but preserve disabled rules so the editor can
/// keep showing them. Distinct from
/// `CompressDialogView.enabledNormalizedIgnoreRules(from:)`, which drops
/// disabled rules for the per-task capture.
enum IgnoreRulesDraft {
    static func normalized(_ rules: [IgnoreRule]) -> [IgnoreRule] {
        rules.map { rule in
            IgnoreRule(
                id: rule.id,
                pattern: rule.pattern.trimmingCharacters(in: .whitespacesAndNewlines),
                isEnabled: rule.isEnabled,
                scope: rule.scope
            )
        }
        .filter { !$0.pattern.isEmpty }
    }
}

struct IgnoreRulesSettingsSection: View {
    @Bindable var settings: ArchiveSettings
    @State private var draftRules: [IgnoreRule]

    init(settings: ArchiveSettings) {
        self.settings = settings
        _draftRules = State(initialValue: settings.ignoreRules)
    }

    var body: some View {
        SettingsGroup("Exclusion Rules") {
            Text("Ignore rules are applied when creating archives. Patterns support * and ? wildcards.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if draftRules.isEmpty {
                Text("No ignore rules defined.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 8) {
                    ForEach($draftRules) { $rule in
                        ruleRow(rule: $rule)
                    }
                }
            }

            HStack {
                Button(action: addRule) {
                    Label("Add Rule", systemImage: "plus")
                }

                Spacer()

                Button("Restore Defaults") {
                    draftRules = IgnoreRule.defaultMacOSRules
                    commitDraftRules(removingInvalidRows: true)
                }
            }
            .padding(.top, 2)
        }
        .onAppear { draftRules = settings.ignoreRules }
        .onDisappear { commitDraftRules(removingInvalidRows: true) }
        .onChange(of: settings.ignoreRules) { _, newValue in
            guard IgnoreRulesDraft.normalized(newValue) != IgnoreRulesDraft.normalized(draftRules) else { return }
            draftRules = newValue
        }
    }

    private func ruleRow(rule: Binding<IgnoreRule>) -> some View {
        HStack(spacing: 8) {
            Toggle("Enabled", isOn: rule.isEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .onChange(of: rule.isEnabled.wrappedValue) { _, _ in commitDraftRules() }

            TextField("Pattern (e.g. .DS_Store)", text: rule.pattern)
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
                .onSubmit { commitDraftRules(removingInvalidRows: true) }
                .foregroundStyle(isValid(rule.wrappedValue) ? Color.primary : Color.red)

            Picker("Scope", selection: rule.scope) {
                ForEach(IgnoreRuleScope.allCases, id: \.self) { scope in
                    Text(label(for: scope)).tag(scope)
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 110)
            .onChange(of: rule.scope.wrappedValue) { _, _ in commitDraftRules() }

            Button(role: .destructive) {
                removeRule(id: rule.wrappedValue.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove ignore rule")
        }
        .padding(.vertical, 2)
    }

    private func addRule() {
        draftRules.append(IgnoreRule(id: UUID().uuidString, pattern: "", isEnabled: true, scope: .all))
    }

    private func removeRule(id: String) {
        draftRules.removeAll { $0.id == id }
        commitDraftRules(removingInvalidRows: true)
    }

    private func commitDraftRules(removingInvalidRows: Bool = false) {
        let validRules = IgnoreRulesDraft.normalized(draftRules)
        guard removingInvalidRows || validRules.count == draftRules.count else { return }
        if removingInvalidRows, validRules != draftRules {
            draftRules = validRules
        }
        guard settings.ignoreRules != validRules else { return }
        settings.ignoreRules = validRules
    }

    private func isValid(_ rule: IgnoreRule) -> Bool {
        !rule.pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func label(for scope: IgnoreRuleScope) -> String {
        switch scope {
        case .files: return "Files"
        case .directories: return "Folders"
        case .all: return "All"
        }
    }
}
