// macOS and Linux only, like everything in this target.
#if !os(iOS)
import BleatKit
import Foundation

/// herdr-core on this machine, reached the way the phone reaches it: `hc
/// connect`, its stdin and stdout the framed byte stream.
///
/// Through the process rather than the core's Unix socket so the console tool
/// exercises exactly the bytes an SSH exec channel carries.
public struct LocalHc: HcStreamOpening {
    public init() {}

    public func openHcConnection(hcPath: String) async throws -> any DuplexStream {
        try LocalProcessStream(
            executable: URL(fileURLWithPath: hcPath),
            args: ["connect"],
            environment: ProcessInfo.processInfo.environment
        )
    }

    /// `hc` on `PATH`, else where Herdr.app installs it — the same two places
    /// `HerdrCoreCheck` asks a host about.
    public static func resolve(_ explicit: String?) -> String? {
        if let explicit { return FileManager.default.isExecutableFile(atPath: explicit) ? explicit : nil }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = path.split(separator: ":").map { "\($0)/hc" } + ["\(home)/.local/bin/hc"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
#endif
