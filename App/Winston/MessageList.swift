import SwiftUI
import TelegramLink
import WinstonCore
import WinstonLogging
#if os(iOS)
import QuickLook
#else
import AppKit
#endif

/// The current chat's messages, scrolled to the newest, with a header where each day starts (see
/// `MessageDaySeparators`). Incoming messages are marked read as they appear,
/// but only while the window is active, so replies that arrive while Adam is elsewhere stay unread.
struct MessageList: View {
    @Environment(AppModel.self) private var model
    #if os(macOS)
    @Environment(\.appearsActive) private var isActive
    #else
    @Environment(\.scenePhase) private var scenePhase
    private var isActive: Bool { scenePhase == .active }
    /// Holds the document Quick Look shows, which a document row sets.
    @Environment(Presentations.self) private var presentations
    #endif
    // The user's, for the messages' times and days. They follow changes in system settings.
    @Environment(\.calendar) private var calendar
    @Environment(\.timeZone) private var timeZone
    @Environment(\.locale) private var locale
    /// What "today" is for the messages' times and the days' headers. Moves on as the day or the
    /// time zone changes, and when the window becomes active again.
    @State private var now = Date.now

    var body: some View {
        let messages = model.currentMessages
        let times = MessageTimes(now: now, calendar: calendar, timeZone: timeZone, locale: locale)
        // A header above the first message of each day.
        let days = MessageDaySeparators.compute(messages, now: now, calendar: calendar, timeZone: timeZone, locale: locale)
        #if os(iOS)
        // Each message has its own time, shown beside it while the list is pulled aside.
        let time: (ChatMessage) -> MessageTimes.Caption? = times.pulledCaption(for:)
        #else
        // Under the bubbles, where a run of messages in one minute shows it once.
        let timed = times.messagesShowingTime(in: messages)
        let time: (ChatMessage) -> MessageTimes.Caption? = { timed.contains($0.id) ? times.caption(for: $0) : nil }
        #endif
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(messages) { message in
                        // A row of its own, before the message's: scrolling to the message shows
                        // the message's row, and the message's row keeps its identity as the
                        // header comes or goes.
                        if let day = days[message.id] {
                            DaySeparator(separator: day)
                        }
                        MessageRow(message: message, time: time(message))
                            .id(message.id)
                            .onAppear {
                                if isActive { model.markRead(message) }
                            }
                    }
                }
                .padding()
                #if os(iOS)
                .modifier(SlidesForMessageTimes())
                #endif
            }
            #if os(iOS)
            // Pulling the list toward the leading edge shows the messages' times, as in Messages.
            // Inside the chat's `.id` below, so each chat starts with its own pull.
            .modifier(PullsForMessageTimes())
            #endif
            .defaultScrollAnchor(.bottom)
            // Dragging the messages down pulls the keyboard down with the finger, as in Messages.
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: model.currentMessages.last?.id) { oldID, newestID in
                guard let newestID else { return }
                // The list appears before the history loads, so going from no messages to some is usually the
                // launch load: jump straight to the newest one rather than animating down to it. (The other case,
                // the first message in an empty chat, fits on screen, so skipping the animation changes nothing.)
                // New messages added to a shown list animate.
                if oldID == nil {
                    proxy.scrollTo(newestID, anchor: .bottom)
                } else {
                    withAnimation {
                        proxy.scrollTo(newestID, anchor: .bottom)
                    }
                }
            }
            .onChange(of: model.addedThumbsUp) { _, added in
                guard let added else { return }
                // Scrolls only as far as it takes to show the whole 👍 above the bottom bar, and not at
                // all if it already shows. The reactions row, not the message: a long message can't fit.
                withAnimation {
                    proxy.scrollTo(ReactionsRow.ScrollID(messageID: added.messageID), anchor: nil)
                }
            }
            .onChange(of: isActive) {
                guard isActive else { return }
                // A day may have passed while the window was away.
                now = .now
                // Private-chat read state is a watermark, so marking the newest message covers the earlier ones.
                if let newest = model.latestIncomingMessage {
                    model.markRead(newest)
                }
            }
        }
        // Each chat gets its own scroll view, which opens at its newest message. One shared scroll
        // view kept the last chat's offset on a switch, then the newest-message change above animated
        // down from there.
        .id(model.selectedChatID)
        .task {
            // At midnight today's times become yesterday's, and "Today" becomes "Yesterday".
            for await _ in NotificationCenter.default.notifications(named: .NSCalendarDayChanged) {
                now = .now
            }
        }
        .task {
            // A new time zone can put `now`, set hours ago, on another day than today.
            for await _ in NotificationCenter.default.notifications(named: .NSSystemTimeZoneDidChange) {
                now = .now
            }
        }
        #if os(iOS)
        // Here rather than on the document's row, which can scroll away, and be unloaded, while
        // the preview shows.
        .quickLookPreview(Binding {
            presentations.previewURL
        } set: {
            presentations.previewURL = $0
        })
        .onChange(of: model.notificationOpenCount) {
            presentations.closePreview()
        }
        // A document of the chat before, still downloading, doesn't open over this one.
        .onChange(of: model.selectedChatID) {
            presentations.dropPendingPreview()
        }
        // As after a logout: the preview went with the list, and a download still under way
        // shows nothing.
        .onDisappear {
            presentations.closePreview()
        }
        #endif
    }
}

