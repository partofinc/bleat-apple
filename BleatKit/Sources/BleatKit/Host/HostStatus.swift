import Foundation

/// One reply to `HostStatusProbe`: what the host is, and how busy it is.
///
/// Two halves because they have different lifetimes. `info` sticks to the host
/// and is stored on its peer record; `load` is true for a moment and is shown
/// only while the connection it was read over is still up.
public struct HostStatus: Sendable, Equatable {
    public var info: HostInfo
    public var load: HostLoad

    public init(info: HostInfo = HostInfo(), load: HostLoad = HostLoad()) {
        self.info = info
        self.load = load
    }

    /// Whether the host said nothing this could read — a reply that is all
    /// banner, or a shell that could not run the probe.
    public var isEmpty: Bool { info.isEmpty && load.isEmpty }
}
