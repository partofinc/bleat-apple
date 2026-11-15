#if DEBUG
import BleatKit

/// Answers `list` with the fixture's shape, for the preview.
struct PreviewLayoutsShell: ShellRunner {
    func run(shell command: String) async throws -> String {
        #"[{"name":"Clinic","saved_at":1794719194,"open":0,"spaces":["clinic-api","clinic-ios","clinic-web"],"panes":3,"claude":3},{"name":"Studio","saved_at":1794628972,"open":1,"spaces":["studio"],"panes":1,"claude":1}]"#
    }
}
#endif
