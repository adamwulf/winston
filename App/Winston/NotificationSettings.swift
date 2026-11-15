#if os(iOS)
import SwiftUI
import UserNotifications
import WinstonCore

struct NotificationSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section {
            switch model.notificationAccess.authorization {
            case .notDetermined:
                Button("Enable Notifications") {
                    Task { await model.notificationAccess.requestPermission() }
                }
                .disabled(model.notificationAccess.isRequesting)
            case .denied:
                Text("Notifications are off")
                settingsButton
            default:
                LabeledContent("Notifications", value: registrationStatus)
                if model.pushRegistration.status == .failed {
                    Button("Retry") {
                        Task { await model.notificationAccess.refresh() }
                    }
                }
                settingsButton
            }
            if let error = model.notificationAccess.errorMessage {
                Text(error).foregroundStyle(.red)
            }
        } header: {
            Text("Notifications")
        } footer: {
            Text("Receive Telegram alerts when Winston is in the background. Uses your Telegram notification settings, including chats outside Winston. Voice replies continue only during an active voice session.")
        }
        .task { await model.notificationAccess.refresh() }
    }

    private var settingsButton: some View {
        Button("Open Notification Settings") {
            guard let url = URL(string: UIApplication.openNotificationSettingsURLString) else { return }
            UIApplication.shared.open(url)
        }
    }

    private var registrationStatus: String {
        switch model.pushRegistration.status {
        case .notRegistered: "Connecting…"
        case .waitingForLogin: "Waiting for Telegram login"
        case .registering: "Connecting…"
        case .registered: "Enabled"
        case .failed: "Couldn't connect"
        }
    }
}
#endif
