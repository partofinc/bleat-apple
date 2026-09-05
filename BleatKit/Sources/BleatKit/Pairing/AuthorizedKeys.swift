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

    /// The `authorized_keys` line for a single-use enrollment key.
    ///
    /// Two option prefixes carry the safety, and both are enforced by **sshd**
    /// rather than by Bleat:
    ///
    /// - `restrict` turns off port forwarding, agent forwarding, X11, PTY and
    ///   user rc. Exec channels still work, which is all pairing needs —
    ///   verified against a real sshd.
    /// - `expiry-time` makes sshd refuse the key outright once the moment
    ///   passes. This is the layer that matters: a signal handler cannot run
    ///   after `SIGKILL`, and nothing runs after a power cut, so without a
    ///   host-enforced deadline an abandoned enrollment key would sit in
    ///   `authorized_keys` forever. Verified: sshd accepts the key before the
    ///   time and answers `Permission denied` after it.
    ///
    /// The timestamp is UTC with a `Z` suffix, which sshd accepts, because a
    /// local-time deadline would shift under DST.
    public static func enrollmentLine(
        publicKeyLine: String,
        marker: Marker,
        expiresAt: Date
    ) -> String {
        let stamp = expiryStamp(expiresAt)
        return #"restrict,expiry-time="\#(stamp)" \#(publicKeyLine) \#(marker.value)"#
    }

    /// `YYYYMMDDHHMMSSZ` — the UTC form sshd accepts.
    static func expiryStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMddHHmmss'Z'"
        return formatter.string(from: date)
    }

    /// Lists the marker of every Bleat device key in the file, one per line.
    ///
    /// Pairing succeeds when a **new** one appears, not when any exists: a host
    /// with a phone already paired has a device key from the start, so
    /// "a device key is present" would be true before the new phone did
    /// anything and would turn any disappearance of the enrollment line into a
    /// false success.
    public static func listDeviceMarkersCommand() -> String {
        let pattern = quote("[[:space:]]\(markerPrefix)-device-[A-Za-z0-9._-]+$")
        return "grep -o -E -- \(pattern) \(path) 2>/dev/null | tr -d '[:blank:]' || true"
    }

    /// Removes **every** Bleat enrollment key, whoever left it.
    ///
    /// Run before minting a new one. In-process cleanup cannot be complete:
    /// `SIGKILL` and power loss leave no chance to tidy up, so a previous run's
    /// key can outlive it. `expiry-time` already makes such a key unusable, but
    /// unusable is not the same as gone — this keeps the file honest, and means
    /// a user reading their own `authorized_keys` sees only keys that mean
    /// something.
    ///
    /// Device keys are untouched: the pattern requires the `-enroll-` infix.
    public static func sweepEnrollmentsCommand() -> String {
        let pattern = quote("[[:space:]]\(markerPrefix)-enroll-[A-Za-z0-9._-]+$")
        // A conditional rather than an early `exit`: this runs inside the lock
        // wrapper, and exiting would leave the lock directory behind.
        return locked(
            "f=\(path); if [ -f \"$f\" ]; then t=$(mktemp) && "
            + "{ grep -v -E -- \(pattern) \"$f\" || true; } > \"$t\" "
            + "&& cat \"$t\" > \"$f\" && rm -f \"$t\"; fi"
        )
    }

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
        return locked(
            "mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch \(path) && "
            + "{ [ ! -s \(path) ] || [ -z \"$(tail -c1 \(path))\" ] || printf '\\n' >> \(path); } && "
            + "printf '%s\\n' \(quoted) >> \(path) && chmod 600 \(path)"
        )
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
        // The `-f` guard matters on a fresh account: without it a removal that
        // runs before any key was written creates an empty authorized_keys at
        // the umask default, typically 0644 — a mode the append path takes
        // care to avoid, since sshd silently ignores a too-permissive file.
        return locked(
            "f=\(path); if [ -f \"$f\" ]; then t=$(mktemp) && "
            + "{ grep -v -E -- \(pattern) \"$f\" || true; } > \"$t\" "
            + "&& cat \"$t\" > \"$f\" && rm -f \"$t\"; fi"
        )
    }

    /// Removes every line carrying this exact public key, whatever its comment.
    ///
    /// **The phone removes the enrollment line by key, because it never learns
    /// the marker.** The marker is minted on the host and the QR does not carry
    /// it — a field that exists only so the *other* side can name a line would
    /// be paid for in QR modules on every pairing. The key is already in the
    /// phone's hands: it arrived as a seed and is the thing being revoked.
    ///
    /// Also used before installing the device key, so re-pairing a phone that
    /// is already known replaces its line instead of appending a second copy of
    /// the same key.
    ///
    /// - Parameter publicKeyLine: An OpenSSH `<algorithm> <base64> [comment]`
    ///   line. Only the blob is matched — options and comments differ between
    ///   how a key was installed and how it is being removed.
    /// - Returns: nil when the line will not parse, rather than a command that
    ///   matches something else. `grep -v` with a pattern built from garbage is
    ///   how an `authorized_keys` file gets truncated.
    public static func removeKeyCommand(publicKeyLine: String) -> String? {
        guard let pattern = keyPattern(publicKeyLine: publicKeyLine) else { return nil }
        // Same read-modify-write as `removeCommand`, and the same reasons for
        // every part of it: `cat` back rather than `mv` so the file keeps its
        // inode and mode, `|| true` because `grep -v` exits 1 when it emits
        // nothing, and the `-f` guard so a removal on a fresh account does not
        // create an `authorized_keys` at the umask default.
        return locked(
            "f=\(path); if [ -f \"$f\" ]; then t=$(mktemp) && "
            + "{ grep -v -E -- \(pattern) \"$f\" || true; } > \"$t\" "
            + "&& cat \"$t\" > \"$f\" && rm -f \"$t\"; fi"
        )
    }

    /// True when a line carrying this exact public key is present.
    ///
    /// Both halves of the swap are verified with it. Installing the device key
    /// and *believing* it landed is how a phone deletes the only credential it
    /// has and discovers on the next launch that it cannot connect.
    public static func containsKeyCommand(publicKeyLine: String) -> String? {
        guard let pattern = keyPattern(publicKeyLine: publicKeyLine) else { return nil }
        return "grep -q -E -- \(pattern) \(path) 2>/dev/null && echo yes || echo no"
    }

    /// Matches the key's blob as a whitespace-delimited field.
    ///
    /// Delimited rather than a bare substring: base64 is not self-delimiting,
    /// and a shorter key's encoding can appear inside a longer one's. The blob
    /// is what gets matched rather than the whole line, because the line
    /// differs between the two ends — the host writes the enrollment key with
    /// `restrict,expiry-time=…` in front and a marker behind, and the phone has
    /// neither.
    static func keyPattern(publicKeyLine: String) -> String? {
        guard let parsed = SSHPublicKeyLine(line: publicKeyLine) else { return nil }
        let blob = parsed.blob.base64EncodedString()
        // base64's alphabet is `A-Za-z0-9+/=`, of which only `+` is an ERE
        // metacharacter — but escaping by construction rather than by that
        // observation, so a change of encoding cannot quietly turn the pattern
        // into a wildcard.
        let escaped = String(blob.flatMap { character -> String in
            "^$.[]|()*+?{}\\".contains(character) ? "\\\(character)" : "\(character)"
        })
        return quote("[[:space:]]\(escaped)([[:space:]]|$)")
    }

    /// True when a line carrying `marker` is present. Prints `yes` or `no`
    /// rather than relying on an exit code, since the caller reads stdout.
    /// Anchored the same way as `removeCommand`, so the two always agree.
    public static func containsCommand(marker: Marker) -> String {
        let pattern = quote("[[:space:]]\(regexEscape(marker.value))$")
        return "grep -q -E -- \(pattern) \(path) 2>/dev/null && echo yes || echo no"
    }

    /// Serialises a mutating command against the other side of the pairing.
    ///
    /// Removal is a read-modify-write (`grep -v` to a temp, then `cat` back)
    /// while the phone concurrently appends. If the append lands between the
    /// read and the write-back it is lost — the phone reports success and can
    /// never connect, and the host prints a timeout that looks unrelated. That
    /// window is exactly the one `expiryGrace` keeps alive on purpose, so it is
    /// not hypothetical.
    ///
    /// `mkdir` is the mutex because it is atomic on every POSIX filesystem and
    /// needs no tool that might be missing — `flock(1)` does not ship on macOS.
    ///
    /// **Staleness is the lock's age, never how long this caller has waited.**
    /// Breaking the lock after N failed attempts looks equivalent and is not:
    /// under contention every waiter eventually reaches N and tears the lock
    /// out from under a live holder, which destroys mutual exclusion precisely
    /// when it is needed. Measured with 200 concurrent appends against 200
    /// removals, the attempt-count version kept 16 of 200 keys and lost the
    /// user's own; judging by age keeps all 200. A lock older than a minute
    /// belongs to a process that died holding it — every operation here is
    /// sub-millisecond — so breaking that one cannot interrupt anybody.
    ///
    /// The wrapped command must not call `exit`, or the lock would outlive it.
    static func locked(_ command: String) -> String {
        let lock = "~/.ssh/.bleat-lock"
        return "mkdir -p ~/.ssh 2>/dev/null; "
            + "while ! mkdir \(lock) 2>/dev/null; do "
            // A failed mkdir means contention only if the lock is actually
            // there. When it is not, the directory is unwritable or read-only,
            // and retrying can never succeed — the loop would spin forever on
            // exactly the failure the user most needs told about. Verified: an
            // `~/.ssh` with mode 500 hung the tool indefinitely before this.
            + "if [ ! -d \(lock) ]; then "
            + "echo \"cannot create lock \(lock): is ~/.ssh writable?\" >&2; exit 75; fi; "
            + "[ -n \"$(find \(lock) -maxdepth 0 -mmin +1 2>/dev/null)\" ] "
            + "&& rmdir \(lock) 2>/dev/null; "
            + "sleep 0.05; done; "
            + "{ \(command); }; r=$?; rmdir \(lock) 2>/dev/null; exit $r"
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
