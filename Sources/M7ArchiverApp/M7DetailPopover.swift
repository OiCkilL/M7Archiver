import SwiftUI

enum M7DetailType {
    case error
    case warning
    case info
    
    var color: Color {
        switch self {
        case .error: return .red
        case .warning: return .orange
        case .info: return .blue
        }
    }
    
    var icon: String {
        switch self {
        case .error: return "exclamationmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        }
    }
}

struct M7DetailPopover: View {
    let title: String
    let type: M7DetailType
    let details: [String]
    var onCopy: (() -> Void)? = nil
    var onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: type.icon)
                    .font(.title2)
                    .foregroundStyle(type.color)
                Text(title)
                    .font(.headline)
            }
            
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(details, id: \.self) { line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            .padding(.vertical, 2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Divider()
                    }
                }
            }
            .frame(maxHeight: 220)
            .background(Color.primary.opacity(0.03))
            .cornerRadius(6)
            
            HStack {
                if let onCopy = onCopy {
                    Button(action: onCopy) {
                        Label("Copy Details", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
                
                Spacer()
                
                Button("Done") {
                    onDismiss()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }
            .padding(.top, 4)
        }
        .padding()
        .frame(width: 340)
    }
}
