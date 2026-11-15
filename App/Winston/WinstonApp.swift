import SwiftUI
import WinstonCore
import WinstonLogging

@main
struct WinstonApp: App {
    private static let log = Logger(label: "app.lifecycle")

    /// Lives as long as the app, which keeps its TelegramLink alive.
    @State private var model: AppModel
    /// The app's scenes taken together: logged as it changes, so the log shows when the app went
    /// to the background, where iOS may suspend or kill it.
    @Environment(\.scenePhase) private var scenePhase
    #if os(macOS)
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    #else
    @UIApplicationDelegateAdaptor private var appDelegate: AppDelegate
    #endif

    init() {
        // First, before anything creates a Logger: a swift-log Logger binds to its handler when
        // it's created. The model is made here, after bootstrap, rather than in its property's
        // initializer, which would run before this.
        WinstonLog.bootstrap()
        Self.logLaunch()
        _model = State(initialValue: AppModel())
    }

    private static func logLaunch() {
        let bundle = Bundle.main
        let process = ProcessInfo.processInfo
        log.notice("app started", [
            "version": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            "build": bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            "bundleID": bundle.bundleIdentifier ?? "unknown",
            "pid": process.processIdentifier,
            "osVersion": process.operatingSystemVersionString,
        ])
    }

    private static func logScenePhase(_ phase: ScenePhase) {
        let name = switch phase {
        case .active: "active"
        case .inactive: "inactive"
        case .background: "background"
        @unknown default: "unknown"
        }
        log.notice("scene phase changed", ["phase": name])
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .onAppear { appDelegate.model = model }
        }
        .onChange(of: scenePhase) { _, phase in
            Self.logScenePhase(phase)
        }
        .commands {
            // One window: a second one would share the same model and Telegram session.
            CommandGroup(replacing: .newItem) {}
            #if os(macOS)
            CommandGroup(after: .help) {
                Divider()
                Button("Open Log Folder") {
                    DebugLogs.openLogFolder()
                }
                Button("Export Debug Logs…") {
                    Task { await DebugLogs.export() }
                }
            }
            #endif
        }
        #if os(macOS)
        // The standard Settings window, opened with Cmd-, or Winston > Settings…
        Settings {
            SettingsView()
                .environment(model)
        }
        #endif
    }
}

// Closes the Telegram session before the app terminates, then ends the process with
// _exit. TDLibKit's receive thread is still inside td_receive, and exit()'s C++ static
// destructors would tear TDLib down under it (EXC_BAD_ACCESS). The session is closed and
// saved by then, so the process ends without running them. The log file is flushed first:
// FellerBuncher writes on its own queue, and _exit would drop what's still queued.

#if os(macOS)
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        Task {
            await model.closeForQuit()
            await WinstonLog.flush()
            _exit(0)
        }
        return .terminateLater
    }
}
#else
/// iOS only calls this when the app is running at termination, for example when it's swiped
/// away while voice mode keeps it alive in the background. A suspended app is killed without it.
final class AppDelegate: NSObject, UIApplicationDelegate {
    private static let log = Logger(label: "app.lifecycle")

    var model: AppModel?

    /// UIKit's delegate form of `didReceiveMemoryWarningNotification`. Logged with the memory left,
    /// since iOS may kill the app next, as it can while a Kokoro model loads.
    func applicationDidReceiveMemoryWarning(_ application: UIApplication) {
        var metadata: [String: CustomStringConvertible] = [:]
        if let megabytes = AvailableMemory.megabytes {
            metadata["availableMB"] = megabytes
        }
        Self.log.warning("memory warning", metadata)
    }

    func applicationWillTerminate(_ application: UIApplication) {
        guard let model else { return }
        model.closeForQuitBlocking()
        WinstonLog.flushBlocking()
        _exit(0)
    }
}
#endif
