import SwiftUI
import TelegramLink

/// The root view: missing credentials, login, or the chat screen. Also applies the voice settings.
struct ContentView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(StorageKey.pauseThreshold) private var pauseThreshold = 1.2
    @AppStorage(StorageKey.voiceIdentifier) private var voiceIdentifier = ""

    var body: some View {
        Group {
            if !model.hasCredentials {
                MissingCredentialsView()
            } else if model.authState == .ready {
                ChatScreen()
            } else {
                LoginView()
            }
        }
        .onAppear { model.start() }
        .onChange(of: pauseThreshold, initial: true) {
            model.voiceLoop.pauseThreshold = .seconds(pauseThreshold)
        }
        .onChange(of: voiceIdentifier, initial: true) {
            model.voiceLoop.voiceIdentifier = voiceIdentifier.isEmpty ? nil : voiceIdentifier
        }
    }
}

struct MissingCredentialsView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Telegram Credentials Missing", systemImage: "key")
        } description: {
            Text("Copy App/Config/Secrets.example.xcconfig to App/Config/Secrets.xcconfig, fill in TG_API_ID and TG_API_HASH from my.telegram.org, then rebuild.")
        }
    }
}
