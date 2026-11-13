import BleatKit
import Foundation
import Observation

/// The new-terminal form: what to run, where, and under what name.
///
/// Three choices, decided by Ravil (13 Nov 2026): the host's shell, a command
/// line, or one of the host's templates with a first message. Directories and
/// commands are suggested from the terminals already running there.
///
/// **Two questions go to the host before `terminal.run`.** Its home, because
/// the core expands no `~` and without a directory starts the terminal in its
/// own, `/` on a Mac; and whether the directory exists, because a missing one
/// fails as `cannot start "/bin/sh"`, blaming the shell (both live, hc 0.1.20).
///
/// **A template's start can take a while**: `terminal.run` returns once the
/// agent is ready and the first message sent, and what it does with an agent
/// that never gets ready is open (plan, question 9). Cancel is the way out;
/// see `NewTerminalSheet`.
@Observable
final class NewTerminalModel: Identifiable {
    enum Kind: String, CaseIterable, Identifiable {
        case shell, command, template
        var id: String { rawValue }
        var title: String {
            switch self {
            case .shell: "Shell"
            case .command: "Command"
            case .template: "Template"
            }
        }
    }

    enum Phase: Equatable {
        case editing
        case starting
        case failed(String)
    }

    var kind: Kind = .shell
    var command = ""
    var templateName: String?
    var task = ""
    /// As typed: `~/api`, `api`, `/srv/web`, or empty for home.
    var directory = ""
    var name = ""

    private(set) var phase: Phase = .editing
    private(set) var templates: [HcTemplate] = []
    private(set) var home: String?

    let hostName: String
    let commandSuggestions: [String]
    private let terminals: [HcTerminal]
    private let host: any TerminalStarting

    init(hostName: String, terminals: [HcTerminal], host: any TerminalStarting) {
        self.hostName = hostName
        self.terminals = terminals
        self.host = host
        commandSuggestions = HcRunSuggestions.commands(from: terminals)
    }

    /// Directories in use on the host, home left out: it is the default.
    /// None until home is known — before that, home itself would be listed
    /// beside "~ (home)" and every path shown in full.
    var directorySuggestions: [String] {
        guard let home else { return [] }
        return HcRunSuggestions.directories(from: terminals, excluding: home)
    }

    var selectedTemplate: HcTemplate? {
        templates.first { $0.name == templateName }
    }

    /// Why the name will not do, while one is typed.
    var nameProblem: String? {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !HcRunRequest.isValidName(name) else { return nil }
        return "Up to 32 lowercase letters, digits, - _ or ."
    }

    var canStart: Bool {
        guard phase != .starting, nameProblem == nil else { return false }
        switch kind {
        case .shell: return true
        case .command: return !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .template: return selectedTemplate != nil
        }
    }

    /// What the new terminal's screen is titled until its own title arrives.
    var title: String {
        let name = name.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { return name }
        switch kind {
        case .shell: return "Shell"
        case .command: return command.trimmingCharacters(in: .whitespacesAndNewlines)
        case .template: return templateName ?? "Template"
        }
    }

    /// Home and templates, side by side. Neither failing stops the form: home
    /// is asked again on start, and no templates means no Template choice.
    func load() async {
        async let templates = host.templates()
        async let home = askHome()
        self.templates = await templates
        if templateName == nil { templateName = self.templates.first?.name }
        self.home = try? await home
    }

    /// Starts it. The new terminal's address, or nil with `phase` saying why.
    func start(size: TerminalGrid?) async -> String? {
        guard canStart else { return nil }
        phase = .starting
        do {
            let home = try await resolvedHome()
            let cwd = HcRunRequest.resolve(directory: directory, home: home)
            let shell = try await host.shell()
            if !HostDirectory.exists(inOutput: try await shell.run(shell: HostDirectory.exists(cwd))) {
                phase = .failed("\(HcRunSuggestions.abbreviate(cwd, home: home)) is not a directory on \(hostName).")
                return nil
            }
            let name = name.trimmingCharacters(in: .whitespaces)
            let request = HcRunRequest(program: program, name: name.isEmpty ? nil : name, cwd: cwd, size: size)
            let address = try await host.start(request)
            // Cancelled while it started (the sheet's Cancel): the terminal
            // may well be running on the host, and the list shows it, but the
            // user asked not to be taken into it.
            try Task.checkCancellation()
            phase = .editing
            return address
        } catch is CancellationError {
            phase = .editing
            return nil
        } catch {
            phase = .failed(Self.message(for: error))
            return nil
        }
    }

    private var program: HcRunRequest.Program {
        switch kind {
        case .shell: .shell
        case .command: .line(command.trimmingCharacters(in: .whitespacesAndNewlines))
        case .template: .template(name: templateName ?? "", task: task)
        }
    }

    private func askHome() async throws -> String {
        let shell = try await host.shell()
        guard let home = HostDirectory.home(inOutput: try await shell.run(shell: HostDirectory.home)) else {
            // The command ran; what it printed did not read as a path.
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "the host's home directory did not read as a path"))
        }
        return home
    }

    private func resolvedHome() async throws -> String {
        if let home { return home }
        let asked = try await askHome()
        home = asked
        return asked
    }

    /// herdr-core's own words where it said no; the directory was checked
    /// first, so a spawn failure here is the program.
    static func message(for error: any Error) -> String {
        if let error = error as? HcError {
            if error.kind == "spawn_failed" { return "It could not be started: \(error.message)." }
            return error.message
        }
        return ErrorMessage.of(error)
    }
}
