import SwiftUI

@main
struct WinstonApp: App {
    /// Lives as long as the app, which keeps its TelegramLink alive.
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
        }
    }
}
