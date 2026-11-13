import SwiftUI

@main
struct WinstonApp: App {
    /// Lives as long as the app, which keeps its TelegramLink alive.
    @State private var model = AppModel()
    #if os(macOS)
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    #else
    @UIApplicationDelegateAdaptor private var appDelegate: AppDelegate
    #endif

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .onAppear { appDelegate.model = model }
        }
        .commands {
            // One window: a second one would share the same model and Telegram session.
            CommandGroup(replacing: .newItem) {}
        }
    }
}

// Closes the Telegram session before the app terminates, then ends the process with
// _exit. TDLibKit's receive thread is still inside td_receive, and exit()'s C++ static
// destructors would tear TDLib down under it (EXC_BAD_ACCESS). The session is closed and
// saved by then, so the process ends without running them.

#if os(macOS)
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        Task {
            await model.closeForQuit()
            _exit(0)
        }
        return .terminateLater
    }
}
#else
/// iOS only calls this when the app is running at termination, for example when it's swiped
/// away while voice mode keeps it alive in the background. A suspended app is killed without it.
final class AppDelegate: NSObject, UIApplicationDelegate {
    var model: AppModel?

    func applicationWillTerminate(_ application: UIApplication) {
        guard let model else { return }
        model.closeForQuitBlocking()
        _exit(0)
    }
}
#endif
