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
    /// What the agent was doing when the transcript was last read.
    ///
    /// Shown at the foot of the chat, and it is also what decides whether to
    /// keep following: an agent that is `working` will have more to say.
    private(set) var status: AgentStatus?
    /// What the load is doing, for the waiting screen.
    ///
    /// Four round trips — dial, `agent get`, open a shell, read the tail — and
    /// the last one moves a couple of hundred kilobytes. A bare spinner for
    /// several seconds looks identical to a hang, and the first thing anyone
    /// does about a hang is tap something else.
    private(set) var step: String?

    /// The load, owned by the model rather than by a `task` modifier.
    ///
    /// **A view cannot be trusted to hold this.** `ConnectionStore.endpoint` is
    /// observable and publishes the moment a dial lands, which re-renders the
    /// screens above this one — and a `.task` cancelled by that churn leaves the
    /// phase on `.loading` with nothing running and no error, which reads
    /// exactly like a chat that never loads until you touch something else.
    /// Owned here, the work survives the churn and re-entrant callers join it.
    private var loadTask: Task<Void, Never>?

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

    /// Loads, joining a load already in flight rather than starting a second.
    func load(for peer: PairedPeer) async {
        if let loadTask {
            await loadTask.value
            return
        }
        let task = Task { await performLoad(for: peer) }
        loadTask = task
        await task.value
        if loadTask == task { loadTask = nil }
    }

    /// Stops following and abandons any load. Called when the screen goes away.
    func stop() {
        loadTask?.cancel()
        loadTask = nil
    }

    private func performLoad(for peer: PairedPeer) async {
        generation += 1
        let generation = generation
        if entries.isEmpty { phase = .loading }
        step = "Connecting…"
        defer { step = nil }

        do {
            let client = try await connections.client(for: peer, session: session)
            step = "Finding the conversation…"
            let agent = try await client.agent(target: target)
            status = agent.agentStatus

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
            step = "Reading it…"
            let output = try await shell.run(shell: command)
            guard generation == self.generation else { return }

            status = agent.agentStatus
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


extension TranscriptModel {
    /// Follows the agent for as long as the chat is on screen.
    ///
    /// **There is no stream to subscribe to.** `observe` carries terminal frames
    /// and nothing else, and the transcript is a file nobody is watching on the
    /// phone's behalf — so "live" here is a long poll: block until the agent
    /// settles, re-read, block again. `agent wait` is what makes that cheap
    /// enough to do; polling the transcript on a timer would re-transfer a
    /// couple of hundred kilobytes to learn nothing most of the time.
    ///
    /// Cancelled by the `task` modifier when the screen goes away, which closes
    /// the exec channel the wait is holding.
    func follow(for peer: PairedPeer) async {
        // Bounded rather than indefinite. An unbounded `agent wait` pins an
        // exec channel open on the host forever, and a phone that sleeps
        // mid-wait would leave it there.
        let window = 25_000

        while !Task.isCancelled {
            // Only an agent that is *working* is going to produce more. Waiting
            // on an idle one would return instantly and spin this loop.
            guard status == .working else { return }
            do {
                let client = try await connections.client(for: peer, session: session)
                _ = try await client.waitForAgent(
                    target: target, until: [.idle, .blocked, .done], timeoutMs: window
                )
            } catch let error as HerdrError where error.code == "timeout" {
                // Still working. Ask again rather than treating this as news.
                continue
            } catch is CancellationError {
                return
            } catch {
                // Anything else — the pane closed, the connection dropped — is
                // not worth a banner over a chat that is already readable. The
                // reload below would report it anyway if it mattered.
                return
            }
            guard !Task.isCancelled else { return }
            await load(for: peer)
        }
    }
}
