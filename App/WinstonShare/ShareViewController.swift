import os
import ShareOutbox
import SwiftUI
import UIKit

/// The share extension's principal class (`NSExtensionPrincipalClass` in
/// `Config/WinstonShare-Info.plist`), over the app Adam shared from: Photos, the screenshot
/// editor, Files, Mail.
///
/// The extension can't run TDLib, so it saves the shared files in the App Group (`ShareOutbox`)
/// and, once they're saved, opens Winston and closes. Winston opens each as a file from Open in
/// (`AppModel.openSharedFiles()`), and its Send to Agent sheet asks which agent it goes to.
final class ShareViewController: UIViewController {
    private static let log = Logger(subsystem: "com.milestonemade.winston.share", category: "share")

    private let outbox = ShareOutbox.appGroup()
    private let state = ShareState(phase: .saving(count: 0))
    /// The copy under way, which Cancel stops.
    private var stageTask: Task<Void, Never>?
    /// The files copied for Winston, waiting for the sheet to be in its window (`handOff()`).
    private var staged: ShareOutbox.Staged?
    /// Set by Cancel, so a copy that ends anyway is removed rather than kept.
    private var isCancelled = false
    /// Set once the sheet is in its window, where `openWinston()` finds the application up the
    /// responder chain. A small file can be copied before then.
    private var hasAppeared = false

    override func viewDidLoad() {
        super.viewDidLoad()
        let panel = UIHostingController(rootView: SharePanel(
            state: state,
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

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        hasAppeared = true
        handOff()
    }

    /// Everything the share sheet handed over. The activation rule allows up to 10 images and
    /// 10 files.
    private var attachments: [NSItemProvider] {
        let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        return items.flatMap { $0.attachments ?? [] }
    }

    /// Copies what can be sent at once, then hands it over (`handOff()`). Winston doesn't see it
    /// until then. Anything else that came with it, such as a web link, is left out.
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
        stageTask = Task {
            do {
                let staged = try await outbox.stage(providers)
                guard !isCancelled else {
                    outbox.discard(staged)
                    return
                }
                self.staged = staged
                handOff()
            } catch {
                // Cancel stopped it, and it left nothing behind.
                guard !isCancelled else { return }
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

    /// Hands the copied files to Winston, opens it, and closes, once they're copied and the sheet
    /// is in its window, whichever comes last. If they can't be handed over, it says to share
    /// again: the originals are still where they were shared from.
    private func handOff() {
        guard hasAppeared, let outbox, let staged else { return }
        self.staged = nil
        do {
            try outbox.publish(staged)
        } catch {
            Self.logFailure("publishing", error)
            state.phase = .failed("Winston couldn't keep \(staged.count == 1 ? "that file" : "those files"). Try sharing again.")
            outbox.discard(staged)
            return
        }
        Self.log.notice("share handed over")
        openWinston()
        extensionContext?.completeRequest(returningItems: nil)
    }

    /// Opens Winston, whose Send to Agent sheet then asks for the agent. `NSExtensionContext`'s
    /// `open(_:completionHandler:)` opens an app only from a Today or iMessage extension, so this
    /// asks the extension's `UIApplication`, found up the responder chain: the sheet's view, in
    /// its window, leads to the window's scene and then the application. Called before the
    /// request completes, while the view is still there. If Winston doesn't open, the files wait
    /// in the outbox until Adam next opens it.
    private func openWinston() {
        guard let url = ShareOutbox.openURL else { return }
        var responder: UIResponder? = self
        while let next = responder {
            if let application = next as? UIApplication {
                application.open(url, options: [:]) { opened in
                    Self.log.notice("opening Winston: \(opened ? "opened" : "failed", privacy: .public)")
                }
                return
            }
            responder = next.next
        }
        Self.log.error("opening Winston failed: no application in the responder chain")
    }

    /// Removes the copied files, or stops the copy under way, which removes what it copied, and
    /// closes. Winston never sees them: they're handed over only once copied. If iOS ends the
    /// extension first, what it copied stays in `Staging` until Winston removes it, a day later.
    private func cancel() {
        Self.log.notice("share cancelled")
        isCancelled = true
        stageTask?.cancel()
        if let outbox, let staged {
            outbox.discard(staged)
            self.staged = nil
        }
        extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
    }
}
