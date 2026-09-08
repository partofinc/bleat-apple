/// What `herdr workspace create` answers with.
///
/// Three objects, because the command makes three things at once — captured
/// live from herdr 0.9.0 into `Fixtures/workspace-create.json`:
///
/// ```
/// {"type":"workspace_created",
///  "workspace":{"workspace_id":"w4","label":"captured","tab_count":1,…},
///  "tab":      {"tab_id":"w4:t1","label":"1",…},
///  "root_pane":{"pane_id":"w4:p1","cwd":"/Users/ravil/Developer",…}}
/// ```
///
/// **A workspace is never empty**, and neither is a tab: `workspace create`
/// yields a workspace holding one tab holding one pane, and that pane is a
/// plain login shell. Verified — `pane process-info` on a new pane reports
/// `argv: ["-zsh"]`, and `agent list` for the session stays empty. Herdr calls
/// a pane an *agent* only once its detection recognises one, so an agent is a
/// separate, opt-in step (`herdr agent start`) rather than a mode this command
/// has.
///
/// `tab` and `root_pane` are optional for the reason `PaneLayout`'s fields
/// are: the workspace is the part the screen needs, and a decode failure on a
/// sibling nothing reads would throw away a workspace that was created
/// perfectly well — on someone's Mac, where it would then have to be closed by
/// hand.
public struct WorkspaceCreated: Codable, Sendable, Hashable {
    public let workspace: Workspace
    public let tab: Tab?
    public let rootPane: Pane?

    public init(workspace: Workspace, tab: Tab? = nil, rootPane: Pane? = nil) {
        self.workspace = workspace
        self.tab = tab
        self.rootPane = rootPane
    }

    /// Where the root pane really opened, when that is not where it was asked
    /// to — otherwise nil.
    ///
    /// **The reply is not evidence on its own.** herdr accepts a `--cwd` that
    /// does not exist, reports success, and silently opens the pane in the home
    /// directory instead; see `WorkspaceDirectory`. So the honest confirmation
    /// is the host's own account of where the pane ended up, compared against
    /// what was asked for.
    ///
    /// nil when the host did not say — `root_pane` is optional, and a missing
    /// answer is not a wrong one. Callers report what they know rather than
    /// guessing, exactly as `SessionStatus` does with a session it has not
    /// asked about yet.
    public func openedElsewhere(than requested: WorkspaceDirectory) -> String? {
        guard let actual = rootPane?.cwd, actual != requested.path else { return nil }
        return actual
    }

    enum CodingKeys: String, CodingKey {
        case workspace
        case tab
        case rootPane = "root_pane"
    }
}
