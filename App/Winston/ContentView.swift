import SwiftUI
import TelegramLink

/// The root view: missing credentials, login, or the chat screen.
struct ContentView: View {
    @Environment(AppModel.self) private var model

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
