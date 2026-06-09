import SwiftUI

/// Placeholder for the deferred Settings scene.
///
/// The full Settings UI (General/Compression/Passwords/Filters/About with
/// Auto-encoding priority list and Auto Extract destination) is planned in
/// later TASK-010 subtasks. For now we render a small placeholder so the
/// menu item still works.
struct SettingsPlaceholderView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "gearshape")
                .imageScale(.large)
                .foregroundStyle(.secondary)
            Text("Settings")
                .font(.title2.weight(.semibold))
            Text("Encoding, compression, password, and filter preferences are coming next.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(width: 420, height: 220)
    }
}
