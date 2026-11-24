import Observation
import SwiftUI

/// Where saving the shared files has got to, for `SharePanel`. Once saved, the sheet closes and
/// Winston opens, so there's no phase for that.
@Observable
final class ShareState {
    enum Phase: Equatable {
        /// Copying this many files into the App Group for Winston.
        case saving(count: Int)
        /// Couldn't save them, and why. Nothing was saved.
        case failed(String)
        /// Nothing here can be saved, and why.
        case unavailable(String)
    }

    var phase: Phase

    init(phase: Phase) {
        self.phase = phase
    }

    /// What VoiceOver says as the phase changes, as nothing else draws it there.
    var announcement: String? {
        switch phase {
        case .saving: nil
        case .failed(let message), .unavailable(let message): message
        }
    }
}

/// The share extension's sheet, shown while it copies what was shared. Once copied, the files go
/// to Winston and the sheet closes as Winston opens, and its Send to Agent sheet asks which agent
/// they go to, as for a file from Open in. Cancel, while they copy, removes them, and Winston
/// never sees them; after a failure, it closes the sheet.
struct SharePanel: View {
    let state: ShareState
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
