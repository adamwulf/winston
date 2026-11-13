#if os(iOS)
import SwiftUI
import UIKit

/// The system share sheet for one file, so it can go to Files, AirDrop, or Mail.
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    /// Called once the sheet finishes, shared or cancelled.
    let onFinish: () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in
            onFinish()
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// A file for `.sheet(item:)`.
struct SharedFile: Identifiable {
    let url: URL
    var id: URL { url }
}
#endif
