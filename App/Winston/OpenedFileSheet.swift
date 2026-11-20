import SwiftUI
import TelegramLink
import WinstonCore

/// The sheet for files opened in Winston from another app: the files, one row per agent, and
/// Cancel. Picking an agent sends them there (`AppModel.sendOpenedFiles(to:)`) and the chat shown
/// stays the same. With one agent it still asks, so a stray tap in another app sends nothing.
/// It can't be swiped away, which could be taken for either; it closes once the files are sent
/// or cancelled. A file that couldn't be copied shows why, with Try Again.
struct OpenedFileSheet: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            List {
                filesSection
                if let error = model.openedFileError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
                agentsSection
            }
            .navigationTitle("Send to Agent")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        model.cancelOpenedFiles()
                    }
                    .disabled(isSending)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 360, minHeight: 320)
        #endif
        .interactiveDismissDisabled()
        // VoiceOver says them, as they show away from the row just picked.
        .onChange(of: model.openedFileError) { _, error in
            if let error {
                AccessibilityNotification.Announcement(error).post()
            }
        }
        .onChange(of: copyErrors) { old, new in
            if new.count > old.count, let error = new.last {
                AccessibilityNotification.Announcement(error).post()
            }
        }
    }

    /// Why each file that couldn't be copied couldn't be.
    private var copyErrors: [String] {
        model.openedFiles.compactMap(\.copyError)
    }

    @ViewBuilder
    private var filesSection: some View {
        if !model.openedFiles.isEmpty {
            Section(model.openedFiles.count == 1 ? "File" : "Files") {
                ForEach(model.openedFiles) { file in
                    fileRow(file)
                }
            }
        }
    }

    @ViewBuilder
    private func fileRow(_ file: OpenedFile) -> some View {
        if file.isCopied {
            Label(file.name, systemImage: file.isPhoto ? "photo" : "doc")
                .accessibilityValue(file.isPhoto ? "Sent as a photo" : "Sent as a file")
        } else if let error = file.copyError {
            // Couldn't be copied, as with the disk full. The other files can go meanwhile.
            VStack(alignment: .leading, spacing: 6) {
                Label(file.name, systemImage: "exclamationmark.triangle.fill")
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                Button("Try Again") {
                    model.retryCopy(of: file.id)
                }
                // Only the button, not the whole row.
                .buttonStyle(.borderless)
                .disabled(isSending)
            }
        } else {
            // Being copied, as an iCloud Drive file downloads.
            Label {
                Text(file.name)
                    .foregroundStyle(.secondary)
            } icon: {
                ProgressView()
                    .controlSize(.small)
            }
            .accessibilityValue("Preparing")
        }
    }

    @ViewBuilder
    private var agentsSection: some View {
        if model.chats.isEmpty {
            Section {
                ContentUnavailableView(
                    "No Agents",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Start a chat with your bots in Telegram, then open the file in Winston again.")
                )
            }
        } else {
            Section("Send To") {
                ForEach(model.chats) { chat in
                    agentRow(chat)
                }
            }
        }
    }

    private func agentRow(_ chat: BotChat) -> some View {
        Button {
            Task { await model.sendOpenedFiles(to: chat.id) }
        } label: {
            HStack {
                Text(chat.title)
                    .foregroundStyle(.primary)
                Spacer()
                if model.openedFilesSendingTo == chat.id {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .disabled(!canSend)
        .accessibilityValue(model.openedFilesSendingTo == chat.id ? "Sending" : "")
    }

    /// A file is copied, none is still being copied, and none is being sent. One whose copy
    /// failed doesn't hold the others up.
    private var canSend: Bool {
        model.openedFiles.contains(where: \.isCopied) && model.openedFilesBeingCopied == 0 && !isSending
    }

    private var isSending: Bool {
        model.openedFilesSendingTo != nil
    }
}
