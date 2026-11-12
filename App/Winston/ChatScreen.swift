import SwiftUI
import TelegramLink

/// The one chat screen: a picker for the bot chats, the message list, and the bottom bar.
struct ChatScreen: View {
    @Environment(AppModel.self) private var model
    @AppStorage(StorageKey.selectedChatID) private var storedChatID = 0
    @State private var draft = ""
    @State private var showingSettings = false

    var body: some View {
        NavigationStack {
            content
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        chatPicker
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button("Settings", systemImage: "gear") {
                            showingSettings = true
                        }
                    }
                }
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        .alert("Winston", isPresented: showingError) {
            Button("OK") {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .onChange(of: storedChatID, initial: true) {
            model.selectedChatID = ChatID(Int64(storedChatID))
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
            ContentUnavailableView(
                "No Bot Chats",
                systemImage: "bubble.left.and.bubble.right",
                description: Text("Start a chat with your bots in Telegram, then reopen Winston.")
            )
        } else {
            ProgressView()
        }
    }

    private var chatPicker: some View {
        Picker("Bot", selection: selectedChat) {
            ForEach(model.chats) { chat in
                Text(chat.title).tag(Optional(chat.id))
            }
        }
        .pickerStyle(.segmented)
        .fixedSize()
    }

    /// Shows the chat in use and remembers the user's choice in `@AppStorage`.
    private var selectedChat: Binding<ChatID?> {
        Binding {
            model.currentChat?.id
        } set: { id in
            if let id { storedChatID = Int(id.rawValue) }
        }
    }

    private var showingError: Binding<Bool> {
        Binding {
            model.errorMessage != nil
        } set: { isShowing in
            if !isShowing { model.errorMessage = nil }
        }
    }
}
