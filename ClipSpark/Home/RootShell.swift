import SwiftUI

/// Root navigation shell — 3 tabs per spec: Home, Templates, Settings.
struct RootShell: View {
    @StateObject private var app = AppState()

    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("Home", systemImage: CSIcon.home.rawValue) }
            TemplatesView()
                .tabItem { Label("Templates", systemImage: CSIcon.templates.rawValue) }
            SettingsView()
                .tabItem { Label("Settings", systemImage: CSIcon.settings.rawValue) }
        }
        .tint(CSTheme.accent)
        .preferredColorScheme(.dark)
        .background(CSTheme.bg.ignoresSafeArea())
        .environmentObject(app)
    }
}
