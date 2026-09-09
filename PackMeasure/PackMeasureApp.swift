import SwiftUI

@main
struct PackMeasureApp: App {
    @State private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environment(appModel)
                .preferredColorScheme(.dark)
                .tint(MeasureStyle.accent)
                .task {
                    appModel.loadIfNeeded()
                }
        }
    }
}
