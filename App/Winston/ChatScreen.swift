import SwiftUI
import TelegramLink
import WinstonCore

/// The one chat screen: a picker for the bot chats, the message list, and the bottom bar.
struct ChatScreen: View {
    @Environment(AppModel.self) private var model
    @State private var draft = ""
    #if os(iOS)
    @State private var showingSettings = false
    #endif

    var body: some View {
        NavigationStack {
            content
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        chatPicker
                    }
                    #if os(iOS)
                    // On the Mac, settings live in the standard Settings window (Cmd-,).
                    ToolbarItem(placement: .primaryAction) {
                        Button("Settings", systemImage: "gear") {
                            showingSettings = true
                        }
                    }
                    #endif
                }
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
        }
        #if os(iOS)
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        #endif
        .alert("Winston", isPresented: showingError) {
            Button("OK") {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    @ViewBuilder
    private var content: some View {
        if !model.chats.isEmpty {
            MessageList()
                .safeAreaInset(edge: .bottom) {
                    BottomBar(draft: $draft)
                }
        } else if let error = model.chatsError {
            ContentUnavailableView {
                Label("Couldn't Load Chats", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Try Again") {
                    Task { await model.loadChats() }
                }
            }
        } else if model.chatsLoaded {
            ContentUnavailableView {
                Label("No Bot Chats", systemImage: "bubble.left.and.bubble.right")
            } description: {
                Text("Start a chat with your bots in Telegram, then reload.")
            } actions: {
                Button("Reload") {
                    Task { await model.loadChats() }
                }
            }
        } else {
            ProgressView()
        }
    }

    @ViewBuilder
    private var chatPicker: some View {
        @Bindable var model = model
        Picker("Bot", selection: $model.selectedChatID) {
            ForEach(model.chats) { chat in
                Text(chat.title).tag(Optional(chat.id))
            }
        }
        .pickerStyle(.segmented)
        .fixedSize()
    }

    private var showingError: Binding<Bool> {
        Binding {
            model.errorMessage != nil
        } set: { isShowing in
            if !isShowing { model.errorMessage = nil }
        }
    }
}
