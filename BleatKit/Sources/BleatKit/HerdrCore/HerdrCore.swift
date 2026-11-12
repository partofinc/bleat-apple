import Foundation

/// What a host last said about herdr-core (`hc`), the runtime Bleat 2 talks to.
///
/// Stored on the peer, so the answer survives a relaunch and reaches the watch
/// with the rest of the record. **Only what the host said is stored.** A host
/// that could not be reached said nothing, so that case is not here: it is
/// `HerdrCoreCheck.Outcome.unreachable`, and it lasts for one check.
public enum HerdrCore: Sendable, Codable, Equatable {
    /// `hc` is on the login shell's `PATH` and answers `--version` as
    /// herdr-core.
    ///
    /// - `path`: absolute — an exec channel runs a non-login shell, and
    ///   `~/.local/bin`, where Herdr.app puts `hc`, is not on its `PATH`.
    /// - `version`: what `hc --version` printed after `hc `, e.g. `0.1.19`.
    case installed(path: String, version: String)
    /// The host was asked and has no herdr-core: no `hc` at all, or an `hc`
    /// that does not answer as herdr-core.
    case missing

    public var isInstalled: Bool {
        if case .installed = self { true } else { false }
    }

    public var path: String? {
        if case .installed(let path, _) = self { path } else { nil }
    }
}
