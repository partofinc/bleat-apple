import Foundation

/// How busy a host is right now: the part of what it says about itself that is
/// only true for a moment.
///
/// Never stored. It is read over a live connection and is worth nothing once
/// that connection has gone.
public struct HostLoad: Sendable, Equatable {
    /// So much of something used, out of so much.
    public struct Usage: Sendable, Equatable {
        /// Bytes.
        public let used: Int64
        /// Bytes.
        public let total: Int64

        public init(used: Int64, total: Int64) {
            self.used = used
            self.total = total
        }

        public var free: Int64 { total - used }

        /// From 0 to 1.
        public var fraction: Double {
            total > 0 ? min(max(Double(used) / Double(total), 0), 1) : 0
        }
    }

    public var cores: Int?
    /// The share of all cores that was busy over the probe's one-second
    /// sample, from 0 to 1.
    public var cpuUsage: Double?
    /// The one-minute load average.
    public var loadAverage: Double?
    public var memory: Usage?
    /// The volume holding the home directory, which is where the agents work.
    public var disk: Usage?
    /// Degrees Celsius. Linux only.
    public var temperature: Double?
    public var uptime: Duration?

    public init(
        cores: Int? = nil,
        cpuUsage: Double? = nil,
        loadAverage: Double? = nil,
        memory: Usage? = nil,
        disk: Usage? = nil,
        temperature: Double? = nil,
        uptime: Duration? = nil
    ) {
        self.cores = cores
        self.cpuUsage = cpuUsage
        self.loadAverage = loadAverage
        self.memory = memory
        self.disk = disk
        self.temperature = temperature
        self.uptime = uptime
    }

    public var isEmpty: Bool { self == HostLoad() }
}
