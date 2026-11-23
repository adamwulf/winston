#if os(macOS)
import AppKit
#endif
import SwiftUI
import TelegramLink
import WinstonCore

/// The root view: missing credentials, login, or the chat screen, and the sheet for files opened
/// in Winston from another app.
struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var presentations = Presentations()
    #if os(macOS)
    @State private var window = WindowReference()
    #endif

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
        // iOS share sheet, or with Open With or a drop on the Dock icon on the Mac. Or the URL
        // the iOS share extension opens Winston with, in the scheme Info.plist registers.
        .onOpenURL { url in
            model.open(url)
            #if os(macOS)
            // In front of Settings, its own window on the Mac, say, so the agent sheet is seen.
            window.window?.makeKeyAndOrderFront(nil)
            #endif
        }
        #if os(macOS)
        .background {
            WindowReader(reference: window)
        }
        #endif
        // This window takes it. Otherwise the Mac opens a new window for each file, sharing the
        // one model.
        .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        .sheet(isPresented: isPickingAgent) {
            OpenedFileSheet()
                // A document still downloading would open Quick Look, closing this mid-pick.
                .onAppear { presentations.dropPendingPreview() }
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

#if os(macOS)
/// The chat window, once ContentView is in one. Weak: the window holds the view, not the other
/// way round.
final class WindowReference {
    weak var window: NSWindow?
}

/// Puts the window it is shown in into `reference`.
private struct WindowReader: NSViewRepresentable {
    let reference: WindowReference

    func makeNSView(context: Context) -> NSView {
        let view = WindowView()
        view.reference = reference
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class WindowView: NSView {
        var reference: WindowReference?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            reference?.window = window
        }
    }
}
#endif

struct MissingCredentialsView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Telegram Credentials Missing", systemImage: "key")
        } description: {
            Text("Copy App/Config/Secrets.example.xcconfig to App/Config/Secrets.xcconfig, fill in TG_API_ID and TG_API_HASH from my.telegram.org, then rebuild.")
        }
    }
}
