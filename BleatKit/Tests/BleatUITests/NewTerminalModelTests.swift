import BleatKit
import Foundation
import Testing
@testable import BleatUI

@Suite("The new-terminal form")
@MainActor
struct NewTerminalModelTests {

    /// A host from a script: its home, which directories exist, its templates,
    /// and what `terminal.run` answers. Records what it was asked.
    final class ScriptedHost: TerminalStarting {
        var home = "/home/pi"
        var directories: Set<String> = ["/home/pi", "/home/pi/api"]
        var templateList: [HcTemplate] = []
        var spaceList: [HerdrSpace] = []
        var startResult: Result<String, any Error> = .success("t7")
        /// Printed before every answer, as a chatty shell startup would.
        var banner = ""
        private(set) var started: [HcRunRequest] = []
        private(set) var commands: [String] = []

        func templates() async -> [HcTemplate] { templateList }

        func spaces() async -> [HerdrSpace] { spaceList }

        func shell() async throws -> any ShellRunner { Shell(host: self) }

        func start(_ request: HcRunRequest) async throws -> String {
            started.append(request)
            return try startResult.get()
        }

        func answer(_ command: String) -> String {
            commands.append(command)
            if command == HostDirectory.home { return banner + home }
            let checked = directories.contains { command == HostDirectory.exists($0) }
            return banner + (checked ? "yes\n" : "no\n")
        }

        struct Shell: ShellRunner {
            let host: ScriptedHost
            func run(shell command: String) async throws -> String {
                await MainActor.run { host.answer(command) }
            }
        }
    }

    private func form(_ host: ScriptedHost, terminals: [HcTerminal] = []) -> NewTerminalModel {
        NewTerminalModel(hostName: "adam", terminals: terminals, host: host)
    }

    @Test("a shell starts in home, detached, at the phone's grid")
    func shellInHome() async throws {
        let host = ScriptedHost()
        let model = form(host)
        await model.load()
        let address = await model.start(size: TerminalGrid(cols: 53, rows: 30))

        #expect(address == "t7")
        let request = try #require(host.started.first)
        #expect(request.program == .shell)
        #expect(request.cwd == "/home/pi")
        #expect(request.size == TerminalGrid(cols: 53, rows: 30))
        #expect(request.params["no_parent"] == .bool(true))
        #expect(model.title == "Shell")
    }

    /// The core blames the shell for a missing directory; the form says what
    /// is wrong instead, and never calls `terminal.run`.
    @Test("a directory that does not exist is said so, and nothing is started")
    func missingDirectory() async {
        let host = ScriptedHost()
        let model = form(host)
        model.directory = "~/nope"
        let address = await model.start(size: nil)

        #expect(address == nil)
        #expect(host.started.isEmpty)
        #expect(model.phase == .failed("~/nope is not a directory on adam."))
    }

    @Test("a command runs as a line, in a directory under home, under its name")
    func command() async throws {
        let host = ScriptedHost()
        let model = form(host)
        model.kind = .command
        model.command = "  claude --resume "
        model.directory = "api"
        model.name = "api-agent"
        _ = await model.start(size: nil)

        let request = try #require(host.started.first)
        #expect(request.program == .line("claude --resume"))
        #expect(request.cwd == "/home/pi/api")
        #expect(request.name == "api-agent")
        #expect(model.title == "api-agent")
    }

    @Test("what cannot start is not offered")
    func canStart() async {
        let host = ScriptedHost()
        let model = form(host)
        #expect(model.canStart)

        model.kind = .command
        #expect(!model.canStart)
        model.command = "claude"
        #expect(model.canStart)

        model.name = "My Agent"
        #expect(model.nameProblem != nil)
        #expect(!model.canStart)
        model.name = "my-agent"
        #expect(model.nameProblem == nil)

        model.kind = .template
        #expect(!model.canStart, "no templates loaded")
    }

    @Test("templates load, the first is picked, and its run carries the task")
    func template() async throws {
        let host = ScriptedHost()
        host.templateList = [
            HcTemplate(name: "pi-env", description: "", command: "claude"),
            HcTemplate(name: "review", description: "", command: "claude"),
        ]
        let model = form(host)
        await model.load()
        #expect(model.templateName == "pi-env")
        #expect(model.home == "/home/pi")

        model.kind = .template
        model.task = "run the tests"
        _ = await model.start(size: nil)
        #expect(try #require(host.started.first).program == .template(name: "pi-env", task: "run the tests"))
    }

