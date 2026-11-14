import Foundation

/// The two shell questions starting a terminal needs answered first: where
/// the user's home is, and where a directory really is, if it exists.
///
/// **Asked, not left to the core.** `terminal.run` expands no `~`, and a
/// directory that does not exist fails as `cannot start "/bin/sh": No such
/// file or directory` — the shell blamed for the directory (live, hc 0.1.20).
/// Checking first turns that into "no such directory".
public enum HostDirectory {
    /// Prints `$HOME`, through `/bin/sh` so a fish login shell only passes a
    /// string.
    public static let home = #"/bin/sh -c 'printf "%s" "$HOME"'"#

    /// Prints the directory's physical path, or `no` when it is not one;
    /// never fails.
    ///
    /// **`/bin/pwd -P`, not the shell's `pwd`.** On a Mac's case-insensitive
    /// disk `cd ~/developer` works, and the shell's own `pwd -P` says
    /// `developer` back; `/bin/pwd -P` asks the system and says `Developer`,
    /// as on disk (live, 13 Nov 2026). Symlinks come out resolved too
    /// (`/tmp` is `/private/tmp`). That spelling is what Herdr.app's space
    /// folders are matched against (`HerdrSpace.spaces(for:in:)`).
    public static func physical(_ path: String) -> String {
        let script = "cd -P -- \(SSHTransport.quote(path)) 2>/dev/null || { echo no; exit 0; }; /bin/pwd -P 2>/dev/null || pwd -P"
        return "/bin/sh -c " + SSHTransport.quote(script)
    }

    /// The home path in `home`'s output, or nil when it is not absolute.
    ///
    /// **The last line, not the whole output.** A host whose shell startup
    /// prints — a motd, an `echo` in `.bashrc` — puts that before the answer,
    /// as the herdr-core lookup found (`LoginShellLookup.path(inOutput:)`).
    public static func home(inOutput output: String) -> String? {
        guard let path = lastLine(of: output), path.hasPrefix("/") else { return nil }
        return path
    }

    /// The path in `physical`'s output, or nil when it is not a directory;
    /// read off its last line for the same reason. Taking the whole output
    /// refused every directory on a host whose shell prints on startup.
    public static func physical(inOutput output: String) -> String? {
        guard let path = lastLine(of: output), path.hasPrefix("/") else { return nil }
        return path
    }

    private static func lastLine(of output: String) -> String? {
        output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
    }
}
