import os
import ShareOutbox
import SwiftUI
import UIKit

/// The share extension's principal class (`NSExtensionPrincipalClass` in
/// `Config/WinstonShare-Info.plist`): the agent picker, over the app Adam shared from.
///
/// The extension can't run TDLib, so picking an agent copies the shared file into the App
/// Group's outbox and closes. Winston sends it the next time it's opened (see
/// `AppModel.sendSharedFiles()`). An extension has no supported way to open its app, so it
/// doesn't try.
final class ShareViewController: UIViewController {
    private static let log = Logger(subsystem: "com.milestonemade.winston.share", category: "share")

    private let outbox = ShareOutbox.appGroup()

    override func viewDidLoad() {
        super.viewDidLoad()
        let picker = UIHostingController(rootView: AgentPicker(
            content: content(),
            send: { [weak self] agent in
                try await self?.save(to: agent)
            },
            cancel: { [weak self] in
                self?.cancel()
            }
        ))
        addChild(picker)
        picker.view.frame = view.bounds
        picker.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(picker.view)
        picker.didMove(toParent: self)
    }

    /// Everything the share sheet handed over. The activation rule allows one image or one file.
    private var attachments: [NSItemProvider] {
        let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        return items.flatMap { $0.attachments ?? [] }
    }

    /// The agents to pick from, or why there are none.
    private func content() -> AgentPicker.Content {
        guard let outbox else {
            return .unavailable("Sharing isn't set up in this build of Winston.")
        }
        let count = attachments.count
        guard count == 1 else {
            Self.log.notice("share sheet handed over \(count, privacy: .public) items; one is needed")
            return .unavailable(count == 0 ? "There's no file here to send." : "Winston sends one file at a time.")
        }
        let agents: [ShareAgent]
        do {
            agents = try outbox.agents()
        } catch {
            // Opening Winston saves the list again. Codes only: a file error's description holds
            // the container's path.
            let nsError = error as NSError
            Self.log.error("agent list unreadable: \(nsError.domain, privacy: .public) \(nsError.code, privacy: .public)")
            agents = []
        }
        Self.log.notice("agent picker shown with \(agents.count, privacy: .public) agents")
        return agents.isEmpty ? .unavailable("No agents yet. Open Winston first.") : .agents(agents)
    }

    /// Copies the shared file into the outbox for `agent`, then closes the share sheet.
    private func save(to agent: ShareAgent) async throws {
        guard let outbox, let attachment = attachments.first else { return }
        do {
            let item = try await outbox.add(attachment, for: agent.id)
            Self.log.notice("shared file saved to the outbox, type \(item.typeIdentifier, privacy: .public)")
        } catch {
            let types = attachment.registeredTypeIdentifiers.joined(separator: ",")
            Self.log.error("saving the shared file failed, types \(types, privacy: .public)")
            throw error
        }
        extensionContext?.completeRequest(returningItems: nil)
    }

    private func cancel() {
        Self.log.notice("share cancelled")
        extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
    }
}
