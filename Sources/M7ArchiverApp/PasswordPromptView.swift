import SwiftUI

/// Lightweight prompt used when `ArchivePasswordProvider` requests a password
/// mid-operation (for example, during extract). The unlock flow on the locked
/// archive itself uses `ArchiveLockView`; this prompt is for transient asks.
struct PasswordPromptView: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    let message: String

    var onSubmit: ((String) -> Void)?

    @State private var password: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(title, systemImage: "lock")
                .font(.title3.weight(.semibold))

            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .onSubmit { submit() }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Continue") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(password.isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 360, idealWidth: 400)
    }

    private func submit() {
        guard !password.isEmpty else { return }
        let entered = password
        password = ""
        onSubmit?(entered)
        dismiss()
    }
}
