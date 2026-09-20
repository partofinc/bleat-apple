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
    /// Shown in an alert and cleared by it. Creating a terminal is one command
    /// with no sheet to report into, so a refusal has nowhere else to go.
    private(set) var failure: String?

    /// The alert's binding, the shape `SessionControlModel` uses: SwiftUI
    /// writes false when the alert goes, and that write is what clears the
    /// message.
    var isShowingFailure: Bool {
        get { failure != nil }
        set { if !newValue { failure = nil } }
    }

    /// nil only in `#Preview`; production callers all pass one.
    private let connections: ConnectionStore?
    private let session: String?

    init(connections: ConnectionStore, session: String?) {
        self.connections = connections
        self.session = session
    }

    #if DEBUG
    init(previewing failure: String? = nil) {
        self.connections = nil
        self.session = nil
        self.failure = failure
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
    /// and in that case the honest answer is nil: the caller reloads, the new
    /// terminal appears in the list with the rest, and nothing has guessed at a
    /// pane somebody at the Mac may be sitting in.
    ///
    /// A failure is reported and nothing is opened, but it is **not** a promise
    /// that nothing was created: a connection that drops after herdr ran the
    /// command leaves the tab there. The caller reloads on both paths for that
    /// reason, so a tab that did land is on screen rather than invisible —
    /// which is also what stops the obvious retry making a second one.
    func create(in workspace: String, for peer: PairedPeer) async -> Pane? {
        guard let connections, !isCreating else { return nil }
        isCreating = true
        failure = nil
        defer { isCreating = false }
        do {
            let client = try await connections.client(for: peer, session: session)
            return try await client.createTab(inWorkspace: workspace).rootPane
        } catch {
            await connections.handle(error)
            failure = ErrorMessage.failure(of: error).message
            return nil
        }
    }
}
