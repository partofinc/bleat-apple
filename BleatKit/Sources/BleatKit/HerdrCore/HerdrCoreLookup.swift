import Foundation

/// The two shell questions that find herdr-core on a host, and how their
/// answers are read.
///
/// **Two commands, not one.** Finding `hc` needs the user's login shell, which
/// may be fish; asking it for the version too would mean POSIX variable
/// assignment inside that shell. So the login shell only runs `command -v`,
/// exactly as `LoginShellLookup` does, and the version is asked of the absolute
/// path it gave, which every shell runs the same way.
public enum HerdrCoreLookup {
    /// `command -v hc` through a login shell. Empty output means absent; see
    /// `LoginShellLookup.command(locating:)` for why that is not a failed command.
    public static let locate = LoginShellLookup.command(locating: "hc")

    /// Where herdr-core's installer and Herdr.app put it, asked only when the
    /// login shell's `PATH` has no herdr-core: `~/.local/bin/hc`, then
    /// `~/.local/bin/herdr-core`, each printed on its own line if it is
    /// executable.
    ///
    /// **The login shell is not enough on a Mac.** `~/.local/bin` is commonly
    /// put on `PATH` in `.zshrc` (it is on this project's Mac; who wrote the
    /// line is unverified), which only an *interactive* shell reads. `zsh -lc` reads `.zprofile`
    /// and stops there, so on such a Mac `command -v hc` answers empty over
    /// SSH while `hc` works in every terminal. Measured 12 Nov 2026 on this
    /// project's Mac, which read "Install herdr-core" with hc 0.1.20 installed.
    /// Debian's `.profile` adds `~/.local/bin` for login shells, which is why
    /// the Pis were found.
    ///
    /// **`herdr-core` as well as `hc`.** The installer always writes
    /// `~/.local/bin/herdr-core`, and adds the `hc` link beside it only when
    /// no `hc` exists — "some window managers ship one" (its own header, read
    /// 12 Nov 2026). On such a host the `hc` on `PATH` is not herdr-core and
    /// there is no `~/.local/bin/hc`; only this name finds what was installed.
    ///
    /// Run by `/bin/sh` inside single quotes, so the login shell (zsh, bash,
    /// fish) only has to pass a quoted string. Empty output when absent; the
    /// trailing `true` keeps absence from being a failed command.
    public static let standardLocations =
        #"/bin/sh -c 'for f in "$HOME/.local/bin/hc" "$HOME/.local/bin/herdr-core"; do [ -x "$f" ] && echo "$f"; done; true'"#

    /// Every absolute path in `standardLocations`' output, in order.
    public static func paths(inOutput output: String) -> [String] {
        output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("/") }
    }

    /// `<path> --version`, with the path quoted for a POSIX shell.
    public static func version(at path: String) -> String {
        SSHTransport.quote(path) + " --version"
    }

    /// The absolute path in `locate`'s output, ignoring a profile's banner.
    public static func path(inOutput output: String) -> String? {
        LoginShellLookup.path(inOutput: output)
    }

    /// The version in `hc --version` output, which reads `hc 0.1.20` (live,
    /// macOS) and `hc 0.1.18` (live, Debian).
    ///
    /// The last line that starts `hc <digit>`, since a shell's startup files
    /// may print before it. Words after the version are allowed and ignored:
    /// a later hc printing `hc 0.2.0 (abc123)` must not read as missing, which
    /// would be stored and tell every user to install what they have.
    ///
    /// Nil when there is none: then the `hc` that was found is not
    /// herdr-core, or does not run, and either way the host needs herdr-core.
    public static func version(inOutput output: String) -> String? {
        var version: String?
        for line in output.split(whereSeparator: \.isNewline) {
            let words = line.split(whereSeparator: \.isWhitespace)
            guard words.count >= 2, words[0] == "hc", let first = words[1].first, first.isNumber else {
                continue
            }
            version = String(words[1])
        }
        return version
    }
}
