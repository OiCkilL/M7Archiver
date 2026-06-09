import SwiftUI
import ArchiveCore

struct FiltersSettingsView: View {
    @Bindable var settings: ArchiveSettings

    var body: some View {
        Form {
            IgnoreRulesSettingsSection(settings: settings)
        }
        .formStyle(.grouped)
    }
}
