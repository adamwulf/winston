import SwiftUI
import TelegramLink
import WinstonCore

/// The one chat screen: a picker for the bot chats, the message list, and the bottom bar.
struct ChatScreen: View {
    @Environment(AppModel.self) private var model
    @State private var draft = ""
    #if os(iOS)
    @State private var showingSettings = false
    #else
    @State private var isDropTargeted = false
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
        .onChange(of: model.notificationOpenCount) {
            showingSettings = false
        }
        // So the agent sheet for the file can show.
        .onChange(of: model.openedFileCount) {
            showingSettings = false
        }
        #endif
        .safeAreaInset(edge: .top) {
            if let error = model.notificationErrorMessage {
                HStack(alignment: .top) {
                    Label(error, systemImage: "exclamationmark.circle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Dismiss", systemImage: "xmark") {
                        model.notificationErrorMessage = nil
                    }
                    .labelStyle(.iconOnly)
                }
                .font(.callout)
                .padding()
                .background(.regularMaterial)
            }
        }
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
                #if os(macOS)
                // Files dropped from Finder anywhere on the chat are sent straight away, as from the
                // + button. Each arrives as its URL, which keeps the file's name and, like the file
                // picker's, gives access to it until the copy is made. Mac only: drags from the iOS
                // Files app carry the file's contents, not its URL. (A folder or a web link arrives as
                // a URL too, and sendDocuments says why it can't send it.)
                .dropDestination(for: URL.self, isEnabled: !model.isSendingAttachment) { fileURLs, _ in
                    sendDropped(fileURLs)
                }
                .onDropSessionUpdated { session in
                    isDropTargeted = session.phase == .entering || session.phase == .active
                }
                .overlay {
                    if isDropTargeted {
                        dropHighlight
                    }
                }
                #endif
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

    #if os(macOS)
    /// Sends dropped files with what's typed as the first one's caption, as the + button does. In voice
    /// mode the text field is hidden, so they go without a caption and the draft stays.
    private func sendDropped(_ fileURLs: [URL]) {
        if model.isVoiceMode {
            Task { await model.sendDocuments(caption: "", fileURLs: fileURLs) }
        } else {
            $draft.sendAsCaption { caption in
                await model.sendDocuments(caption: caption, fileURLs: fileURLs)
            }
        }
    }

    private var dropHighlight: some View {
        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(.tint, lineWidth: 3)
            .overlay {
                Label("Drop to Send", systemImage: "arrow.up.doc")
                    .font(.title3)
                    .padding()
                    .background(.regularMaterial, in: .capsule)
            }
            .padding(8)
            .allowsHitTesting(false)
    }
    #endif

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
