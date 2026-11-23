import os
import ShareOutbox
import SwiftUI
import UIKit

/// The share extension's principal class (`NSExtensionPrincipalClass` in
/// `Config/WinstonShare-Info.plist`), over the app Adam shared from: Photos, the screenshot
/// editor, Files, Mail.
///
/// The extension can't run TDLib, nor open Winston, so it saves the shared files in the App
/// Group (`ShareOutbox`) and says to open Winston. Winston opens each the next time it's active,
/// as a file from Open in (`AppModel.openSharedFiles()`), and its Send to Agent sheet asks which
/// agent it goes to.
final class ShareViewController: UIViewController {
    private static let log = Logger(subsystem: "com.milestonemade.winston.share", category: "share")

    private let outbox = ShareOutbox.appGroup()
    private let state = ShareState(phase: .saving(count: 0))
    private var saveTask: Task<Void, Never>?
    /// What was saved, for Cancel to remove.
    private var saved: [URL] = []
    private var isCancelled = false

    override func viewDidLoad() {
        super.viewDidLoad()
        let panel = UIHostingController(rootView: SharePanel(
            state: state,
            done: { [weak self] in
                self?.done()
            },
            cancel: { [weak self] in
                self?.cancel()
            }
        ))
        addChild(panel)
        panel.view.frame = view.bounds
        panel.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(panel.view)
        panel.didMove(toParent: self)
        save()
    }

    /// Everything the share sheet handed over. The activation rule allows up to 10 images and
    /// 10 files.
    private var attachments: [NSItemProvider] {
        let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        return items.flatMap { $0.attachments ?? [] }
    }

    /// Saves what can be sent at once, so the sheet says what's next as soon as it can. Anything
    /// else that came with it, such as a web link, is left out.
    private func save() {
        guard let outbox else {
            state.phase = .unavailable("Sharing isn't set up in this build of Winston.")
            return
        }
        let all = attachments
        let providers = all.filter(ShareOutbox.canAdd)
        Self.log.notice("share sheet handed over \(all.count, privacy: .public) items, \(providers.count, privacy: .public) files")
        guard !providers.isEmpty else {
            state.phase = .unavailable("There's no file here Winston can send.")
            return
        }
        state.phase = .saving(count: providers.count)
        saveTask = Task {
            do {
                let files = try await outbox.add(providers)
                guard !isCancelled else {
                    outbox.remove(files)
                    return
                }
                saved = files
                state.phase = .saved(count: files.count)
            } catch {
                let nsError = error as NSError
                Self.log.error("saving shared files failed: \(nsError.domain, privacy: .public) \(nsError.code, privacy: .public)")
                state.phase = .failed(Self.message(for: error, count: providers.count))
            }
        }
    }

    private static func message(for error: any Error, count: Int) -> String {
        switch error as? ShareOutbox.AddFailure {
        case .folder: "Winston can send files, but not folders."
        case .noFile: "There's no file here Winston can send."
        case nil: "Winston couldn't read \(count == 1 ? "that file" : "those files"). Try sharing again."
        }
    }

    private func done() {
        Self.log.notice("share done")
        extensionContext?.completeRequest(returningItems: nil)
    }

    /// Removes what was saved, or will be once the save under way ends.
    private func cancel() {
        Self.log.notice("share cancelled")
        isCancelled = true
        saveTask?.cancel()
        outbox?.remove(saved)
        saved = []
        extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
    }
}
