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
///     SIMCTL_CHILD_BLEAT_OPEN='t58/Backend' xcrun simctl launch <phone> team.partof.bleat
///
/// Debug builds only, and inert without the variables.
public enum DebugLaunch {
    /// `BLEAT_PAIR_CODE` redeems a pairing link. `BLEAT_OPEN` opens the first
    /// host and then, when it names one, a terminal: its address, and after a
    /// slash a title for the screen (everything after the first slash, since
    /// titles may hold one). Empty stops at the host's terminal list.
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

        let parts = open.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard let address = parts.first, !address.isEmpty else { return }
        let title = parts.count > 1 && !parts[1].isEmpty ? parts[1] : address
        // A beat first, as a finger would leave: a collapsed split view turns
        // the selection into a push of its own, and a route appended in the
        // same turn is dropped.
        await step()
        context.navigation.push(.terminal(peer: peer.hostKey, address: address, title: title))
    }

    private static func step() async {
        try? await Task.sleep(for: .milliseconds(700))
    }
}
#endif
