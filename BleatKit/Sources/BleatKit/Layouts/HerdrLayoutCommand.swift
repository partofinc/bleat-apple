import Foundation

/// What the phone asks `herdr-layout` to do on a Mac, as one shell command,
/// and how its answer is read.
///
/// **Only what makes sense away from the Mac**: list, restore, save an open
/// layout as it is now, close, and rename (asked for by Ravil after the
/// first restore from a phone, 15 Nov 2026). `show` moves the Mac's own
/// window, which nobody at the phone is looking at; delete, save and add are
/// left to the Mac.
public enum HerdrLayoutCommand: Sendable, Equatable {
    case list
    case restore(String)
    case update(String)
    /// `force` closes even while agents in it are working.
    case close(String, force: Bool)
    case rename(String, to: String)

    /// The script's own arguments.
    public var arguments: [String] {
        switch self {
        case .list: ["list", "--json"]
        case .restore(let name): ["restore", name]
        case .update(let name): ["update", name]
        case .close(let name, let force): ["close", name] + (force ? ["--force"] : [])
        case .rename(let name, let new): ["rename", name, new]
        }
    }

    /// The script, for `/bin/sh`. No single quote anywhere in it: it travels
    /// inside them, as `HostStatusProbe.script` does.
    ///
    /// - **`PATH` gets `~/.local/bin`, and the directory `hc` was found in.**
    ///   The script calls `hc` and `herdr-app` by bare name, and an SSH
    ///   login's `PATH` on a Mac has neither (see `HerdrCoreLookup`). `$1` is
    ///   added only when set: an empty entry in `PATH` is the working directory.
    /// - **It outlives the phone.** A restore starts a Claude per pane and
    ///   takes a while, and iOS drops the socket when the app leaves the
    ///   front. Written straight to the channel, the script's first line
    ///   after that would fail on a closed pipe and stop it half way, with
    ///   some spaces open and the rest not. So its output goes to files, and
    ///   is sent once it has finished; `HUP` is ignored for the same reason.
    /// - **`HUP` ignored is passed on to what the script starts** (kept from
    ///   review): that is only the `caffeinate` keeping the Mac awake while
    ///   Herdr.app runs, which ends with Herdr.app. The panes' Claude
    ///   sessions are started by Herdr.app through herdr-core, not by it.
    /// - The exit status is the script's, so a refusal still throws
    ///   `ShellError` with the script's words on stderr.
    static let script = """
        trap "" HUP
        PATH="$HOME/.local/bin:$PATH"
        [ -n "$1" ] && PATH="$1:$PATH"
        shift
        o=$(mktemp) && e=$(mktemp) || exit 70
        herdr-layout "$@" >"$o" 2>"$e"
        s=$?
        cat "$o"
        cat "$e" >&2
        rm -f "$o" "$e"
        exit $s
        """

    /// The command for the login shell to run.
    ///
    /// - Parameter hcPath: where herdr-core was found on the host, if known;
    ///   its directory goes on `PATH`.
    public func command(hcPath: String?) -> String {
        let directory = hcPath.map { ($0 as NSString).deletingLastPathComponent } ?? ""
        return (["/bin/sh", "-c", "'\(Self.script)'", "sh", SSHTransport.quote(directory)]
            + arguments.map(SSHTransport.quote)).joined(separator: " ")
    }

    /// The host has no `herdr-layout`: the shell's "not found", status 127,
    /// naming the script. **Only when it names it** (from review): `env`
    /// also exits 127 when the script is there and `python3` is not, and
    /// that host has the script, which cannot run.
    public static func isMissing(_ error: any Error) -> Bool {
        guard let error = error as? ShellError, error.exitCode == 127 else { return false }
        return error.stderr.contains("herdr-layout")
    }

    /// `close` refused because agents in the layout are still working:
    /// "N agent(s) still working in …: wait, or close anyway with --force".
    /// Matched on the script's own words, which this project also owns.
    public static func isStillWorking(_ error: any Error) -> Bool {
        (error as? ShellError)?.stderr.contains("still working in") ?? false
    }

    /// Why the script said no, in its words: every line of stderr, without
    /// the `herdr-layout: ` its refusals start with.
    public static func refusal(in error: ShellError) -> String {
        let lines = error.stderr.split(whereSeparator: \.isNewline).map {
            $0.hasPrefix("herdr-layout: ") ? $0.dropFirst("herdr-layout: ".count) : $0
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What it did, from the last line it printed: "restored Clinic: 5/5
    /// space(s), 5 pane(s), 5 Claude (5 by session id, 0 with --continue)".
    public static func summary(inOutput output: String) -> String? {
        output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
    }
}
