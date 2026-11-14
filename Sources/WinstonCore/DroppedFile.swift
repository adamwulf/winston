import CoreTransferable
import Foundation

/// A file dropped on the chat window, as `dropDestination` hands it over, for
/// `AppModel.sendDroppedFiles` to send as a document.
///
/// It's imported from the dropped item's URL, so the copy keeps the file's name: importing the file's
/// contents instead would hand over a copy named for its type, such as "text.txt". The import copies
/// the file with `DocumentFiles.copyForSending` straight away, while the drop still grants access to
/// it, and TDLib uploads the copy.
public struct DroppedFile: Transferable, Sendable {
    /// The copy, or why it couldn't be made: a folder or a web link was dropped, or the file couldn't
    /// be read. Kept rather than thrown: SwiftUI leaves an item whose import throws out of the drop
    /// without a word, and Adam should hear why it wasn't sent.
    let copy: Result<URL, any Error>

    public static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(importing: { (url: URL) in
            do {
                return DroppedFile(copy: .success(try await DocumentFiles.copyForSending(from: url)))
            } catch {
                return DroppedFile(copy: .failure(error))
            }
        })
    }
}
