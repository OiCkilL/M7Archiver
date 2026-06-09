import SwiftUI

struct AboutSettingsView: View {
    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 80, height: 80)

            VStack(spacing: 8) {
                Text("M7Archiver")
                    .font(.title.weight(.bold))

                Text("Version \(versionString) (\(buildString))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Text("A professional, native archive manager for macOS.\nBuilt with ArchiveCore engine.")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 40)

            Divider()
                .frame(width: 200)

            VStack(spacing: 4) {
                Text("\u{00A9} 2026 M7 Software")
                Text("All rights reserved.")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var versionString: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }

    private var buildString: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }
}
