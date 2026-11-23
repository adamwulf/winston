import Observation
import SwiftUI

/// Where saving the shared files has got to, for `SharePanel`.
@Observable
final class ShareState {
    enum Phase: Equatable {
        /// Copying this many files into the App Group for Winston.
        case saving(count: Int)
        /// Saved this many: Winston asks for the agent when it's next opened.
        case saved(count: Int)
        /// Couldn't save them, and why. Nothing was saved.
        case failed(String)
        /// Nothing here can be saved, and why.
        case unavailable(String)
    }

    var phase: Phase

    init(phase: Phase) {
        self.phase = phase
    }

    var isSaved: Bool {
        if case .saved = phase { true } else { false }
    }

    /// What VoiceOver says as the phase changes, as nothing else draws it there.
    var announcement: String? {
        switch phase {
        case .saving: nil
        case .saved(let count): "\(Self.readyTitle(count)). \(Self.openWinston(count))"
        case .failed(let message), .unavailable(let message): message
        }
    }

    static func readyTitle(_ count: Int) -> String {
        count == 1 ? "Ready to Send" : "\(count) Files Ready to Send"
    }

    static func openWinston(_ count: Int) -> String {
        "Tap Done, then open Winston to choose the agent \(count == 1 ? "it goes" : "they go") to."
    }
}

/// The share extension's sheet. It copies what was shared at once, then says to tap Done and open
/// Winston, whose Send to Agent sheet asks which agent it goes to, as for a file from Open in.
/// Done hands the files to Winston and closes; Cancel, at any point, removes them, and Winston
/// never sees them.
struct SharePanel: View {
    let state: ShareState
    let done: () -> Void
    let cancel: () -> Void

    var body: some View {
        NavigationStack {
            content
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle("Send with Winston")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", action: cancel)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", action: done)
                            .disabled(!state.isSaved)
                    }
                }
        }
        .onChange(of: state.phase) {
            if let announcement = state.announcement {
                AccessibilityNotification.Announcement(announcement).post()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state.phase {
        case .saving(let count):
            ProgressView(count == 1 ? "Preparing the file…" : "Preparing \(count) files…")
        case .saved(let count):
            ContentUnavailableView {
                Label(ShareState.readyTitle(count), systemImage: "paperplane")
            } description: {
                Text(ShareState.openWinston(count))
            }
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't Prepare", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            }
        case .unavailable(let message):
            ContentUnavailableView {
                Label("Nothing to Send", systemImage: "paperplane")
            } description: {
                Text(message)
            }
        }
    }
}
