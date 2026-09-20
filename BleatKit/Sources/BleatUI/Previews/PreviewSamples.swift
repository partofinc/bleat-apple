#if DEBUG
import BleatKit
import Foundation

/// What the host says, for previews.
///
/// Hand-written rather than read from `Fixtures/` — those are not bundled with
/// the app and a preview cannot reach them — but shaped like the captured
/// output: opaque workspace ids of both lengths, `pane_id` already carrying its
/// workspace (`w2:p1`, never a bare `p1`), and every one of the five agent
/// states present. A sample list that was all `idle` would leave the screens
/// this app is organised around — blocked first — with nothing to show.

extension SessionInfo {
    static var samples: [SessionInfo] {
        [
            SessionInfo(name: "work", running: true, isDefault: true),
            SessionInfo(name: "phone", running: true, isDefault: false),
            SessionInfo(name: "bleat-test", running: false, isDefault: false),
        ]
    }
}

extension Workspace {
    /// In the order `HerdrClient.workspaces()` returns them — blocked, done,
    /// working, idle, unknown — so a preview cannot disagree with the app about
    /// what "most in need of attention first" means.
    static var samples: [Workspace] {
        [
            Workspace(
                workspaceID: "w2", label: "bleat-apple", number: 2,
                agentStatus: .blocked, focused: true, paneCount: 3, tabCount: 2
            ),
            Workspace(
                workspaceID: "w653998617a6031", label: "herdr", number: 5,
                agentStatus: .done, paneCount: 2
            ),
            Workspace(
                workspaceID: "wA", label: "nuvio-assess", number: 7,
                agentStatus: .working, paneCount: 4, tabCount: 3
            ),
            Workspace(
                workspaceID: "w3", label: "dotfiles", number: 3,
                agentStatus: .idle, paneCount: 1
            ),
            Workspace(
                workspaceID: "w9", label: "scratch", number: 9,
                agentStatus: .unknown, paneCount: 1
            ),
        ]
    }
}

extension Agent {
    /// Blocked first, as `HerdrClient.agents()` sorts them.
    ///
    /// The last two exist for the row's fallbacks: one with no title at all,
    /// which must fall back to the agent kind rather than rendering blank, and
    /// one with neither, which falls back to the pane id.
    static var samples: [Agent] {
        [
            Agent(
                paneID: "w2:p1", workspaceID: "w2", tabID: "t1", agentStatus: .blocked,
                agent: "claude",
                cwd: "/Users/ravil/Developer/rawillk/bleat-apple",
                foregroundCwd: "/Users/ravil/Developer/rawillk/bleat-apple/BleatKit",
                terminalTitleStripped: "Do you want to make this edit to PeerDetailView.swift?"
            ),
            Agent(
                paneID: "w2:p2", workspaceID: "w2", tabID: "t1", agentStatus: .done,
                agent: "claude",
                cwd: "/Users/ravil/Developer/rawillk/herdr",
                terminalTitleStripped: "Rewrote the pane layout tests"
            ),
            Agent(
                paneID: "w2:p3", workspaceID: "w2", tabID: "t2", agentStatus: .working,
                agent: "claude",
                cwd: "/Users/ravil/Developer/rawillk/nuvio-assess",
                foregroundCwd: "/Users/ravil/Developer/rawillk/nuvio-assess/LinkKit/Sources",
                terminalTitleStripped: "Auditing the migration for missing indexes"
            ),
            Agent(
                paneID: "w2:p4", workspaceID: "w2", tabID: "t2", agentStatus: .idle,
                agent: "codex",
                cwd: "/Users/ravil/Developer/rawillk/dotfiles"
            ),
            Agent(
                paneID: "w2:p5", workspaceID: "w2", tabID: "t3", agentStatus: .unknown,
                cwd: "/Users/ravil"
            ),
        ]
    }
}

