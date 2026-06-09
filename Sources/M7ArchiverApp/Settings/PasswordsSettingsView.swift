import SwiftUI
import AppKit

struct PasswordsSettingsView: View {
    @Bindable var store: SavedPasswordsStore
    @State private var selection: SavedPasswordEntry.ID?
    @State private var showClearConfirmation = false
    @State private var pendingRemoval: SavedPasswordEntry?

    var body: some View {
        SettingsPane(minWidth: 620, idealWidth: 720, maxWidth: 760) {
            SettingsGroup("Saved Passwords") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Passwords entered to unlock encrypted archives are stored in Keychain. Settings only lists saved records so you can remove them.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(store.entries.count) saved")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if store.entries.isEmpty {
                        ContentUnavailableView(
                            "No saved passwords in Keychain",
                            systemImage: "key.slash",
                            description: Text("Encrypted archives will ask for a password when opened.")
                        )
                        .frame(maxWidth: .infinity, minHeight: 300)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 1)
                        )
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(Array(store.entries.enumerated()), id: \.element.id) { index, entry in
                                    savedPasswordRow(entry: entry, index: index)
                                }
                            }
                        }
                        .frame(height: 300)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 1)
                        )
                    }
                }

                HStack {
                    Button("Clear All…", role: .destructive) {
                        showClearConfirmation = true
                    }
                    .disabled(store.entries.isEmpty)

                    Spacer()

                    Button("Remove Selection…", role: .destructive) {
                        if let entry = selectedEntry {
                            pendingRemoval = entry
                        }
                    }
                    .disabled(selectedEntry == nil)
                }
            }
        }
        .confirmationDialog(
            "Forget all saved passwords?",
            isPresented: $showClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Forget All", role: .destructive) {
                store.clearAll()
                selection = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Encrypted archives will prompt for the password again the next time you open them.")
        }
        .confirmationDialog(
            "Forget saved password?",
            isPresented: removeConfirmationBinding,
            titleVisibility: .visible
        ) {
            Button("Forget Password", role: .destructive) {
                if let pendingRemoval {
                    store.delete(pendingRemoval)
                }
                pendingRemoval = nil
                selection = nil
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: {
            if let pendingRemoval {
                Text("\((pendingRemoval.path as NSString).lastPathComponent) will ask for a password the next time it is opened.")
            }
        }
        .onAppear { store.refresh() }
        .onChange(of: store.entries) { _, _ in
            guard let selection else { return }
            if !store.entries.contains(where: { $0.id == selection }) {
                self.selection = nil
            }
        }
    }

    private var selectedEntry: SavedPasswordEntry? {
        guard let selection else { return nil }
        return store.entries.first { $0.id == selection }
    }

    private func savedPasswordRow(entry: SavedPasswordEntry, index: Int) -> some View {
        Button {
            selection = entry.id
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text((entry.path as NSString).lastPathComponent)
                        .font(.body)
                        .foregroundStyle(.primary)
                    Text(entry.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                Text(entry.savedAt, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(rowBackground(for: entry, index: index))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Saved password for \((entry.path as NSString).lastPathComponent)")
        .accessibilityValue(accessibilityValue(for: entry))
        .accessibilityAddTraits(selection == entry.id ? .isSelected : [])
    }

    private func accessibilityValue(for entry: SavedPasswordEntry) -> String {
        let savedAt = entry.savedAt.formatted(.relative(presentation: .named))
        return selection == entry.id ? "Selected, \(savedAt)" : savedAt
    }

    private func rowBackground(for entry: SavedPasswordEntry, index: Int) -> Color {
        if selection == entry.id {
            Color.accentColor.opacity(0.18)
        } else if index % 2 == 1 {
            Color.secondary.opacity(0.05)
        } else {
            Color.clear
        }
    }

    private var removeConfirmationBinding: Binding<Bool> {
        Binding(
            get: { pendingRemoval != nil },
            set: { isPresented in
                if !isPresented { pendingRemoval = nil }
            }
        )
    }
}
