#if DEBUG
import BleatKit

/// A host for previews: one template, two Herdr.app spaces, a home, and a
/// start that never returns.
final class PreviewTerminalHost: TerminalStarting {
    func templates() async -> [HcTemplate] {
        [HcTemplate(name: "pi-env", description: "Claude on a Pi with Docker Compose services.", command: "claude")]
    }
    func spaces() async throws -> [HerdrSpace] {
        [
            HerdrSpace(id: "sp1", name: "", folder: "/home/pi/developer/api"),
            HerdrSpace(id: "sp2", name: "web", folder: "/home/pi/developer/web"),
        ]
    }
    func shell() async throws -> any ShellRunner { PreviewShell() }
    func start(_ request: HcRunRequest) async throws -> String {
        try await Task.sleep(for: .seconds(3600))
        return "t1"
    }

    private struct PreviewShell: ShellRunner {
        func run(shell command: String) async throws -> String {
            command == HostDirectory.home ? "/home/pi" : "/home/pi\n"
        }
    }
}
#endif
