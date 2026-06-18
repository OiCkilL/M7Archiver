import SwiftUI
import ArchiveCore

/// Compact progress view shown in the standalone Compress Archive window while
/// a compression is running.  Observes the owning `ArchiveWindowModel`:
/// displays a determinate bar when the engine reports a fraction (7-Zip) and an
/// indeterminate bar otherwise (ZIP / before the first percentage arrives).
/// The presenter dismisses the window when `createArchiveFromNewPanel` returns.
struct CompressProgressView: View {
    @Bindable var model: ArchiveWindowModel

    var body: some View {
        VStack(spacing: 14) {
            if let progress = model.session.progress, model.isCompressing {
                Text(progress.message)
                    .font(.callout)
                    .lineLimit(1)
                if let fraction = progress.fraction {
                    ProgressView(value: max(0, min(1, fraction)))
                        .progressViewStyle(.linear)
                        .frame(minWidth: 240)
                    Text("\(Int((fraction * 100).rounded()))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .controlSize(.regular)
                        .frame(minWidth: 240)
                }
            } else {
                ProgressView()
                    .controlSize(.large)
                Text("Preparing…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(28)
        .frame(minWidth: 300, minHeight: 140)
    }
}
