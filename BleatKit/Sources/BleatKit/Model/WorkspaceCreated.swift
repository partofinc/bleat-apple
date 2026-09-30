/// What `herdr workspace create` answers with.
///
/// Three objects, because the command makes three things at once — captured
/// live from herdr 0.9.0 into `Fixtures/workspace-create.json`, and the shape
/// re-verified against 0.9.3 on 30 Sept 2026 — identical key set:
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
/// `tab` and `root_pane` are tolerated rather than required, for the reason
/// `PaneLayout`'s fields are: the workspace is the part the screen needs, and a
/// sibling nothing reads must not throw away a workspace that was created
/// perfectly well — on someone's Mac, where it would then have to be closed by
/// hand.
///
/// **Optional is not enough for that, which is why `init(from:)` is written
/// out.** The synthesized decoder uses `decodeIfPresent`, which tolerates a
/// *missing* key and still throws `typeMismatch` on one that is present and
/// malformed — so a future herdr emitting `"number": "1"` in the tab would fail
/// the whole decode, and the create would be reported as a failure over a
/// workspace that exists. Measured, not assumed: a probe with a malformed
/// nested key throws through an optional property.
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
    /// **`requested` must be the host's canonical form, not what a user typed.**
    /// The cwd herdr reports is resolved — `/tmp` comes back `/private/tmp`,
    /// `/var` comes back `/private/var`, and `//` and `..` are collapsed — so
    /// comparing against a raw string reports a perfectly correct workspace as
    /// misplaced, for paths as ordinary as `/tmp`. `DirectoryCheck` exists to
    /// produce that form, and is asked before the create rather than after.
    ///
    /// nil when the host did not say — `root_pane` is optional, and a missing
    /// answer is not a wrong one. Callers report what they know rather than
    /// guessing, exactly as `SessionStatus` does with a session it has not
    /// asked about yet.
    public func openedElsewhere(than requested: WorkspaceDirectory) -> String? {
        guard let actual = rootPane?.cwd, actual != requested.path else { return nil }
        return actual
    }

    /// The workspace is required; its siblings are taken only if they read.
    ///
    /// `try?` per sibling rather than a plain optional — see the note above.
    /// Losing `root_pane` costs the placement check, which
    /// `openedElsewhere(than:)` already reports as "the host did not say"
    /// rather than as a wrong answer.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        workspace = try container.decode(Workspace.self, forKey: .workspace)
        tab = try? container.decodeIfPresent(Tab.self, forKey: .tab)
        rootPane = try? container.decodeIfPresent(Pane.self, forKey: .rootPane)
    }

    enum CodingKeys: String, CodingKey {
        case workspace
        case tab
        case rootPane = "root_pane"
    }
}
