#if os(iOS)
import TelegramLink
import UIKit
import UserNotifications
import WinstonCore
import WinstonLogging

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    private static let log = Logger(label: "app.notifications")
    private static let lifecycleLog = Logger(label: "app.lifecycle")
    private var pendingNotification: TelegramNotification?

    var model: AppModel? {
        didSet {
            guard let model, model !== oldValue else { return }
            if let pendingNotification {
                self.pendingNotification = nil
                model.openNotification(pendingNotification)
            }
            Task { await model.notificationAccess.refresh() }
        }
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        guard let environment = Bundle.main.object(forInfoDictionaryKey: "TelegramPushEnvironment") as? String,
              environment == "development" || environment == "production" else {
            Self.log.error("push environment is missing or invalid")
            model?.pushRegistration.registrationFailed()
            return
        }
        model?.pushRegistration.receivedDeviceToken(deviceToken, isSandbox: environment == "development")
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        Self.log.error("Apple push registration failed", error.logCodes())
        model?.pushRegistration.registrationFailed()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let target = TelegramNotification(userInfo: notification.request.content.userInfo)
        // The current conversation already displays the message (and speaks it in voice mode).
        let isCurrentChat = target != nil && target?.chatID == model?.currentChat?.id
        var metadata = Self.alertMetadata(target)
        metadata["banner"] = !isCurrentChat
        Self.log.notice("alert arrived in the foreground", metadata)
        return isCurrentChat ? [] : [.banner, .list, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let target = TelegramNotification(userInfo: response.notification.request.content.userInfo)
        let action: String = switch response.actionIdentifier {
        case UNNotificationDefaultActionIdentifier: "open"
        case UNNotificationDismissActionIdentifier: "dismiss"
        default: "other"
        }
        var metadata = Self.alertMetadata(target)
        metadata["action"] = action
        // False when a tap launched the app, so iOS had ended it while it was away.
        metadata["modelReady"] = model != nil
        Self.log.notice("alert response", metadata)
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier, let target else { return }
        if let model {
            model.openNotification(target)
        } else {
            pendingNotification = target
        }
    }

    /// An alert's chat and message IDs (never its text), and the app's state when it came.
    private static func alertMetadata(_ target: TelegramNotification?) -> [String: CustomStringConvertible] {
        [
            "chatID": target?.chatID.description ?? "notPrivate",
            "messageID": target?.messageID?.description ?? "none",
            "appState": appStateName,
        ]
    }

    private static var appStateName: String {
        switch UIApplication.shared.applicationState {
        case .active: "active"
        case .inactive: "inactive"
        case .background: "background"
        @unknown default: "unknown"
        }
    }

    /// UIKit's delegate form of `didReceiveMemoryWarningNotification`. Logged with the memory left,
    /// since iOS may kill the app next, as it can while a Kokoro model loads.
    func applicationDidReceiveMemoryWarning(_ application: UIApplication) {
        var metadata: [String: CustomStringConvertible] = [:]
        if let megabytes = AvailableMemory.megabytes {
            metadata["availableMB"] = megabytes
        }
        Self.lifecycleLog.warning("memory warning", metadata)
    }

    /// Called only if iOS terminates the app while it is running, such as during voice mode.
    func applicationWillTerminate(_ application: UIApplication) {
        guard let model else { return }
        model.closeForQuitBlocking()
        WinstonLog.flushBlocking()
        _exit(0)
    }
}
#endif