/// One message: a bubble (incoming on the left, outgoing on the right), its time, its reactions, and its
/// send state. The time shows under the bubble on the Mac, and beside it while the list is pulled aside on
/// iOS.
struct MessageRow: View {
    @Environment(AppModel.self) private var model
    let message: ChatMessage
    /// Nil for no time: see `MessageTimes.pulledCaption(for:)` (iOS) and
    /// `MessageTimes.messagesShowingTime(in:)` (Mac).
    let time: MessageTimes.Caption?

    var body: some View {
        HStack {
            if message.isOutgoing { Spacer(minLength: 48) }
            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 4) {
                bubble
                    .contentShape(.rect(cornerRadius: 16))
                    // Same 👍 toggle as the context menu, and only on sent messages like it. High priority so a
                    // double tap on a document row or the photo retry button reacts instead of tapping that
                    // button twice; a single tap there still reaches the button once the double tap fails.
                    .highPriorityGesture(TapGesture(count: 2).onEnded {
                        guard message.sendState == .sent else { return }
                        Task { await model.toggleThumbsUp(on: message) }
                    })
                    #if os(iOS)
                    .alignmentGuide(.bubbleCenter) { $0[VerticalAlignment.center] }
                    #endif
                #if os(macOS)
                // After the bubble, so VoiceOver reads it next.
                if let time {
                    Text(time.text)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(message.isOutgoing ? .trailing : .leading)
                        .accessibilityLabel(time.accessibilityLabel)
                }
                #endif
                if !message.reactions.isEmpty {
                    ReactionsRow(reactions: message.reactions)
                        .id(ReactionsRow.ScrollID(messageID: message.id))
                }
                sendState
            }
            if !message.isOutgoing { Spacer(minLength: 48) }
        }
        .contextMenu {
            if message.sendState == .sent {
                Button(message.hasMyThumbsUp ? "Remove 👍" : "React 👍") {
                    Task { await model.toggleThumbsUp(on: message) }
                }
            }
            // The bubble's text: the message, or a photo's or file's caption.
            if !message.text.isEmpty {
                Button("Copy", systemImage: "doc.on.doc") {
                    copyText()
                }
            }
            // Says it again in the chosen voice and model, to compare them after changing settings.
            if !message.spokenText.isEmpty {
                Button("Speak", systemImage: "speaker.wave.2") {
                    model.readAloud(message)
                }
            }
        }
        #if os(iOS)
        // Past the row's trailing end, level with the bubble, so it slides in with the bubbles. After the
        // context menu, which leaves it out of its preview.
        .overlay(alignment: Alignment(horizontal: .trailing, vertical: .bubbleCenter)) {
            if let time {
                PulledTime(messageID: message.id, text: time.text)
            }
        }
        #endif
    }

    /// The time VoiceOver reads with the bubble: on iOS, where it shows only during a pull. The Mac's time
    /// under the bubble is read on its own.
    private var spokenTime: String? {
        #if os(iOS)
        time?.accessibilityLabel
        #else
        nil
        #endif
    }

    private func copyText() {
        #if os(iOS)
        UIPasteboard.general.string = message.text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.text, forType: .string)
        #endif
    }

    /// VoiceOver reads the time as the value of the bubble's last part: its text, or else its photo or
    /// document. Set or not with `isEnabled`, so a time coming or going doesn't replace the view (and a
    /// loaded photo with it).
    private var bubble: some View {
        let spokenTime = spokenTime
        let attachmentIsLast = message.text.isEmpty
        return VStack(alignment: .leading, spacing: 6) {
            switch message.attachment {
            case .photo(let file, let width, let height):
                PhotoView(file: file, width: width, height: height)
                    .accessibilityValue(spokenTime ?? "", isEnabled: spokenTime != nil && attachmentIsLast)
            case .document(let file, let fileName, _, let size):
                DocumentRow(file: file, fileName: fileName, size: size)
                    .accessibilityValue(spokenTime ?? "", isEnabled: spokenTime != nil && attachmentIsLast)
            case nil:
                EmptyView()
            }
            if !message.text.isEmpty {
                Text(message.text)
                    .accessibilityValue(spokenTime ?? "", isEnabled: spokenTime != nil)
            }
        }
        .padding(10)
        .foregroundStyle(message.isOutgoing ? Color.white : Color.primary)
        .background(
            message.isOutgoing ? Color.accentColor : Color.secondary.opacity(0.15),
            in: .rect(cornerRadius: 16)
        )
    }

    @ViewBuilder
    private var sendState: some View {
        switch message.sendState {
        case .sent:
            EmptyView()
        case .pending:
            Label("Sending…", systemImage: "clock")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .failed(let error):
            Label("Not sent: \(error)", systemImage: "exclamationmark.circle")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }
}

