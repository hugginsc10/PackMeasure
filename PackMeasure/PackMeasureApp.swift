import SwiftUI

@main
struct PackMeasureApp: App {
    @State private var appModel = AppModel()
    @State private var preferences = AppPreferences()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environment(appModel)
                .environment(preferences)
                .preferredColorScheme(preferences.appearance.colorScheme)
                .tint(MeasureStyle.accent)
                .task {
                    appModel.loadIfNeeded()
                }
        }
    }
}
