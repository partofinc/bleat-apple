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

    /// Whether a failed start proves that **nothing was typed into the pane**.
    ///
    /// This is the question, and it is deliberately not "was it a timeout".
    /// `agent start` blocks on the host for up to thirty seconds while herdr
    /// types the executable in and waits — so anything that goes wrong *to the
    /// connection* during that window says nothing about whether the command
    /// ran, and an agent may well be sitting in that pane. Only herdr
    /// answering, in its own error envelope, settles it.
    ///
    /// The same shape as `ConnectionPolicy.isRefusalByHost`, with one extra
    /// clause: `timeout` is a `HerdrError` that means "I stopped waiting", and
    /// that is emphatically not a refusal. Measured — a `claude` given 3.5s
    /// against a 4.9s cold start timed out and then came up anyway, nameless.
    ///
    /// Everything else herdr says is a refusal made **before it typed
    /// anything**, each measured under 30ms:
    ///
    /// | code | meaning |
    /// |---|---|
    /// | `agent_pane_not_found` | no such pane |
    /// | `agent_pane_busy` | the pane holds an agent, or is running something |
    /// | `invalid_agent_name` | herdr's name rule; see `AgentName` |
    /// | `agent_name_taken` | that name is in use in this session |
    /// | `invalid_agent_timeout` | outside the bounds above |
    ///
    /// So: a non-`timeout` `HerdrError` is safe to retry, and **everything
    /// else has to be checked** — a dropped connection and a reply this build
    /// could not read both leave an agent that probably started.
    ///
    /// **`agent_not_ready` is the second exception, and it reached a device.**
    /// It is what herdr answers when the agent came up and stopped at a dialog
    /// — the Claude Code workspace-trust prompt, which is what a *new*
    /// directory always produces, so it is the common case for an agent started
    /// in a workspace the phone just made. Measured 12 Sept 2026 in an isolated
    /// session, against a directory Claude Code had never seen:
    ///
    /// ```
    /// {"error":{"code":"agent_not_ready",
    ///           "message":"agent probe is blocked during startup and is not ready for prompts"}}
    /// ```
    ///
    /// exit 1, in **3.9s** — and `agent list` then held `name: "probe"`,
    /// `launch_pending: true`. So the agent exists *and is named*: herdr
    /// created it, typed the executable, watched it block, and reported an
    /// error over something that had entirely succeeded.
    ///
    /// Read as a refusal — which it was, because the code is not `timeout` —
    /// the phone told the user nothing had happened and left the button armed
    /// over an agent that was sitting there waiting to be answered. Both
    /// retries are dead ends, measured: the same name gives
    /// `agent_name_taken`, any other name gives `agent_pane_busy`.
    public static func isRefusalBeforeTyping(_ error: any Error) -> Bool {
        guard let herdr = error as? HerdrError else { return false }
        return herdr.code != "timeout" && herdr.code != blockedDuringStartupCode
    }

    /// herdr's code for "it started, and it is waiting at a dialog".
    public static let blockedDuringStartupCode = "agent_not_ready"

    /// Whether the agent started and stopped at a dialog.
    ///
    /// Kept apart from `timeout` although both mean "the pane is not untouched",
    /// because what the user should do differs and that is the whole point. A
    /// timeout is genuinely *ambiguous* — herdr stopped waiting and may or may
    /// not have left an agent — so it is followed by reading the host back. This
    /// is not ambiguous at all: herdr says the agent is blocked during startup,
    /// and it named it. The remedy is to answer the dialog, which `PaneKeyBar`
    /// can now do, so the screen's job is to offer the way there rather than to
    /// investigate.
    public static func isBlockedDuringStartup(_ error: any Error) -> Bool {
        (error as? HerdrError)?.code == blockedDuringStartupCode
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
        // A shell's complaint names the command it could not run, which is the
        // one thing that ties a line in this pane to the agent we asked for.
        // Anything else on screen belongs to whatever the user was doing.
        lines
            .map { $0.trimmingCharactersInWhitespace() }
            .filter { !$0.isEmpty }
            .last { line in
                Self.shellComplaints.contains { line.contains($0) } && names(kind, in: line)
            }
    }

    /// Whether `line` names `kind` **as the command**, rather than merely
    /// containing its letters.
    ///
    /// **A substring test is not good enough here, and the short kinds are why.**
    /// herdr offers `pi`, `amp`, `agy`, `omp` and `kimi`, and one of the
    /// complaints below is the very generic "No such file or directory" — so
    /// `cat: /Users/x/api/keys: No such file or directory`, left on screen by
    /// something the user did earlier, would be quoted back as the reason `pi`
    /// failed to start. That breaks the promise this function's own
    /// documentation makes.
    ///
    /// Every shell puts the offending command in its own colon-separated field:
    ///
    /// ```
    /// zsh:  command not found: devin
    /// bash: devin: command not found
    /// sh: 1: devin: not found
    /// env: devin: No such file or directory
    /// ```
    ///
    /// So the field has to *be* the kind — or end in it, for the path form a
    /// shell sometimes echoes. `api` is then not `pi`, and nothing is guessed.
    private static func names(_ kind: AgentKind, in line: String) -> Bool {
        line.split(separator: ":").contains { field in
            let value = String(field).trimmingCharactersInWhitespace()
            return value == kind.rawValue || value.hasSuffix("/" + kind.rawValue)
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
