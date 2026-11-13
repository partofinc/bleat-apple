import Foundation

/// The two shell questions starting a terminal needs answered first: where
/// the user's home is, and whether a directory exists.
///
/// **Asked, not left to the core.** `terminal.run` expands no `~`, and a
/// directory that does not exist fails as `cannot start "/bin/sh": No such
/// file or directory` — the shell blamed for the directory (live, hc 0.1.20).
/// Checking first turns that into "no such directory".
public enum HostDirectory {
    /// Prints `$HOME`, through `/bin/sh` so a fish login shell only passes a
    /// string.
    public static let home = #"/bin/sh -c 'printf "%s" "$HOME"'"#

    /// Prints `yes` when `path` is a directory, `no` otherwise; never fails.
    public static func exists(_ path: String) -> String {
        "/bin/sh -c " + SSHTransport.quote("[ -d \(SSHTransport.quote(path)) ] && echo yes || echo no")
    }

    /// The home path in `home`'s output, or nil when it is not absolute.
    public static func home(inOutput output: String) -> String? {
        let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.hasPrefix("/") ? path : nil
    }
}
