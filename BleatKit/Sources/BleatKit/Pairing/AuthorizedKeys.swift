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

    /// A marker for one enrollment: `bleat-enroll-<16 hex>`.
    ///
    /// Hex only, and generated here rather than taken from a caller, because
    /// the marker is interpolated into a shell command and into a key comment.
    /// Nothing that reaches either place should be able to carry a quote.
    public static func enrollmentMarker(id: String? = nil) -> String {
        "\(markerPrefix)-enroll-\(sanitizeMarker(id ?? randomHex()))"
    }

    /// A marker for a device's durable key: `bleat-device-<16 hex>`.
    public static func deviceMarker(id: String? = nil) -> String {
        "\(markerPrefix)-device-\(sanitizeMarker(id ?? randomHex()))"
    }

    /// Appends a key, creating `~/.ssh` with the permissions sshd insists on.
    ///
    /// `StrictModes` is on by default, and it makes sshd **silently ignore**
    /// `authorized_keys` when `~/.ssh` is group- or world-writable. Without the
    /// `chmod`s a first-time pairing on a fresh account writes a correct file
    /// that authenticates nothing, and the failure gives no hint why.
    public static func appendCommand(line: String) -> String {
        let quoted = quote(line)
        return "mkdir -p ~/.ssh && chmod 700 ~/.ssh && "
            + "printf '%s\\n' \(quoted) >> \(path) && chmod 600 \(path)"
    }

    /// Removes every line carrying `marker`.
    ///
    /// Writes back through `cat > "$f"` rather than `mv`: the original file
    /// keeps its inode, owner and mode, whereas moving a temp file over it
    /// would carry `mktemp`'s instead — and a mode sshd dislikes silently
    /// disables the whole file. `|| true` because `grep -v` exits 1 when it
    /// emits nothing, which is a normal outcome here, not a failure.
    public static func removeCommand(marker: String) -> String {
        let safe = quote(sanitizeMarker(marker))
        return "f=\(path); t=$(mktemp) && { grep -v -F -- \(safe) \"$f\" || true; } > \"$t\" "
            + "&& cat \"$t\" > \"$f\" && rm -f \"$t\""
    }

    /// True when a line carrying `marker` is present. Prints `yes` or `no`
    /// rather than relying on an exit code, since the caller reads stdout.
    public static func containsCommand(marker: String) -> String {
        let safe = quote(sanitizeMarker(marker))
        return "grep -q -F -- \(safe) \(path) 2>/dev/null && echo yes || echo no"
    }

    // MARK: - Safety

    /// Keeps a marker to `[A-Za-z0-9._-]`, which is what makes it safe both to
    /// interpolate into a shell command and to append to a key line.
    static func sanitizeMarker(_ marker: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        return String(marker.filter(allowed.contains))
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
