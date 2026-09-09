/// The rules around starting an agent that are not the command itself.
///
/// Kept in `BleatKit` beside `ConnectionPolicy` for the same reason: they are
/// decisions taken from measurement, they are what the UI's behaviour hangs on,
/// and here they can be tested.
public enum AgentStart {
    /// What herdr waits for the agent to become interactive, in milliseconds.
    ///
    /// **herdr's own default, chosen deliberately rather than inherited.** The
    /// temptation is to shorten it so a phone is not blocked for half a minute
    /// on a missing binary — and that is the wrong direction, because it makes
    /// the *ambiguous* outcome more likely. Measured: a `claude` given 3.5s
    /// against a 4.9s cold start timed out, and then came up anyway with
    /// `name: null`. A shorter budget buys a faster answer to the rare failure
    /// by turning ordinary slow successes into "it may or may not have
    /// started", which is the worst thing this screen can say.
    ///
    /// Lengthening it is no better: the 30s is only ever spent when the pane
    /// was free, the name was good, and the binary never appeared — every other
    /// refusal comes back in under 30ms.
    public static let defaultTimeoutMs = 30_000

    /// herdr's bounds, which its `--help` does not print. Below the lower one
    /// it answers `invalid_agent_timeout`.
    public static let minimumTimeoutMs = 3_001
    public static let maximumTimeoutMs = 300_000

    /// Whether a failed start leaves the pane's fate unknown.
    ///
    /// Only `timeout` does. Every other refusal is herdr declining before it
    /// typed anything — measured under 30ms each — so the pane is untouched and
    /// a retry is safe:
    ///
    /// | code | meaning |
    /// |---|---|
    /// | `agent_pane_not_found` | no such pane |
    /// | `agent_pane_busy` | the pane holds an agent, or is running something |
    /// | `invalid_agent_name` | herdr's name rule; see `AgentName` |
    /// | `agent_name_taken` | that name is in use in this session |
    /// | `invalid_agent_timeout` | outside the bounds above |
    ///
    /// `timeout` is the one that means "I stopped waiting", which is not the
    /// same as "it did not happen": the agent may be booting in the pane still.
    public static func isUnknownOutcome(_ error: any Error) -> Bool {
        (error as? HerdrError)?.code == "timeout"
    }

    /// Reads the real cause of a timeout out of the pane.
    ///
    /// **The pane is the only place it is written.** herdr's own answer is
    /// `timed out waiting for agent startup`, which names nothing — while the
    /// pane holds the whole story. Measured, with a kind whose binary is not
    /// installed:
    ///
    /// ```
    /// devin
    /// ➜  bleat-apple devin
    /// zsh: command not found: devin
    /// ➜  bleat-apple git:(main)
    /// ```
    ///
    /// The same shape as `SessionStarter.diagnosis` reading a launch log: the
    /// command that failed cannot report itself, so the place its output went
    /// is fetched and quoted back.
    ///
    /// - Parameter lines: the pane's visible rows, most recent last.
    /// - Returns: the line worth showing, or nil when nothing there explains
    ///   anything. Never a guess — a caller with nil says the honest "it did
    ///   not come up in time" rather than offering an unrelated line as a
    ///   cause, which is the mistake `SessionStarter` made with herdr's own
    ///   startup banner.
    public static func diagnosis(inPane lines: [String], kind: AgentKind) -> String? {
        let interesting = lines
            .map { $0.trimmingCharactersInWhitespace() }
            .filter { !$0.isEmpty }
        // A shell's complaint names the command it could not run, which is the
        // one thing that ties a line in this pane to the agent we asked for.
        // Anything else on screen belongs to whatever the user was doing.
        return interesting.last { line in
            line.contains(kind.rawValue) && Self.shellComplaints.contains { line.contains($0) }
        }
    }

    /// What a shell says when it cannot run something. Three shells' wording,
    /// because sshd's shell is the user's, not ours.
    private static let shellComplaints = [
        "command not found",    // zsh, bash
        "not found",            // sh, dash
        "No such file or directory",
    ]
}

private extension String {
    /// `Foundation`-free, because `BleatKit` models stay importable anywhere.
    func trimmingCharactersInWhitespace() -> String {
        var value = Substring(self)
        while let first = value.first, first.isWhitespace { value = value.dropFirst() }
        while let last = value.last, last.isWhitespace { value = value.dropLast() }
        return String(value)
    }
}