extension TranscriptEntry {
    /// A short exchange with a subagent's report in the middle of it, which is
    /// the case the "subagent" chip exists for.
    static var samples: [TranscriptEntry] {
        let start = Date(timeIntervalSinceNow: -1_500)
        return [
            TranscriptEntry(
                id: "1", role: .user,
                text: "The endpoint list keeps losing the Tailscale name when the tunnel is off. "
                    + "Can you find out why?",
                timestamp: start
            ),
            TranscriptEntry(
                id: "2", role: .assistant,
                text: """
                    Found it. `tailscale status --json` exits 0 with \
                    `BackendState: "Stopped"`, so a stopped tunnel is not an error — it is a \
                    clean, empty answer. Flattened into one list, that is indistinguishable \
                    from a host that has dropped every overlay address, and one refresh \
                    prunes them all.

                    The fix is to keep the report per probe: `nil` means "this probe gave no \
                    confident answer" and prunes nothing, while an empty array is a real one.
                    """,
                timestamp: start.addingTimeInterval(90)
            ),
            TranscriptEntry(
                id: "3", role: .assistant,
                text: "Checked the other two probes as well: `scutil` and `ifconfig` both fail "
                    + "loudly, so neither has this shape.",
                timestamp: start.addingTimeInterval(140),
                isSidechain: true
            ),
            TranscriptEntry(
                id: "4", role: .user,
                text: "Good. Write the test first, then the fix.",
                timestamp: start.addingTimeInterval(200)
            ),
        ]
    }
}

extension Pane {
    /// Free panes, for the picker that starts an agent: one per workspace plus
    /// a split, with the opaque id forms the host really uses.
    ///
    /// Read as JSON rather than built with a memberwise initialiser, for the
    /// reason CLAUDE.md gives about `Agent.target`: a hand-built model can be
    /// wrong in the same way the code is and the test still passes. This is the
    /// shape `pane list` really returns.
    static var samples: [Pane] {
        // The three shapes a shell takes on screen, which is what `TerminalRow`
        // is written against: titled with its own directory, as an idle login
        // shell is in `Fixtures/pane-list.json`; titled with what it is running,
        // which is when the path below it earns its place; and untitled, which
        // falls back to the pane id.
        let body = """
        [{"pane_id":"w2:p1","workspace_id":"w2","tab_id":"w2:t1","agent_status":"unknown",
          "focused":false,"cwd":"/Users/ravil/Developer/rawillk/bleat-apple",
          "foreground_cwd":"/Users/ravil/Developer/rawillk/bleat-apple",
          "terminal_title":"ravil@rawillkair:~/Developer/rawillk/bleat-apple",
          "terminal_title_stripped":"ravil@rawillkair:~/Developer/rawillk/bleat-apple"},
         {"pane_id":"w2:p3","workspace_id":"w2","tab_id":"w2:t1","agent_status":"unknown",
          "focused":false,"cwd":"/Users/ravil/Developer/rawillk/bleat-apple",
          "foreground_cwd":"/Users/ravil/Developer/rawillk/bleat-apple/BleatKit",
          "terminal_title":"swift test","terminal_title_stripped":"swift test"},
         {"pane_id":"w653998617a6031:p1","workspace_id":"w653998617a6031",
          "tab_id":"w653998617a6031:t1","agent_status":"unknown","focused":false,
          "cwd":"/Users/ravil/Developer/rawillk/herdr"}]
        """
        return (try? JSONDecoder().decode([Pane].self, from: Data(body.utf8))) ?? []
    }

    /// What `NewWorkspaceModel.loadSuggestions` derives from `pane list`: the
    /// distinct directories the host's panes are already sitting in.
    ///
    /// Sorted, because the model sorts them, and shaped like the real thing —
    /// several checkouts under one parent, which is the case that makes head
    /// truncation the right choice in the row.
    static var sampleDirectories: [String] {
        [
            "/Users/ravil/Developer/rawillk/bleat-apple",
            "/Users/ravil/Developer/rawillk/herdr",
            "/Users/ravil/Developer/nuvio/nuvio-assess",
            "/Users/ravil/dotfiles",
        ].sorted()
    }
}

#endif
