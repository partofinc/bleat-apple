/// What is running in a pane, from `pane process-info --pane <target>`.
///
/// Asked for so the pane's pty can be found. Herdr exposes no way to set a
/// pane's size — `pane resize` adjusts split ratios, and a pane's grid otherwise
/// belongs to the session — so the only handle on it is the tty of the process
/// inside, reached through this pid.
public struct PaneProcessInfo: Decodable, Sendable {
    public struct Process: Decodable, Sendable {
        public let pid: Int
        public let cmdline: String?
    }

    public let paneID: String?
    /// The shell herdr started. The fallback when nothing is running in front
    /// of it — a plain pane still has a pty worth sizing.
    public let shellPID: Int?
    public let foregroundProcesses: [Process]?

    /// The process whose tty should be resized: whatever is in the foreground,
    /// or the shell behind it.
    public var pid: Int? {
        foregroundProcesses?.first?.pid ?? shellPID
    }

    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
        case shellPID = "shell_pid"
        case foregroundProcesses = "foreground_processes"
    }
}

/// `pane process-info` wraps its payload one level deeper than the other
/// commands do.
public struct PaneProcessInfoResult: Decodable, Sendable {
    public let processInfo: PaneProcessInfo

    enum CodingKeys: String, CodingKey {
        case processInfo = "process_info"
    }
}
