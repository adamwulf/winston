import SwiftUI
import TelegramLink
import WinstonCore
import WinstonLogging
#if os(iOS)
import QuickLook
#else
import AppKit
#endif

/// The current chat's messages, scrolled to the newest. Incoming messages are marked read as they appear,
/// but only while the window is active, so replies that arrive while Adam is elsewhere stay unread.
struct MessageList: View {
    @Environment(AppModel.self) private var model
    #if os(macOS)
    @Environment(\.appearsActive) private var isActive
    #else
    @Environment(\.scenePhase) private var scenePhase
    private var isActive: Bool { scenePhase == .active }
    #endif

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(model.currentMessages) { message in
                        MessageRow(message: message)
                            .id(message.id)
                            .onAppear {
                                if isActive { model.markRead(message) }
                            }
                    }
                }
                .padding()
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: model.currentMessages.last?.id) { _, newestID in
                guard let newestID else { return }
                withAnimation {
                    proxy.scrollTo(newestID, anchor: .bottom)
                }
            }
            .onChange(of: isActive) {
                // Private-chat read state is a watermark, so marking the newest message covers the earlier ones.
                if isActive, let newest = model.latestIncomingMessage {
                    model.markRead(newest)
                }
            }
        }
    }
}

/// One message: a bubble (incoming on the left, outgoing on the right), its reactions, and its send state.
struct MessageRow: View {
    @Environment(AppModel.self) private var model
    let message: ChatMessage

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
                if !message.reactions.isEmpty {
                    ReactionsRow(reactions: message.reactions)
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
        }
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch message.attachment {
            case .photo(let file, let width, let height):
                PhotoView(file: file, width: width, height: height)
            case .document(let file, let fileName, _, let size):
                DocumentRow(file: file, fileName: fileName, size: size)
            case nil:
                EmptyView()
            }
            if !message.text.isEmpty {
                Text(message.text)
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

struct ReactionsRow: View {
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
                Image(decorative: image, scale: 1)
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

/// A document as a filename row. Tapping downloads it, then opens Quick Look (iOS) or the default app (macOS).
struct DocumentRow: View {
    private static let log = Logger(label: "app.document")
    @Environment(AppModel.self) private var model
    let file: FileRef
    let fileName: String
    let size: Int64
    #if os(iOS)
    @State private var previewURL: URL?
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
        #if os(iOS)
        .quickLookPreview($previewURL)
        #endif
    }

    private func open() async {
        do {
            let url = try await model.download(file)
            #if os(iOS)
            previewURL = url
            #else
            NSWorkspace.shared.open(url)
            #endif
        } catch {
            // Codes only: a TDLib file error's message can hold a local path.
            Self.log.error("document download failed", error.tdlibLogCodes(["fileID": String(file.id)]))
            model.errorMessage = userMessage(for: error)
        }
    }
}
