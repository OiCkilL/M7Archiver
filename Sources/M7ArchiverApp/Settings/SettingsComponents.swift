import SwiftUI

struct SettingsPane<Content: View>: View {
    let minWidth: CGFloat
    let idealWidth: CGFloat
    let maxWidth: CGFloat
    @ViewBuilder var content: () -> Content

    init(
        minWidth: CGFloat = 620,
        idealWidth: CGFloat = 720,
        maxWidth: CGFloat = 760,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.minWidth = minWidth
        self.idealWidth = idealWidth
        self.maxWidth = maxWidth
        self.content = content
    }

    var body: some View {
        Form {
            content()
        }
        .formStyle(.grouped)
        .frame(minWidth: minWidth, idealWidth: idealWidth, maxWidth: maxWidth)
    }
}

struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        Section(header: Text(title)) {
            content()
        }
    }
}