/// The header above the first message of a day, as in Messages: the day, small, dimmed and centered.
/// VoiceOver reads it as a heading, so the rotor's Headings go from day to day. On iOS it holds
/// still while the bubbles slide aside to show their times: it isn't a message, and has no time.
struct DaySeparator: View {
    let separator: MessageDaySeparators.Separator

    var body: some View {
        Text(separator.text)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            // Wraps at the largest text sizes, rather than being cut short.
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            // More room above than between messages, so a new day stands apart.
            .padding(.top, 8)
            .accessibilityLabel(separator.accessibilityLabel)
            .accessibilityAddTraits(.isHeader)
            #if os(iOS)
            .modifier(HoldsStillForMessageTimes())
            #endif
    }
}

#if os(iOS)
private extension VerticalAlignment {
    /// The middle of a message's bubble, which the time beside it lines up with.
    nonisolated enum BubbleCenter: AlignmentID {
        static func defaultValue(in context: ViewDimensions) -> CGFloat {
            context[VerticalAlignment.center]
        }
    }

    static let bubbleCenter = VerticalAlignment(BubbleCenter.self)
}

/// A message's time beside its row while the list is pulled aside, and only then. It waits just past the
/// row's trailing end, so it comes into view as the bubbles slide over. It tells the pull its width, which
/// sets how far they slide.
private struct PulledTime: View {
    @Environment(MessageTimesPull.self) private var pull: MessageTimesPull?
    let messageID: MessageID
    let text: String

