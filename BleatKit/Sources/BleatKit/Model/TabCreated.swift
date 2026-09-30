/// What `herdr tab create` answers with.
///
/// Captured live from herdr 0.9.0 into `Fixtures/tab-create.json`, and the
/// shape re-verified against 0.9.3 on 30 Sept 2026 — identical key set:
///
/// ```
/// {"type":"tab_created",
///  "tab":      {"tab_id":"w1:t2","label":"2",…},
///  "root_pane":{"pane_id":"w1:pA","tab_id":"w1:t2","cwd":"…"}}
/// ```
///
/// Like `workspace create`, a tab is never empty: it arrives holding one pane
/// running a login shell.
///
/// **This is how the phone gets another pane, and a tab rather than a split is
/// a deliberate choice made on measurement.** Both commands produce a pane an
/// agent can start in immediately. What differs is what they cost whoever is at
/// the Mac — measured in a 120-column session:
///
/// | | pane rect |
/// |---|---|
/// | `pane split --direction right` | **60** × 40 |
/// | `tab create` | **120** × 40 |
///
/// A split halves the pane it came from *and* the new one, and this file
/// records at length what a narrow grid does to an agent's output: the program
/// wraps to its pty's width and no client can reflow it. A tab takes nothing
/// from any existing pane. So the phone adds tabs.
///
/// **`--cwd` is not sent, because the default is the one we want.** Measured
/// against a workspace whose panes sit in `/Users/ravil/Developer` while the
/// server was started in the repo root: the new tab's pane came up in
/// `/Users/ravil/Developer`. It inherits the *workspace*, not the server — the
/// opposite of `workspace create`, which is why that one must always be told.
/// So adding a pane needs no path typed on a phone at all.
public struct TabCreated: Codable, Sendable, Hashable {
    public let tab: Tab
    public let rootPane: Pane?

    public init(tab: Tab, rootPane: Pane? = nil) {
        self.tab = tab
        self.rootPane = rootPane
    }

    /// The tab is required; its pane is taken only if it reads.
    ///
    /// The same `try?`-per-sibling shape as `WorkspaceCreated`, and for the
    /// same measured reason: a plain optional still throws on a key that is
    /// present and malformed, which would report a failure over a tab that
    /// exists on someone's Mac. The caller can recover the pane by re-reading
    /// `pane list`, so losing it costs a round trip rather than the tab.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tab = try container.decode(Tab.self, forKey: .tab)
        rootPane = try? container.decodeIfPresent(Pane.self, forKey: .rootPane)
    }

    enum CodingKeys: String, CodingKey {
        case tab
        case rootPane = "root_pane"
    }
}
