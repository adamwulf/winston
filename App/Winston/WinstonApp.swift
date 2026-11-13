import SwiftUI

@main
struct WinstonApp: App {
    /// Lives as long as the app, which keeps its TelegramLink alive.
    @State private var model = AppModel()
    #if os(macOS)
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    #endif

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                #if os(macOS)
                .onAppear { appDelegate.model = model }
                #endif
        }
        .commands {
            // One window: a second one would share the same model and Telegram session.
            CommandGroup(replacing: .newItem) {}
        }
    }
}

#if os(macOS)
/// Closes the Telegram session before quitting. iOS doesn't need this: it ends a suspended
/// app without running exit-time cleanup.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        Task {
            await model.closeForQuit()
            // TDLibKit's receive thread is still inside td_receive, and exit()'s C++ static
            // destructors would tear TDLib down under it (EXC_BAD_ACCESS on quit). The session
            // is closed and saved, so end the process without running them.
            _exit(0)
        }
        return .terminateLater
    }
}
#endif
