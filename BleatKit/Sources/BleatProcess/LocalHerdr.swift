#if !os(iOS)
import Foundation

/// Where the `herdr` on this machine is, for `bleat` to run it here.
///
/// **This process's own `PATH` first, then a login shell.** The `PATH` `bleat`
/// was started with is the one the user's terminal has, and searching it costs
/// nothing; a login shell (`HostInspector.locateHerdr`) finds a `herdr` added
/// only by a profile, which is how `bleat pair` finds it and how the phone asks
/// over SSH. It used to be a fixed `/opt/homebrew/bin/herdr`, right on the Mac
/// and wrong on every Pi.
public enum LocalHerdr {
    /// - Parameters:
    ///   - given: `--herdr`, if passed. A value with a `/` is a path (`~`
    ///     expanded, relative to the working directory); a bare name is looked
    ///     up on `PATH`, as `bleat hosts add` stores one.
    ///   - path: The `PATH` to search; this process's by default.
    ///   - loginShell: The fallback when `given` is nil and `PATH` has none.
    public static func resolve(
        _ given: String?,
        path: String? = ProcessInfo.processInfo.environment["PATH"],
        loginShell: () -> String? = { HostInspector().locateHerdr() }
    ) -> String? {
        if let given {
            let expanded = (given as NSString).expandingTildeInPath
            guard !expanded.contains("/") else { return URL(fileURLWithPath: expanded).path }
            return executable(named: expanded, onPath: path)
        }
        return executable(named: "herdr", onPath: path) ?? loginShell()
    }

    /// The first executable called `name` in `path`'s directories.
    static func executable(named name: String, onPath path: String?) -> String? {
        for directory in (path ?? "").split(separator: ":") where !directory.isEmpty {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(name).path
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}

#endif