    var body: some View {
        // Read here rather than in the row, so the times showing and hiding redraws only this.
        if let pull, pull.showsTimes {
            // A point at the row's trailing end, which the time starts `spacing` past. (An alignment
            // guide on the time, for the row's overlay to place it by, was ignored.)
            Color.clear
                .frame(width: 0, height: 0)
                .overlay(alignment: .leading) {
                    Text(text)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        // One line, shrunk to fit whole if it must: a caption line is shorter than any
                        // bubble, so the times of neighboring rows never overlap, as wrapped ones could.
                        // An earlier year's time at the largest text size, in a 320-point window, needs
                        // about a third; a fifth leaves room for longer languages.
                        .lineLimit(1)
                        .minimumScaleFactor(0.2)
                        // Its line's height, which the zero-size point it hangs from doesn't give it.
                        .fixedSize(horizontal: false, vertical: true)
                        .onGeometryChange(for: CGFloat.self) { proxy in
                            proxy.size.width
                        } action: { width in
                            pull.timeMeasured(messageID, width: width)
                        }
                        .onDisappear {
                            pull.timeHidden(messageID)
                        }
                        // A time longer than this shrinks.
                        .containerRelativeFrame(.horizontal, alignment: .leading) { length, _ in
                            length * MessageTimesPull.widestTimeFraction
                        }
                        .padding(.leading, MessageTimesPull.spacing)
                }
                // VoiceOver reads the time with the bubble, gesture or not.
                .accessibilityHidden(true)
                .allowsHitTesting(false)
        }
    }
}

/// Slides the bubbles, all together, as far as the list's `MessageTimesPull` says. With the days'
/// headers, which `HoldsStillForMessageTimes` slides back, the only views that read `slide`, so a
/// drag redraws nothing else.
private struct SlidesForMessageTimes: ViewModifier {
    @Environment(MessageTimesPull.self) private var pull: MessageTimesPull?

    func body(content: Content) -> some View {
        // Toward the leading edge: SwiftUI mirrors the offset in a right-to-left layout.
        content.offset(x: -(pull?.slide ?? 0))
    }
}

/// Keeps a view in the list where it is while `SlidesForMessageTimes` slides the list: it slides it
/// back as far, in the same frame and with the same spring, so it doesn't move at all.
private struct HoldsStillForMessageTimes: ViewModifier {
    @Environment(MessageTimesPull.self) private var pull: MessageTimesPull?

    func body(content: Content) -> some View {
        content.offset(x: pull?.slide ?? 0)
    }
}

/// Pulling the list toward the leading edge slides the bubbles over to show each message's time beside
/// it, as in Messages, and letting go springs them back: see `MessageTimesPull`. The pull goes in the
/// environment for the views that slide the bubbles and show the times.
private struct PullsForMessageTimes: ViewModifier {
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pull = MessageTimesPull()

    func body(content: Content) -> some View {
        content
            .gesture(PullGesture(pull: pull, rightToLeft: layoutDirection == .rightToLeft, reduceMotion: reduceMotion))
            .environment(pull)
    }
}

/// The drag behind `PullsForMessageTimes`: a UIKit pan rather than a DragGesture, so it can turn down a
/// touch at the leading edge, which is the back swipe's, begin only for a drag toward the leading edge,
/// and go along with the list's scrolling, which goes on during a pull as in Messages. Other drags, taps,
/// double taps and long presses go on to the list and its bubbles as before.
private struct PullGesture: UIGestureRecognizerRepresentable {
    let pull: MessageTimesPull
    let rightToLeft: Bool
    let reduceMotion: Bool

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        context.coordinator.rightToLeft = rightToLeft
        return pan
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        context.coordinator.rightToLeft = rightToLeft
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let position = MessageTimesPull.towardLeading(recognizer.translation(in: recognizer.view).x, rightToLeft: rightToLeft)
        switch recognizer.state {
        case .began:
            pull.begin(at: position)
        case .changed:
            pull.move(to: position)
        case .ended, .cancelled, .failed:
            var release = 0
            // Once the spring has wholly stopped, so the times don't go while the bubbles still move.
            let spring = Animation.spring(duration: 0.35, bounce: MessageTimesPull.releaseBounce(reduceMotion: reduceMotion))
            withAnimation(spring, completionCriteria: .removed) {
                release = pull.release()
            } completion: {
                pull.settled(after: release)
            }
        default:
            break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var rightToLeft = false

        func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let window = touch.window else { return false }
            let x = touch.location(in: window).x
            return MessageTimesPull.mayStart(atDistanceFromLeadingEdge: rightToLeft ? window.bounds.width - x : x)
        }

        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return false }
            let translation = pan.translation(in: pan.view)
            return MessageTimesPull.begins(
                towardLeading: MessageTimesPull.towardLeading(translation.x, rightToLeft: rightToLeft),
                down: translation.y
            )
        }

        // The list's own pan, so it scrolls on while the bubbles are pulled aside: a scroll view's pan, and
        // the list's is the only scroll view under the touch. No other recognizer, such as the context
        // menu's long press, runs alongside.
        func gestureRecognizer(
            _ recognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            guard let scrollView = other.view as? UIScrollView else { return false }
            return other === scrollView.panGestureRecognizer
        }
    }
}
#endif

