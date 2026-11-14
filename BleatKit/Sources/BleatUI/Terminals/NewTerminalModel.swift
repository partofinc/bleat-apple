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
/// own, `/` on a Mac; and where the directory really is, because a missing one
/// fails as `cannot start "/bin/sh"`, blaming the shell (both live, hc 0.1.20).
///
/// **A template's start can take a while**: `terminal.run` returns once the
/// agent is ready and the first message sent, and what it does with an agent
/// that never gets ready is open (plan, question 9). Cancel is the way out;
/// see `NewTerminalSheet`.
///
/// **Where it shows in Herdr.app** (`HerdrSpace`): by default the space whose
/// folder holds its directory, in a new tab; or a space picked by hand; or
/// none, and Herdr.app does not show it. The spaces are read when the sheet
/// opens and again on Start, so a space closed on the Mac meanwhile is not
/// sent: an unknown id would make Herdr.app create a new, unnamed space.
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

    /// Which Herdr.app space it goes in.
    enum Placement: Hashable {
        /// The space whose folder holds the directory, if one does.
        case matching
        /// None: Herdr.app does not show it.
        case hidden
        case space(String)
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
    var placement: Placement = .matching

    private(set) var phase: Phase = .editing
    private(set) var templates: [HcTemplate] = []
    /// Herdr.app's spaces on the host; none where Herdr.app never ran.
    private(set) var spaces: [HerdrSpace] = []
    /// Why the spaces could not be read, so "none" is not mistaken for
    /// "Herdr.app never ran here".
    private(set) var spacesProblem: String?
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

    /// The typed directory as an absolute path; nil until home is known.
    /// On Start it is replaced by the host's own spelling of it.
    private var typedDirectory: String? {
        home.map { HcRunRequest.resolve(directory: directory, home: $0) }
    }

    /// The space it will be shown in, as the form stands.
    var space: HerdrSpace? { space(placement, for: typedDirectory) }

    /// What "By folder" would choose, whatever is picked.
    var spaceByFolder: HerdrSpace? { space(.matching, for: typedDirectory) }

    /// Whether "By folder" is chosen and finds no space, so the terminal will
    /// not show in Herdr.app although it has spaces here — the case to warn
    /// about: a phone's terminal went missing on the Mac this way, its folder
    /// having no space yet (14 Nov 2026). "None", picked, is not warned about.
    var noSpaceForFolder: Bool {
        placement == .matching && home != nil && !spaces.isEmpty && spaceByFolder == nil
    }

    /// Whether "By folder" cannot be told yet: home is not known, so neither
    /// is the directory. Start asks for home and places it then.
    var spaceAwaitsHome: Bool { placement == .matching && home == nil }

    /// The one rule: the space a placement puts a terminal in `cwd` in.
    private func space(_ placement: Placement, for cwd: String?) -> HerdrSpace? {
        switch placement {
        case .matching: cwd.flatMap { HerdrSpace.matching($0, in: spaces) }
        case .hidden: nil
        case .space(let id): spaces.first { $0.id == id }
        }
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

    /// Home, templates and spaces, side by side. None failing stops the form:
    /// home is asked again on start, no templates means no Template choice,
    /// and spaces that cannot be read are said so and asked again on Start.
    func load() async {
        async let templates = host.templates()
        async let spaces = readSpaces()
        async let home = askHome()
        self.templates = await templates
        await spaces
        if templateName == nil { templateName = self.templates.first?.name }
        self.home = try? await home
    }

    /// Starts it. The new terminal's address, or nil with `phase` saying why.
    func start(size: TerminalGrid?) async -> String? {
        guard canStart else { return nil }
        phase = .starting
        do {
            let home = try await resolvedHome()
            let typed = HcRunRequest.resolve(directory: directory, home: home)
            let shell = try await host.shell()
            guard let cwd = HostDirectory.physical(inOutput: try await shell.run(shell: HostDirectory.physical(typed))) else {
                phase = .failed("\(HcRunSuggestions.abbreviate(typed, home: home)) is not a directory on \(hostName).")
                return nil
            }
            // Again, as they are now: the sheet may have been open a while.
            await readSpaces()
            if case .space(let id) = placement, !spaces.contains(where: { $0.id == id }) {
                phase = .failed("That space is no longer in Herdr on \(hostName). Pick another.")
                return nil
            }
            let name = name.trimmingCharacters(in: .whitespaces)
            let request = HcRunRequest(
                program: program, name: name.isEmpty ? nil : name, cwd: cwd, size: size, space: space(placement, for: cwd)?.id
            )
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

    /// Reads the spaces, keeping what was read before if this read fails.
    private func readSpaces() async {
        do {
            spaces = try await host.spaces()
            spacesProblem = nil
        } catch is CancellationError {
            return
        } catch {
            spacesProblem = Self.message(for: error)
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
