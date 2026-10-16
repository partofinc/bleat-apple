#if DEBUG
import BleatKit
import Foundation

/// Drives the app from its launch environment, in a simulator nobody can tap.
///
/// `simctl` can launch an app and take a picture of it, and nothing else — it
/// cannot press a button, and a `bleat://` link handed to it stops at the
/// system's "Open in Bleat?" alert. So an end-to-end run against a scratch
/// host, the only way to see the watch and the phone talk, needs the app to
/// walk itself to the screen in question:
///
///     SIMCTL_CHILD_BLEAT_PAIR_CODE='bleat://pair?d=…' xcrun simctl launch <phone> team.partof.bleat
///     SIMCTL_CHILD_BLEAT_OPEN='bleat-test/w1/host' xcrun simctl launch <watch> team.partof.bleat.watchkitapp
///
/// Debug builds only, and inert without the variables.
public enum DebugLaunch {
    /// `BLEAT_PAIR_CODE` redeems a pairing link. `BLEAT_OPEN` opens the first
    /// host and then, a path component at a time: a session, a workspace id, a
    /// title for that workspace, a pane target, and a title for that pane. The
    /// pane title is everything after the target, slashes included, since real
    /// ones are paths. An empty component takes the default (the id for the
    /// workspace title, the target for the pane's: the row title is not known
    /// here), and an empty value stops at the host's sessions.
    ///
    /// `BLEAT_OPEN_MODE` names the `PaneMode` a pane opens in, `chat` by
    /// default: `terminal` opens it as a terminal row does. Its own variable,
    /// not a path component, so it never depends on a title being given.
    public static func apply(to context: AppContext) async {
        let environment = ProcessInfo.processInfo.environment
        if let code = environment["BLEAT_PAIR_CODE"] {
            context.pairing.open(code: code)
        }
        guard let open = environment["BLEAT_OPEN"] else { return }
        // The hosts come from a file on the phone and from the phone on the
        // watch; either way they are not there on the first turn.
        for _ in 0..<100 where context.peers.peers.isEmpty {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard let peer = context.peers.peers.first else { return }
        context.navigation.selectedPeer = peer.hostKey

        // Empty components are kept, so `//` skips one without shifting the rest.
        let parts = open.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let mode = paneMode(environment["BLEAT_OPEN_MODE"])
        guard let session = parts.first, !session.isEmpty else { return }
        // A beat between steps, as a finger would leave: a collapsed split
        // view turns the selection into a push of its own, and a route
        // appended in the same turn is dropped.
        await step()
        context.navigation.push(.workspaces(peer: peer.hostKey, session: session))
        guard parts.count > 1, !parts[1].isEmpty else { return }
        let label = parts.count > 2 && !parts[2].isEmpty ? parts[2] : parts[1]
        await step()
        context.navigation.push(
            .agents(peer: peer.hostKey, session: session, workspace: parts[1], label: label)
        )
        guard parts.count > 3, !parts[3].isEmpty else { return }
        // A pane target holds a colon and no slash: `w1:p1`.
        let title = parts.count > 4 ? parts[4...].joined(separator: "/") : ""
        await step()
        context.navigation.push(
            .pane(peer: peer.hostKey, session: session, target: parts[3],
                  title: title.isEmpty ? parts[3] : title, mode: mode)
        )
    }

    /// The mode `BLEAT_OPEN_MODE` names, matched against `PaneMode` itself so a
    /// new case is reachable without touching this. A word that names none is
    /// said, not quietly read as the default: here the only symptom of a typo
    /// would be a wrong screenshot.
    private static func paneMode(_ name: String?) -> PaneMode {
        guard let name, !name.isEmpty else { return .chat }
        guard let mode = PaneMode.allCases.first(where: { "\($0)" == name }) else {
            print("DebugLaunch: BLEAT_OPEN_MODE=\(name) is not one of",
                  PaneMode.allCases.map { "\($0)" }, "- opening chat")
            return .chat
        }
        #if os(watchOS)
        // The watch has no pane stream through the phone, so a terminal here
        // would be one only a simulator's direct socket can show.
        if mode != .chat {
            print("DebugLaunch: the watch opens panes as chat; ignoring BLEAT_OPEN_MODE=\(name)")
            return .chat
        }
        #endif
        return mode
    }

    private static func step() async {
        try? await Task.sleep(for: .milliseconds(700))
    }
}
#endif