struct ReactionsRow: View {
    /// The ID the message list scrolls to, to show a message's reactions.
    struct ScrollID: Hashable {
        let messageID: MessageID
    }

    let reactions: [Reaction]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(reactions, id: \.emoji) { reaction in
                Text(reaction.count > 1 ? "\(reaction.emoji) \(reaction.count)" : reaction.emoji)
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        reaction.isChosen ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.15),
                        in: .capsule
                    )
            }
        }
    }
}

/// A photo shown inline. It downloads when it first appears.
struct PhotoView: View {
    private static let log = Logger(label: "app.photo")
    @Environment(AppModel.self) private var model
    let file: FileRef
    let width: Int
    let height: Int
    @State private var image: CGImage?
    @State private var failed = false
    @State private var attempt = 0

    var body: some View {
        Group {
            if let image {
                // Labelled, so VoiceOver says what a photo without a caption is before its time.
                Image(image, scale: 1, label: Text("Photo"))
                    .resizable()
            } else if failed {
                Button {
                    failed = false
                    attempt += 1
                } label: {
                    Label("Couldn't load photo. Tap to retry.", systemImage: "photo")
                        .font(.caption)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .buttonStyle(.plain)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel("Loading photo")
            }
        }
        .aspectRatio(aspectRatio, contentMode: .fit)
        .frame(maxWidth: 260)
        .clipShape(.rect(cornerRadius: 10))
        .task(id: attempt) {
            // Scrolling back to a loaded photo shouldn't download and decode it again.
            guard image == nil else { return }
            do {
                let url = try await model.download(file)
                image = await PhotoFiles.displayImage(at: url, maxPixelSize: 1024)
                failed = image == nil
            } catch {
                // Codes only: a TDLib file error's message can hold a local path.
                Self.log.error("photo download failed", error.tdlibLogCodes(["fileID": String(file.id)]))
                failed = true
            }
        }
    }

    private var aspectRatio: CGFloat {
        width > 0 && height > 0 ? CGFloat(width) / CGFloat(height) : 1
    }
}

/// A document as a filename row. Tapping downloads it, then opens Quick Look (iOS), which the
/// message list presents, or the default app (macOS).
struct DocumentRow: View {
    private static let log = Logger(label: "app.document")
    @Environment(AppModel.self) private var model
    let file: FileRef
    let fileName: String
    let size: Int64
    #if os(iOS)
    @Environment(Presentations.self) private var presentations
    #endif

    var body: some View {
        Button {
            Task { await open() }
        } label: {
            HStack(spacing: 8) {
                if model.isDownloading(file) {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "doc")
                        .font(.title2)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(fileName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(size.formatted(.byteCount(style: .file)))
                        .font(.caption)
                        .opacity(0.7)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(model.isDownloading(file))
    }

    private func open() async {
        let notificationCount = model.notificationOpenCount
        #if os(iOS)
        // The download can outlive this row, and its chat being shown.
        let request = presentations.requestPreview()
        #endif
        do {
            let url = try await model.download(file)
            guard notificationCount == model.notificationOpenCount else { return }
            #if os(iOS)
            presentations.showPreview(url, for: request)
            #else
            NSWorkspace.shared.open(url)
            #endif
        } catch {
            // Codes only: a TDLib file error's message can hold a local path.
            Self.log.error("document download failed", error.tdlibLogCodes(["fileID": String(file.id)]))
            guard notificationCount == model.notificationOpenCount else { return }
            model.errorMessage = userMessage(for: error)
        }
    }
}
