import SwiftUI

struct SettingsView: View {
    var body: some View {
        NavigationStack {
            List {
                Section("General") {
                    row(.settings, "Editor preferences")
                    row(.volume, "Sound & haptics")
                    row(.export, "Export defaults")
                }
                Section("About") {
                    LabeledContent("Version", value: "0.10.0 (Unit 10)")
                    LabeledContent("Offline", value: "100% on-device")
                }
            }
            .scrollContentBackground(.hidden)
            .background(CSTheme.bg)
            .navigationTitle("Settings")
        }
    }

    private func row(_ icon: CSIcon, _ title: String) -> some View {
        Label {
            Text(title).font(CSType.body)
        } icon: {
            icon.symbol.foregroundStyle(CSTheme.accent)
        }
    }
}
