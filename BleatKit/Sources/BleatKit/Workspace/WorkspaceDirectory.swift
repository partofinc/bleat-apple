import Foundation

/// The directory a new workspace's first pane opens in.
///
/// **Validated, never sanitised** — the `Marker(text:)` and `SessionName`
/// rule. Repairing a path would put a workspace somewhere the user did not
/// name, which is precisely the failure this type exists to prevent.
///
/// Unlike `SessionName`, none of these rules are herdr's. herdr accepts
/// everything below without complaint, and that is the problem. Measured
/// against herdr 0.9.0 on the dev Mac, 8 Sept 2026:
///
/// ```
/// $ herdr workspace create --cwd /no/such/dir --label ghost
/// {"result":{"root_pane":{"cwd":"/Users/ravil", …},
///            "workspace":{"label":"ghost", …}}}
/// ```
///
/// Exit 0, `workspace_created`, no error anywhere — and a workspace called
/// `ghost` sitting in the home directory rather than the path that was asked
/// for. The same class of lie as `session delete` answering `{"deleted":true}`
/// over a session that never existed, and it takes the same answer: check
/// rather than trust. Two halves, and both are needed —
///
/// - the shape is refused here, before anything leaves the phone;
/// - the *existence* cannot be, so the caller asks the host — which also
///   answers the second question this type cannot: **what the path really is**.
///   herdr reports a canonical cwd (`/tmp` comes back `/private/tmp`), so a
///   phone comparing its own string against that would call a workspace
///   misplaced that had gone exactly where it was asked. `DirectoryCheck`
///   resolves it the same way herdr does, and
///   `WorkspaceCreated.openedElsewhere(than:)` compares against *that*.
public struct WorkspaceDirectory: Sendable, Hashable {
    /// Why a string is not a usable directory.
    public enum Problem: Sendable, Hashable {
        case empty
        /// **The silent one.** A relative path is resolved against the *server
        /// process's* working directory, not the client's and not the user's
        /// home. Measured: the CLI run from `/tmp` with `--cwd ../` produced a
        /// pane in `/Users/ravil/Developer/rawillk` — the parent of wherever
        /// `herdr server` happened to be started. From a phone that directory
        /// is whatever the SSH session's home was when the session was
        /// launched, which is not a thing the user can reason about.
        case notAbsolute
        /// A leading `~` looks absolute enough to type and is not. Every
        /// argument reaches the host inside single quotes — `SSHTransport.quote`
        /// — so no shell expands it, and herdr then treats it as a directory
        /// that does not exist and falls back to the home directory. The right
        /// answer happens to be where it lands, which is worse than being
        /// wrong: it works until the path is `~/Developer`.
        case tilde

        /// Fit to show under a text field.
        public var message: String {
            switch self {
            case .empty: "Give the workspace a directory."
            case .notAbsolute: "Type the full path, starting with a slash."
            case .tilde: "Type the full path — the phone cannot expand ~ on the host."
            }
        }
    }

    /// Absolute, and without a trailing slash except at the root.
    public let path: String

    public init?(_ path: String) {
        guard Self.problem(with: path) == nil else { return nil }
        self.path = Self.normalising(path)
    }

    /// What is wrong with `path`, or nil if nothing is.
    ///
    /// Separate from the initialiser so a field can say *why* while the user is
    /// still typing, rather than only refusing to proceed.
    public static func problem(with path: String) -> Problem? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .empty }
        if trimmed.hasPrefix("~") { return .tilde }
        if !trimmed.hasPrefix("/") { return .notAbsolute }
        return nil
    }

    /// The last path component, which is the label herdr itself would choose.
    ///
    /// Measured against herdr 0.9.0 — `workspace create` with no `--label`:
    ///
    /// | cwd | label |
    /// |---|---|
    /// | `/Users/ravil/Developer/partofinc/bleat-apple` | `bleat-apple` |
    /// | `/Users/ravil/Developer` | `Developer` |
    /// | `/tmp` | `tmp` |
    /// | `/` | `/` |
    /// | `/Users/ravil` | **`~`** |
    ///
    /// So: the basename, and offering the same string as a placeholder means
    /// the common case needs no typing and the field is not lying about what
    /// leaving it empty will do.
    ///
    /// **Except for the home directory, where this is knowingly wrong.** herdr
    /// abbreviates it to `~`, and the phone cannot tell which path that is —
    /// nothing in a peer record holds the host's home directory, and asking for
    /// it would be a round trip for a placeholder. So `/Users/ravil` suggests
    /// `ravil` while herdr would write `~`. The cost is one wrong hint on one
    /// path, paid only by a user who leaves the label blank there; the fix
    /// costs a shell command on every keystroke. Pinned by a test so it is not
    /// mistaken later for an oversight.
    public var suggestedLabel: String {
        let name = path.split(separator: "/").last.map(String.init) ?? ""
        return name.isEmpty ? path : name
    }

    /// Trailing slashes removed, so `/Users/ravil/` and `/Users/ravil` are one
    /// directory rather than two with different suggested labels. The root
    /// survives, because it is nothing but a slash.
    ///
    /// **Newlines are trimmed as well as spaces**, because the likeliest way
    /// this field is filled is a paste from a terminal's `pwd`, which carries
    /// one. Kept, it passes every check here and then fails on the host — and
    /// the message would name the directory without the newline in it, so the
    /// user is told there is no such directory about one that plainly exists.
    ///
    /// This is a trim, not a canonicalisation: `/tmp` stays `/tmp`, and the
    /// host resolves it. See `DirectoryCheck`.
    private static func normalising(_ path: String) -> String {
        var trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.count > 1 && trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed
    }
}
