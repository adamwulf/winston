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
    /// The files copied for Winston, which Done hands over and Cancel removes.
    private var staged: ShareOutbox.Staged?
    /// Set by Cancel, so a copy still under way is removed once it ends rather than kept.
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

    /// Copies what can be sent at once, so Done can hand it over as soon as Adam taps it. Winston
    /// doesn't see it until then. Anything else that came with it, such as a web link, is left
    /// out.
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
        Task {
            do {
                let staged = try await outbox.stage(providers)
                guard !isCancelled else {
                    outbox.discard(staged)
                    return
                }
                self.staged = staged
                state.phase = .saved(count: staged.count)
            } catch {
                Self.logFailure("staging", error)
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

    private static func logFailure(_ step: String, _ error: any Error) {
        // Codes only: a file error's description names the file.
        let nsError = error as NSError
        log.error("\(step, privacy: .public) shared files failed: \(nsError.domain, privacy: .public) \(nsError.code, privacy: .public)")
    }

    /// Hands the copied files to Winston, then closes. If they're gone, as when the sheet was
    /// left open for a day and Winston removed them as leftovers, it says to share again: the
    /// originals are still where they were shared from.
    private func done() {
        guard let outbox, let staged else { return }
        do {
            try outbox.publish(staged)
        } catch {
            Self.logFailure("publishing", error)
            state.phase = .failed("Winston couldn't keep \(staged.count == 1 ? "that file" : "those files"). Try sharing again.")
            outbox.discard(staged)
            self.staged = nil
            return
        }
        self.staged = nil
        Self.log.notice("share done")
        extensionContext?.completeRequest(returningItems: nil)
    }

    /// Removes the copied files, or the copy under way once it ends, and closes. Winston never
    /// sees them: only Done hands them over. If iOS ends the extension first, what it copied stays
    /// in `Staging` until Winston removes it, a day later.
    private func cancel() {
        Self.log.notice("share cancelled")
        isCancelled = true
        if let outbox, let staged {
            outbox.discard(staged)
            self.staged = nil
        }
        extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
    }
}
