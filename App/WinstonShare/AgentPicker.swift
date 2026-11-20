import ShareOutbox
import SwiftUI

/// The share extension's sheet: one row per agent, and Cancel. Tapping a row sends the shared file
/// to that agent. With one agent it still asks, so a stray tap in the share sheet sends nothing.
struct AgentPicker: View {
    enum Content {
        case agents([ShareAgent])
        /// Nothing can be sent, and why, such as before Winston has saved any agents.
        case unavailable(String)
    }

    let content: Content
    /// Saves the file for the agent, then closes the sheet. Throws if the file can't be read.
    let send: (ShareAgent) async throws -> Void
    let cancel: () -> Void

    @State private var sendingTo: ShareAgent.ID?
    @State private var failed = false

    var body: some View {
        NavigationStack {
            Group {
                switch content {
                case .agents(let agents):
                    list(agents)
                case .unavailable(let reason):
                    ContentUnavailableView(reason, systemImage: "paperplane")
                }
            }
            .navigationTitle("Send to Agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: cancel)
                        .disabled(sendingTo != nil)
                }
            }
        }
    }

    private func list(_ agents: [ShareAgent]) -> some View {
        List {
            Section {
                ForEach(agents) { agent in
                    Button {
                        pick(agent)
                    } label: {
                        HStack {
                            Text(agent.name)
                                .foregroundStyle(.primary)
                            Spacer()
                            if sendingTo == agent.id {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(sendingTo != nil)
                }
            } footer: {
                if failed {
                    Text("Winston couldn't read that file.")
                        .foregroundStyle(.red)
                } else {
                    Text("Winston sends the file the next time you open it.")
                }
            }
        }
    }

    private func pick(_ agent: ShareAgent) {
        sendingTo = agent.id
        failed = false
        Task {
            do {
                try await send(agent)
            } catch {
                sendingTo = nil
                failed = true
            }
        }
    }
}
