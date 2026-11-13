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
        .commands {
            // One window: a second one would share the same model and Telegram session.
            CommandGroup(replacing: .newItem) {}
        }
    }
}
