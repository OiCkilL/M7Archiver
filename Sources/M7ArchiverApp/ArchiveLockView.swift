import SwiftUI
import ArchiveCore

struct ArchiveLockView: View {
    @Bindable var session: ArchiveSession
    var savedPasswords: SavedPasswordsStore? = nil
    var onUnlockSuccess: @MainActor () async -> Void = {}
    @State private var password: String = ""
    @State private var isRevealed: Bool = false
    @State private var rememberPassword: Bool = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 24) {
            iconStack

            VStack(spacing: 6) {
                Text("Encrypted Archive")
                    .font(.title2.weight(.semibold))
                Text("This archive is password protected. Enter the password to view its contents.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Password")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Group {
                    if isRevealed {
                        TextField("Enter password", text: $password)
                    } else {
                        SecureField("Enter password", text: $password)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .focused($fieldFocused)
                .onSubmit { unlock() }

                statusLabel

                HStack {
                    Toggle("Show password", isOn: $isRevealed)
                        .toggleStyle(.checkbox)
                        .controlSize(.small)
                    Spacer()
                    Button("Unlock Archive") { unlock() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(password.isEmpty || isUnlocking)
                }

                if savedPasswords != nil {
                    Toggle("Remember password for this archive", isOn: $rememberPassword)
                        .toggleStyle(.checkbox)
                        .controlSize(.small)
                }
            }
            .frame(maxWidth: 320)

            Text("Saved passwords can be managed from M7Archiver → Settings → Passwords.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { fieldFocused = true }
    }

    @ViewBuilder
    private var iconStack: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: "doc.zipper")
                .resizable()
                .scaledToFit()
                .frame(width: 64, height: 64)
                .foregroundStyle(.tint)
            Image(systemName: "lock.fill")
                .imageScale(.large)
                .foregroundStyle(.yellow)
                .padding(6)
                .background(.regularMaterial, in: Circle())
                .offset(x: 6, y: 6)
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch session.lockState {
        case .locked(.wrongPassword):
            Label("Incorrect password. Try again.", systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.red)
        case .failed(message: let message, details: _):
            Label(message, systemImage: "exclamationmark.octagon.fill")
                .font(.callout)
                .foregroundStyle(.red)
        case .unlocking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Unlocking…").foregroundStyle(.secondary)
            }
            .font(.callout)
        default:
            EmptyView()
        }
    }

    private var isUnlocking: Bool {
        if case .unlocking = session.lockState { return true }
        return false
    }

    private func unlock() {
        guard !password.isEmpty else { return }
        let entered = password
        let shouldRemember = rememberPassword
        Task {
            await session.unlock(password: entered)
            guard session.lockState == .unlocked else { return }
            if shouldRemember, let store = savedPasswords, let archiveURL = session.archiveURL {
                store.save(password: entered, for: archiveURL)
            }
            password = ""
            await onUnlockSuccess()
        }
    }
}
