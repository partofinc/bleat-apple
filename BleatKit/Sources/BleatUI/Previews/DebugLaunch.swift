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
    /// title for that workspace, and a pane target. An empty value stops at the
    /// host's sessions.
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

        let parts = open.split(separator: "/").map(String.init)
        guard let session = parts.first else { return }
        // A beat between steps, as a finger would leave: a collapsed split
        // view turns the selection into a push of its own, and a route
        // appended in the same turn is dropped.
        await step()
        context.navigation.push(.workspaces(peer: peer.hostKey, session: session))
        guard parts.count > 1 else { return }
        let label = parts.count > 2 ? parts[2] : parts[1]
        await step()
        context.navigation.push(
            .agents(peer: peer.hostKey, session: session, workspace: parts[1], label: label)
        )
        guard parts.count > 3 else { return }
        // A pane target holds a colon and no slash: `w1:p1`.
        await step()
        context.navigation.push(
            .pane(peer: peer.hostKey, session: session, target: parts[3], title: parts[3])
        )
    }

    private static func step() async {
        try? await Task.sleep(for: .milliseconds(700))
    }
}
#endif
