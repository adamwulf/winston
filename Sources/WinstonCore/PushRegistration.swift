import Foundation
import Logging
import LogSupport
import Observation
import TelegramLink

/// Joins APNs registration and Telegram login, which can finish in either order.
/// Tokens are requested from Apple on each launch, never restored from preferences.
@MainActor
@Observable
public final class PushRegistration {
    public enum Status: Equatable {
        case notRegistered, waitingForLogin, registering, registered, failed
    }

    public private(set) var status: Status = .notRegistered
    private static let log = Logger(label: "app.push")
    private let link: TelegramLink?
    private var token: String?
    private var isSandbox = false
    private var isAuthorized = false
    private var revision = 0
    private var isRegistering = false

    package init(link: TelegramLink?) {
        self.link = link
    }

    /// Called on every successful APNs registration, including token rotation and relaunch.
    public func receivedDeviceToken(_ data: Data, isSandbox: Bool) {
        guard !data.isEmpty else { return }
        token = data.map { String(format: "%02x", $0) }.joined()
        self.isSandbox = isSandbox
        revision += 1
        registerIfReady()
    }

    public func registrationFailed() {
        token = nil
        revision += 1
        status = .failed
    }

    package func setAuthorized(_ authorized: Bool) {
        guard isAuthorized != authorized else { return }
        isAuthorized = authorized
        revision += 1
        if token != nil {
            status = .waitingForLogin
        } else if status != .failed {
            // An APNs failure can arrive before Telegram finishes login. Keep its Retry
            // state until Apple supplies a token, rather than showing Connecting forever.
            status = .notRegistered
        }
        registerIfReady()
    }

    private func registerIfReady() {
        guard token != nil else { return }
        guard isAuthorized, let link else {
            status = .waitingForLogin
            return
        }
        guard !isRegistering else { return }
        isRegistering = true
        Task {
            defer { isRegistering = false }
            // Serialize registrations: an old token's slower response must not overwrite a
            // newer token. A login or token change during the request is applied next.
            while isAuthorized, let token {
                let registeringRevision = revision
                status = .registering
                do {
                    try await link.registerForPushNotifications(token: token, isSandbox: isSandbox)
                    if revision == registeringRevision {
                        status = .registered
                        Self.log.notice("push device registered")
                    }
                } catch {
                    // TDLib errors can contain the token. Log codes only, never the payload.
                    Self.log.error("push registration failed", error.tdlibLogCodes())
                    if revision == registeringRevision { status = .failed }
                }
                guard revision != registeringRevision else { return }
            }
        }
    }
}
