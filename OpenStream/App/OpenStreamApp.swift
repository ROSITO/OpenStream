import SwiftUI

@main
struct OpenStreamApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .frame(minWidth: 960, minHeight: 640)
                .onAppear { appState.startServices() }
        }
        .defaultSize(width: 1180, height: 760)

        Settings {
            SettingsView(settings: appState.settings) {
                appState.applySettings()
            }
            .environment(appState)
        }
    }
}
