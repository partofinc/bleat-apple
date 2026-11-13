import BleatKit

/// What the new-terminal form needs from a host: its templates, Herdr.app's
/// spaces there, a shell for
/// the questions asked first, and starting the terminal. `TerminalsModel`
/// answers it over the list's live connection; tests answer it from a script.
@MainActor
protocol TerminalStarting: AnyObject, Sendable {
    func templates() async -> [HcTemplate]
    func spaces() async -> [HerdrSpace]
    func shell() async throws -> any ShellRunner
    func start(_ request: HcRunRequest) async throws -> String
}
