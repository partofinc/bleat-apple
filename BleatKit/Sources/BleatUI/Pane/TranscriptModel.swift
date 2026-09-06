import BleatKit
import Foundation
import Observation

/// Loads an agent's own transcript for the pane on screen.
///
/// Two hops, because herdr only knows the pointer. `agent get` gives
/// `agent_session`, and the transcript is a file the *agent* wrote — so the
/// second hop is a plain shell command over `ShellRunner`, the same seam
/// pairing uses, rather than anything herdr can answer.
@Observable
final class TranscriptModel {
    enum Phase {
        case idle
        case loading
        case loaded([TranscriptEntry])
        /// The pane has no transcript to read, and that is not a failure.
        /// A plain shell, an agent that keeps no transcript, an agent herdr
        /// identifies by a path form this build does not read yet.
        case unavailable(String)
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var capturedAt: Date?

    private let connections: ConnectionStore
    private let session: String?
    private let target: String
    /// Same hazard as `RemoteList`: a slow load that finishes late must not
    /// overwrite a newer one that already succeeded.
    private var generation = 0

    init(connections: ConnectionStore, session: String?, target: String) {
        self.connections = connections
        self.session = session
        self.target = target
    }

    var entries: [TranscriptEntry] {
        if case .loaded(let entries) = phase { return entries }
        return []
    }

    func load(for peer: PairedPeer) async {
        generation += 1
        let generation = generation
        if entries.isEmpty { phase = .loading }

        do {
            let client = try await connections.client(for: peer, session: session)
            let agent = try await client.agent(target: target)

            // `AgentSessionRefKind` is `id` or `path`. Only `id` is handled:
            // a path would be interpolated whole into a shell command, and
            // validating an arbitrary path is a different and harder problem
            // than validating an identifier. Refusing beats guessing.
            guard let reference = agent.agentSession, reference.kind == "id",
                  let id = reference.value, !id.isEmpty
            else {
                guard generation == self.generation else { return }
                phase = .unavailable("Herdr does not report a session id for this pane, "
                    + "so there is no transcript to find.")
                return
            }
            guard let command = TranscriptCommand.read(sessionID: id) else {
                guard generation == self.generation else { return }
                phase = .unavailable("The session id this host reported is not a shape "
                    + "Bleat will put in a command.")
                return
            }

            // Deliberately not `client`: this is a file the agent wrote, not
            // anything herdr can be asked about.
            let shell = try await connections.shell(for: peer)
            let output = try await shell.run(shell: command)
            guard generation == self.generation else { return }

            let entries = Transcript.entries(from: Data(output.utf8))
            guard !entries.isEmpty else {
                // The command succeeds and prints nothing both when there is no
                // file and when the tail held no prose. Neither is an error.
                phase = .unavailable("No transcript was found for this agent on that Mac.")
                return
            }
            phase = .loaded(entries)
            capturedAt = .now
        } catch is CancellationError {
            // The screen went away, or the mode changed. Nobody to tell.
        } catch {
            // Guarded before `handle`, as everywhere else: a superseded load
            // that finally fails would otherwise tear down the connection a
            // newer, successful one just established.
            guard generation == self.generation else { return }
            await connections.handle(error)
            phase = .failed(ErrorMessage.of(error))
        }
    }
}
