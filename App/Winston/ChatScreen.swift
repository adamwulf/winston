import SwiftUI
import TelegramLink
import WinstonCore
import WinstonLogging

/// The one chat screen: a picker for the bot chats, the message list, and the bottom bar.
struct ChatScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(Presentations.self) private var presentations
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
        // A file Adam opened, so its agent sheet can show.
        .onChange(of: model.openedFileCount) {
            showingSettings = false
        }
        .onChange(of: showingSettings, initial: true) {
            presentations.isShowingSettings = showingSettings
        }
        #endif
        .onChange(of: model.errorMessage != nil, initial: true) { _, isShowing in
            presentations.isShowingAlert = isShowing
        }
        // As after a logout from settings: nothing of this screen shows now.
        .onDisappear {
            presentations.isShowingSettings = false
            presentations.isShowingAlert = false
        }
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
                #if os(iOS)
                // So the app switcher shows the bar above the keyboard.
                .modifier(HoldsBottomInsetWhileInactive())
                #endif
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

#if os(iOS)
/// Keeps the bottom inset (the keyboard's space) the chat had while the app was active, so the app
/// switcher shows the bottom bar where it was, until the app is active again with the system's inset
/// back to the held one, or a second after it is active if that doesn't happen. In the simulator, on
/// the way to the background, UIKit reported the keyboard at another height just before the
/// snapshot, which moved the bar; on an iPhone the bar showed hidden behind the keyboard, most
/// likely for the same reason. See `BottomInsetHold`.
private struct HoldsBottomInsetWhileInactive: ViewModifier {
    private static let log = Logger(label: "app.layout")
    /// How long to wait, once active, for the keyboard to come back before letting go anyway, in
    /// case it doesn't.
    private static let keyboardReturnTimeout = Duration.seconds(1)

    @Environment(\.scenePhase) private var scenePhase
    @State private var hold = BottomInsetHold()

    func body(content: Content) -> some View {
        content
            // While held, the system's bottom inset is ignored and the held one put in its place.
            .safeAreaPadding(.bottom, hold.heldInset ?? 0)
            .ignoresSafeArea(edges: hold.heldInset == nil ? [] : .bottom)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.safeAreaInsets.bottom
            } action: { inset in
                hold.measured(inset)
            }
            .onChange(of: scenePhase, initial: true) {
                // Whether the keyboard was already back as the app became active.
                if scenePhase == .active, let held = hold.heldInset {
                    Self.log.info("active with the bottom inset held", ["held": inset(held), "now": inset(hold.latestInset)])
                }
                hold.sceneIsActive(scenePhase == .active)
            }
            .task(id: hold.isWaitingToLetGo) {
                guard hold.isWaitingToLetGo else { return }
                do {
                    try await Task.sleep(for: Self.keyboardReturnTimeout)
                } catch {
                    return
                }
                Self.log.info("bottom inset not back in time", ["held": inset(hold.heldInset), "now": inset(hold.latestInset)])
                hold.letGo()
            }
            // With the lifecycle log's scene phases, these show when the keyboard came back.
            .onChange(of: hold.heldInset) { old, new in
                if let new {
                    Self.log.info("bottom inset held", ["inset": inset(new)])
                } else {
                    Self.log.info("bottom inset let go", ["held": inset(old), "now": inset(hold.latestInset)])
                }
            }
    }

    /// An inset for the log, to the tenth of a point.
    private func inset(_ inset: CGFloat?) -> String {
        inset.map { Double($0).formatted(.number.precision(.fractionLength(1))) } ?? "none"
    }
}
#endif
