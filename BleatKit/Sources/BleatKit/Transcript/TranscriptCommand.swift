import Foundation

/// Finds and tails an agent's own transcript on the host.
///
/// Plain shell rather than a herdr command, because herdr has none: it knows
/// only what was drawn on the terminal. This runs over the same `ShellRunner`
/// pairing uses.
///
/// **The whole point is that the filtering happens on the host.** The transcript
/// measured on the dev Mac was 183MB for one session, with single records up to
/// 1.3MB — utterly untransferable to a phone. But the conversation inside it was
/// under 7% of the records and the median record was 548 bytes, so a `tail` and
/// two filters reduce it to a payload worth sending before anything crosses the
/// wire. Nothing here reads the whole file.
public enum TranscriptCommand {
    /// Where Claude Code keeps transcripts, one directory per project.
    ///
    /// **Located by glob rather than by computing the directory name.** The
    /// directory is the project's path with the separators replaced, and
    /// reproducing that escaping in Swift would be a rule this code guessed at
    /// and could silently get wrong for one path in twenty. The session id is
    /// already unique across every project, so the glob is both simpler and more
    /// robust than the derivation.
    private static let root = #""$HOME"/.claude/projects"#

    /// - Parameters:
    ///   - sessionID: `agent_session.value` from `agent get`.
    ///   - turns: How many matching records to return, newest last.
    ///   - scanning: How far back through the file to look for them. Records
    ///     are mostly *not* conversation, so this has to be several times
    ///     `turns` — measured at about 7% in a real file.
    /// - Returns: `nil` when the id is not a shape that may be put in a shell
    ///   command. See `isSafe`.
    public static func read(sessionID: String, turns: Int = 120, scanning records: Int = 1500) -> String? {
        guard isSafe(sessionID) else { return nil }
        let path = "\(root)/*/'\(sessionID)'.jsonl"
        // `command ls -t … | head -1` because the same session id can in
        // principle appear under two project directories; the most recently
        // written is the live one.
        //
        // **`command` is load-bearing, not decoration.** sshd runs this through
        // the user's login shell, and zsh sources `.zshenv` for every
        // non-interactive shell — so a user's `alias ls=eza` is in scope here.
        // eza's `-t` takes a field argument, which swallows the path and
        // returns nothing, so the transcript is silently "not found" on exactly
        // the machines whose owners customise their shell. Found the hard way:
        // this repository's own dev Mac has that alias, and the first version
        // of this command returned zero bytes against a file that was there.
        // `command` skips aliases and functions and runs the real binary.
        //
        // Then, in order: cut to a bounded number of records; drop the giant
        // ones; keep only conversational records.
        //
        // **The size bound is 128KB, not 16KB.** Measured on a live transcript:
        // of 635 conversational records in the last 1500, seven exceeded 16KB —
        // and they were long pasted prompts and long answers, which is exactly
        // what the chat exists to show. They vanished with nothing on screen to
        // say a turn was missing. Attachments and tool results are what this is
        // aimed at, and the `grep` below already excludes most of them; the
        // bound only has to stay under the 1.3MB records that make the file
        // untransferable. The `grep` is a cheap pre-filter and not
        // the parser — the phone parses the JSON properly, because a substring
        // test cannot tell a top-level type from the same bytes inside a tool
        // result.
        //
        // `|| true` because every stage here exits non-zero on "nothing
        // matched", and an agent with no transcript is a normal answer rather
        // than a failed command — the caller distinguishes them by the output
        // being empty.
        return """
            f=$(command ls -t \(path) 2>/dev/null | head -1); \
            [ -n "$f" ] && tail -n \(records) "$f" \
            | awk 'length($0) < 131072' \
            | grep -E '"type":"(user|assistant)"' \
            | tail -n \(turns) || true
            """
    }

    /// Whether an id may be interpolated into a shell command.
    ///
    /// **It is validated, not escaped**, for the reason `AuthorizedKeys.Marker`
    /// is: this value arrives as JSON *from the host* and is then spliced into a
    /// command that host will run, so the only safe posture is to refuse
    /// anything that is not obviously an identifier. It is single-quoted as well
    /// — the charset already excludes a quote, so the two are belt and braces
    /// rather than one standing in for the other.
    ///
    /// `..` is refused separately: every character in it is allowed, and a path
    /// component of `..` inside a glob is how a lookup climbs out of
    /// `~/.claude/projects`.
    static func isSafe(_ id: String) -> Bool {
        guard (1...128).contains(id.count), !id.contains("..") else { return false }
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        guard id.allSatisfy(allowed.contains) else { return false }
        // A leading dash would be read as an option by `ls`, and a leading dot
        // makes a hidden file rather than the one that was asked for.
        return !id.hasPrefix("-") && !id.hasPrefix(".")
    }
}
