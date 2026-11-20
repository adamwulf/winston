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

    var isShowingAny: Bool {
        isShowingSettings || isShowingAlert || isShowingPicker || isShowingPushToTalk || previewURL != nil
    }
}
