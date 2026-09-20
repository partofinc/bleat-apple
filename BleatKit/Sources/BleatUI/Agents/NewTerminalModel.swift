import BleatKit
import Observation

/// Opening a plain shell on the host: one `tab create`, and the pane it brings.
///
/// **There is no form, because there is nothing to ask.** `herdr tab create`
/// takes no command — what launches is the user's own shell — and a new tab's
/// pane inherits the *workspace's* directory, measured, which is the opposite
/// of `workspace create` and is why that one needs a path typed and this one
/// does not. No name, no kind, no timeout: the whole request is which
/// workspace.
///
/// **A tab rather than a `pane split`**, for the reason `NewAgentModel.addPane`
/// gives: measured in a 120-column session a split pane is 60 columns against a
/// tab's 120, and it narrows the pane it came from — which belongs to whoever
/// is at the Mac.
@Observable
final class NewTerminalModel {
    private(set) var isCreating = false

    /// What the alert says. Creating a terminal is one command with no sheet to
    /// report into, so anything worth reading has nowhere else to go.
    ///
    /// **Two shapes, and they are not both failures.** A refusal is herdr
    /// declining and nothing was created; the other is a tab that *was*
    /// created out of a reply that did not say which pane it brought, where
    /// "that did not happen" would be a lie about somebody's Mac.
    struct Notice: Identifiable, Sendable {
        let title: String
        let message: String
        var id: String { title + message }
    }

    private(set) var notice: Notice?

    /// The alert's binding, the shape `SessionControlModel` uses: SwiftUI
    /// writes false when the alert goes, and that write is what clears it.
    var isShowingNotice: Bool {
        get { notice != nil }
        set { if !newValue { notice = nil } }
    }

    /// nil only in `#Preview`; production callers all pass one.
    private let connections: ConnectionStore?
    private let session: String?

    init(connections: ConnectionStore, session: String?) {
        self.connections = connections
        self.session = session
    }

    #if DEBUG
    init(previewing notice: Notice? = nil) {
        self.connections = nil
        self.session = nil
        self.notice = notice
    }
    #endif

    /// Adds a tab to `workspace` and answers with the pane it brought, or nil
    /// when there is nothing certain to open.
    ///
    /// **The pane is not ready the instant this returns**, and that is measured
    /// rather than assumed: a new *tab's* pane took an agent immediately while a
    /// new *workspace's* root pane answered `agent_pane_busy`, because its shell
    /// had not reached a prompt. Nothing here waits, because nothing here needs
    /// to — opening the pane is a read, and the shell's prompt arrives in the
    /// stream like anything else it prints.
    ///
    /// **The pane is taken from the reply's own `root_pane`, never from
    /// "whichever pane is new".** `TabCreated` makes that field optional
    /// because a malformed one must not fail a tab that was really created —
    /// and in that case nothing is opened, because the alternative is guessing
    /// at a pane somebody at the Mac may be sitting in. That is **said**
    /// rather than left as a button that appears to do nothing: the terminal
    /// exists, it is in the list, and only its identity was lost.
    ///
    /// A failure is reported and nothing is opened, but it is **not** a promise
    /// that nothing was created: a connection that drops after herdr ran the
    /// command leaves the tab there. The caller reloads on both paths for that
    /// reason, so a tab that did land is on screen rather than invisible —
    /// which is also what stops the obvious retry making a second one.
    func create(in workspace: String, for peer: PairedPeer) async -> Pane? {
        guard let connections, !isCreating else { return nil }
        isCreating = true
        notice = nil
        defer { isCreating = false }
        do {
            let client = try await connections.client(for: peer, session: session)
            guard let pane = try await client.createTab(inWorkspace: workspace).rootPane else {
                notice = Notice(
                    title: "The terminal is in the list",
                    message: "The host made it but did not say which pane it is, "
                        + "so it could not be opened straight away."
                )
                return nil
            }
            return pane
        } catch {
            await connections.handle(error)
            notice = Notice(
                title: "That did not happen",
                message: ErrorMessage.failure(of: error).message
            )
            return nil
        }
    }
}
