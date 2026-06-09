import SwiftUI

enum InspectorTab: String, CaseIterable {
    case info
    case comment

    var icon: String {
        switch self {
        case .info: return "info.circle"
        case .comment: return "quote.bubble"
        }
    }

    var label: String {
        switch self {
        case .info: return "Info"
        case .comment: return "Comment"
        }
    }
}

struct InspectorTabControl: View {
    @Binding var selection: InspectorTab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(InspectorTab.allCases, id: \.self) { tab in
                Button {
                    selection = tab
                } label: {
                    ZStack {
                        Rectangle()
                            .fill(Color.clear)
                        Image(systemName: tab.icon)
                            .font(.system(size: 13))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 22)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .background(
                    selection == tab
                        ? Color.accentColor
                        : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6)
                )
                .foregroundStyle(selection == tab ? Color.white : Color.secondary)
                .contentShape(Rectangle())
                .accessibilityLabel(tab.label)
                .accessibilityAddTraits(selection == tab ? .isSelected : [])
            }
        }
        .frame(maxWidth: .infinity)
        .padding(2)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
    }
}
