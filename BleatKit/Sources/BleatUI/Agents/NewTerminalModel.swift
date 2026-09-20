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

    /// Presentation, kept **separate from the message rather than derived from
    /// it**. A binding that nils the notice on dismissal blanks the alert's
    /// title while it is still animating out, because the title is read from
    /// the model on the re-render that dismissal causes. The notice outlives
    /// its alert and is cleared by the next attempt instead.
    var isShowingNotice = false

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
        self.isShowingNotice = notice != nil
    }
    #endif

    private func show(_ notice: Notice) {
        self.notice = notice
        isShowingNotice = true
    }

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
    /// exists and only its identity was lost.
    ///
    /// A failure is reported and nothing is opened, but it is **not** a promise
    /// that nothing was created: a connection that drops after herdr ran the
    /// command leaves the tab there. The caller reloads on both paths for that
    /// reason, so a tab that did land is on screen rather than invisible —
    /// which is also what stops the obvious retry making a second one.
    func create(in workspace: String, for peer: PairedPeer) async -> Pane? {
        guard let connections, !isCreating else { return nil }
        isCreating = true
        // Cleared here rather than on dismissal, so the alert keeps its title
        // through its own exit animation.
        notice = nil
        defer { isCreating = false }
        do {
            let client = try await connections.client(for: peer, session: session)
            guard let pane = try await client.createTab(inWorkspace: workspace).rootPane else {
                // **Said in the future tense, because the list has not been
                // read yet** — this returns before the caller reloads, and a
                // reload can fail. "It is in the list" would be a claim about
                // the user's own screen that nothing here has checked.
                show(Notice(
                    title: "The terminal was created",
                    message: "The host did not say which pane it is, so it could not be opened. "
                        + "It will appear under Terminals."
                ))
                return nil
            }
            return pane
        } catch {
            await connections.handle(error)
            show(Notice(
                title: "That did not happen",
                message: ErrorMessage.failure(of: error).message
            ))
            return nil
        }
    }
}
