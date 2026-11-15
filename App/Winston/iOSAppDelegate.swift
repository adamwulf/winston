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

    func applicationDidBecomeActive(_ application: UIApplication) {
        guard let model else { return }
        Task { await model.notificationAccess.refresh() }
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
        if let target, target.chatID == model?.currentChat?.id { return [] }
        return [.banner, .list, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let target = TelegramNotification(userInfo: response.notification.request.content.userInfo) else { return }
        if let model {
            model.openNotification(target)
        } else {
            pendingNotification = target
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
