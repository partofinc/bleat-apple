import Foundation

/// The two shell questions that find herdr-core on a host, and how their
/// answers are read.
///
/// **Two commands, not one.** Finding `hc` needs the user's login shell, which
/// may be fish; asking it for the version too would mean POSIX variable
/// assignment inside that shell. So the login shell only runs `command -v`,
/// exactly as `HerdrLookup` does, and the version is asked of the absolute
/// path it gave, which every shell runs the same way.
public enum HerdrCoreLookup {
    /// `command -v hc` through a login shell. Empty output means absent; see
    /// `HerdrLookup.command(locating:)` for why that is not a failed command.
    public static let locate = HerdrLookup.command(locating: "hc")

    /// `<path> --version`, with the path quoted for a POSIX shell.
    public static func version(at path: String) -> String {
        quote(path) + " --version"
    }

    /// The absolute path in `locate`'s output, ignoring a profile's banner.
    public static func path(inOutput output: String) -> String? {
        HerdrLookup.path(inOutput: output)
    }

    /// The version in `hc --version` output, which reads `hc 0.1.19` (live,
    /// hc 0.1.19 on macOS).
    ///
    /// The last line of that shape, since a shell's startup files may print
    /// before it. Nil when there is none: then the `hc` that was found is not
    /// herdr-core, or does not run, and either way the host needs herdr-core.
    public static func version(inOutput output: String) -> String? {
        var version: String?
        for line in output.split(whereSeparator: \.isNewline) {
            let words = line.split(whereSeparator: \.isWhitespace)
            guard words.count == 2, words[0] == "hc", let first = words[1].first, first.isNumber else {
                continue
            }
            version = String(words[1])
        }
        return version
    }

    /// Single quotes for POSIX shells, the same rule as `SSHTransport.quote`.
    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
