#if os(iOS)
import Logging
import LogSupport
import Observation
import UIKit
import UserNotifications

/// The iOS permission and APNs calls, separate from Telegram's device registration.
@MainActor
@Observable
public final class NotificationAccess {
    public private(set) var authorization: UNAuthorizationStatus = .notDetermined
    public private(set) var errorMessage: String?
    public private(set) var isRequesting = false
    private static let log = Logger(label: "app.notifications")

    public init() {}

    /// Refresh on activation, since permission can change in Settings while we're suspended.
    /// Never prompts here. Apple should be asked for the current token on every launch.
    public func refresh() async {
        authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        if authorization == .authorized || authorization == .provisional || authorization == .ephemeral {
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    public func requestPermission() async {
        guard !isRequesting else { return }
        isRequesting = true
        defer { isRequesting = false }
        errorMessage = nil
        do {
            _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            await refresh()
        } catch {
            Self.log.error("notification permission request failed", error.logCodes())
            errorMessage = "Couldn't enable notifications. Please try again."
        }
    }
}
#endif