    /// The directory was checked first, so a spawn failure is the program.
    @Test("herdr-core refusing is shown in its own words")
    func refused() async {
        let host = ScriptedHost()
        host.startResult = .failure(HcError(code: -32000, message: "cannot start \"nope\": No such file or directory (os error 2)", kind: "spawn_failed"))
        let model = form(host)
        model.kind = .command
        model.command = "nope"
        #expect(await model.start(size: nil) == nil)
        #expect(model.phase == .failed("It could not be started: cannot start \"nope\": No such file or directory (os error 2)."))
    }

    @Test("suggestions come from the host's terminals")
    func suggestions() async throws {
        let terminals = try [
            JSONDecoder().decode(HcTerminal.self, from: Data(#"{"address":"t1","cwd":"/home/pi/api","foreground":{"argv":["claude"],"cwd":"/home/pi/api"}}"#.utf8)),
            JSONDecoder().decode(HcTerminal.self, from: Data(#"{"address":"t2","cwd":"/home/pi","foreground":{"argv":["zsh"],"cwd":"/home/pi"}}"#.utf8)),
        ]
        let model = form(ScriptedHost(), terminals: terminals)
        await model.load()
        #expect(model.commandSuggestions == ["claude"])
        #expect(model.directorySuggestions == ["/home/pi/api"])
    }

    @Test("a host whose shell prints on startup still starts terminals")
    func chattyHost() async {
        let host = ScriptedHost()
        host.banner = "Welcome to adam\n"
        let model = form(host)
        await model.load()
        #expect(model.home == "/home/pi")
        #expect(await model.start(size: nil) == "t7")
    }

    /// Cancel while starting: nothing is opened and nothing reads as failed.
    @Test("a start cancelled part way opens nothing and says nothing failed")
    func cancelled() async {
        let host = ScriptedHost()
        host.startResult = .failure(CancellationError())
        let model = form(host)
        #expect(await model.start(size: nil) == nil)
        #expect(model.phase == .editing)
    }

    @Test("no directory suggestions until home is known")
    func suggestionsWaitForHome() async throws {
        let terminals = try [
            JSONDecoder().decode(HcTerminal.self, from: Data(#"{"address":"t1","cwd":"/home/pi","foreground":{"cwd":"/home/pi"}}"#.utf8)),
            JSONDecoder().decode(HcTerminal.self, from: Data(#"{"address":"t2","cwd":"/home/pi/api"}"#.utf8)),
        ]
        let model = form(ScriptedHost(), terminals: terminals)
        #expect(model.directorySuggestions.isEmpty)
        await model.load()
        #expect(model.directorySuggestions == ["/home/pi/api"])
    }

    @Test("by default it goes in the space whose folder holds its directory")
    func spaceByFolder() async throws {
        let host = ScriptedHost()
        host.spaceList = [HerdrSpace(id: "sp1", name: "", folder: "/home/pi/api"), HerdrSpace(id: "sp2", name: "", folder: "/srv")]
        let model = form(host)
        await model.load()
        #expect(model.space == nil, "home is in no space")
        model.directory = "api"
        #expect(model.space?.id == "sp1")
        _ = await model.start(size: nil)
        #expect(try #require(host.started.first).space == "sp1")
    }

    @Test("a space picked by hand wins, and None starts it hidden from Herdr.app")
    func spacePicked() async throws {
        let host = ScriptedHost()
        host.spaceList = [HerdrSpace(id: "sp1", name: "", folder: "/home/pi/api"), HerdrSpace(id: "sp2", name: "", folder: "/srv")]
        let model = form(host)
        await model.load()
        model.directory = "api"
        model.placement = .space("sp2")
        #expect(model.spaceByFolder?.id == "sp1")
        _ = await model.start(size: nil)
        model.placement = .hidden
        _ = await model.start(size: nil)
        #expect(host.started.map(\.space) == ["sp2", nil])
    }

    @Test("a home that does not read as a path is contract drift, not a failed command")
    func unreadableHome() async {
        let host = ScriptedHost()
        host.home = "not a path"
        let model = form(host)
        #expect(await model.start(size: nil) == nil)
        guard case .failed = model.phase else {
            Issue.record("expected failed")
            return
        }
        #expect(host.started.isEmpty)
    }
}
