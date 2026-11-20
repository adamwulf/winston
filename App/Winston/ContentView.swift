import SwiftUI
import TelegramLink
import WinstonCore

/// The root view: missing credentials, login, or the chat screen, and the sheet for files opened
/// in Winston from another app.
struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var presentations = Presentations()

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
        .environment(presentations)
        .onAppear { model.start() }
        // A file another app opened in Winston, as Info.plist's document types offer it: from the
        // iOS share sheet, or with Open With or a drop on the Dock icon on the Mac. The only URLs
        // Winston is handed: it has no URL scheme.
        .onOpenURL { url in
            model.openFile(at: url)
        }
        // This window takes it. Otherwise the Mac opens a new window for each file, sharing the
        // one model.
        .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        .sheet(isPresented: isPickingAgent) {
            OpenedFileSheet()
        }
    }

    /// Shows once Winston is logged in with its bot chats, and nothing else is showing: a file
    /// Adam opens closes settings and the pickers (`AppModel.openedFileCount`), but a failed upload
    /// waits, and so does everything for push-to-talk, which could be in a hold. Only the model
    /// closes it, once the files are sent or cancelled: the sheet can't be swiped away.
    private var isPickingAgent: Binding<Bool> {
        Binding {
            model.isPickingAgentForOpenedFiles && !presentations.isShowingAny
        } set: { _ in
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
