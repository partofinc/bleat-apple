import Foundation

/// Builds the shell one-liners that add and remove keys in a host's
/// `~/.ssh/authorized_keys`.
///
/// Commands rather than file I/O because both callers reach the file the same
/// way — over an SSH exec channel. The phone uses these to install its own key
/// and delete the enrollment key it arrived on; the console tool runs the same
/// strings locally, so there is one definition of what a Bleat entry looks like
/// and one definition of how it is removed.
public enum AuthorizedKeys {
    public static let path = "~/.ssh/authorized_keys"

    /// Every entry Bleat writes carries a marker in its comment so it can be
    /// found again and removed without touching keys the user put there.
    public static let markerPrefix = "bleat"

    /// A validated marker.
    ///
    /// A type rather than a `String` because an unusable marker is not a
    /// cosmetic problem: `grep -v -F -- ''` matches **every** line, so a marker
    /// that sanitised down to nothing would replace the user's entire
    /// `authorized_keys` with an empty file — destroying keys Bleat never wrote
    /// and locking them out of their own machine. Making the empty case
    /// unrepresentable is the only fix that cannot be forgotten at a call site.
    public struct Marker: Sendable, Hashable, CustomStringConvertible {
        public let value: String

        /// Fails when `id` contains nothing usable. Callers that generate their
        /// own id get a non-optional result from `enrollment()`/`device()`.
        init?(kind: String, id: String) {
            let cleaned = AuthorizedKeys.sanitizeMarker(id)
            guard !cleaned.isEmpty else { return nil }
            self.value = "\(AuthorizedKeys.markerPrefix)-\(kind)-\(cleaned)"
        }

        public var description: String { value }
    }

    /// A marker for one enrollment: `bleat-enroll-<16 hex>`.
    ///
    /// Hex, and generated here rather than taken from a caller, because the
    /// marker is interpolated into a shell command and into a key comment.
    /// Nothing reaching either place should be able to carry a quote.
    public static func enrollmentMarker() -> Marker {
        Marker(kind: "enroll", id: randomHex())!   // randomHex is always usable
    }

    /// A marker for a device's durable key: `bleat-device-<16 hex>`.
    public static func deviceMarker() -> Marker {
        Marker(kind: "device", id: randomHex())!
    }

    /// Rebuilds a marker from a caller-supplied id, e.g. one read back off a
    /// host. Nil when nothing usable survives sanitising.
    public static func enrollmentMarker(id: String) -> Marker? { Marker(kind: "enroll", id: id) }
    public static func deviceMarker(id: String) -> Marker? { Marker(kind: "device", id: id) }

    /// Appends a key, creating `~/.ssh` with the permissions sshd insists on
    /// and guaranteeing the new entry starts on its own line.
    ///
    /// Two silent failures are guarded here, and both produce a file that looks
    /// right and authenticates nothing:
    ///
    /// - `StrictModes` is on by default, and it makes sshd **ignore**
    ///   `authorized_keys` entirely when `~/.ssh` or the file is group- or
    ///   world-writable. Hence the `chmod`s.
    /// - A plain `>>` appends with no leading newline, and `authorized_keys`
    ///   files written by hand or by other tools frequently lack a trailing
    ///   one. Without the guard the new key is glued onto the end of the last
    ///   existing key, which kills **both**: the user's previous key stops
    ///   authenticating and the newly paired device never works.
    ///
    /// `$(tail -c1 …)` strips a trailing newline, so it comes back empty
    /// exactly when the file already ends in one.
    public static func appendCommand(line: String) -> String {
        let quoted = quote(line)
        return "mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch \(path) && "
            + "{ [ ! -s \(path) ] || [ -z \"$(tail -c1 \(path))\" ] || printf '\\n' >> \(path); } && "
            + "printf '%s\\n' \(quoted) >> \(path) && chmod 600 \(path)"
    }

    /// Removes every line whose comment ends with `marker`.
    ///
    /// Anchored at end-of-line and preceded by whitespace rather than matched
    /// as a bare substring: markers share a prefix namespace and take a
    /// caller-supplied id, so an unanchored `bleat-device-01` would also strip
    /// `bleat-device-012` — another device's key.
    ///
    /// Writes back through `cat > "$f"` rather than `mv`: the original file
    /// keeps its inode, owner and mode, whereas moving a temp file over it
    /// would carry `mktemp`'s instead — and a mode sshd dislikes silently
    /// disables the whole file. `|| true` because `grep -v` exits 1 when it
    /// emits nothing, which is a normal outcome here, not a failure.
    public static func removeCommand(marker: Marker) -> String {
        let pattern = quote("[[:space:]]\(regexEscape(marker.value))$")
        return "f=\(path); t=$(mktemp) && { grep -v -E -- \(pattern) \"$f\" || true; } > \"$t\" "
            + "&& cat \"$t\" > \"$f\" && rm -f \"$t\""
    }

    /// True when a line carrying `marker` is present. Prints `yes` or `no`
    /// rather than relying on an exit code, since the caller reads stdout.
    /// Anchored the same way as `removeCommand`, so the two always agree.
    public static func containsCommand(marker: Marker) -> String {
        let pattern = quote("[[:space:]]\(regexEscape(marker.value))$")
        return "grep -q -E -- \(pattern) \(path) 2>/dev/null && echo yes || echo no"
    }

    // MARK: - Safety

    /// Keeps a marker to `[A-Za-z0-9._-]`, which is what makes it safe both to
    /// interpolate into a shell command and to append to a key line.
    static func sanitizeMarker(_ marker: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        return String(marker.filter(allowed.contains))
    }

    /// `.` is the only regex metacharacter that survives `sanitizeMarker`;
    /// outside a bracket expression `-` and `_` are literal.
    static func regexEscape(_ value: String) -> String {
        value.replacingOccurrences(of: ".", with: #"\."#)
    }

    static func randomHex(bytes: Int = 8) -> String {
        (0..<bytes).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    /// Single-quotes for `sh`, ending and reopening the quote around any quote
    /// in the value. Same rule as `SSHTransport.quote`.
    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
