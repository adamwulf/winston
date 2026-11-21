import Foundation
import Observation

/// Which of the app's other presentations are showing. The agent sheet for opened files waits
/// until none is, rather than closing one Adam is using, such as push-to-talk during a hold.
/// ContentView owns it; the views that present them keep it up to date.
@Observable
final class Presentations {
    var isShowingSettings = false
    var isShowingAlert = false
    var isShowingPicker = false
    var isShowingPushToTalk = false
    /// The document Quick Look shows, on iOS: one for the whole message list, which presents it,
    /// so a document row scrolling away doesn't lose track of it.
    var previewURL: URL?
    /// The preview a document row asked for while its document downloads. A download that
    /// finishes for another, after a chat switch, say, shows nothing.
    private var pendingPreview: UUID?

    var isShowingAny: Bool {
        isShowingSettings || isShowingAlert || isShowingPicker || isShowingPushToTalk || previewURL != nil
    }

    /// Asks for a preview of a document still to download, in place of any asked for before.
    /// Returns the request, for `showPreview(_:for:)`.
    func requestPreview() -> UUID {
        let request = UUID()
        pendingPreview = request
        return request
    }

    /// Shows the downloaded document in Quick Look, if `request` is still the preview asked for.
    func showPreview(_ url: URL, for request: UUID) {
        guard pendingPreview == request else { return }
        pendingPreview = nil
        previewURL = url
    }

    /// Drops the preview asked for, so its download shows nothing: when the chat changes.
    func dropPendingPreview() {
        pendingPreview = nil
    }

    /// Closes the preview, and drops the one asked for.
    func closePreview() {
        pendingPreview = nil
        previewURL = nil
    }
}
