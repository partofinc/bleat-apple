import Foundation
import Testing
@testable import BleatKit

@Suite("Starting a terminal from the phone")
struct HcRunTests {

    private func json(_ name: String) throws -> HcJSON {
        try JSONDecoder().decode(HcJSON.self, from: Fixture.data(name))
    }

    private func terminal(_ json: String) throws -> HcTerminal {
        try JSONDecoder().decode(HcTerminal.self, from: Data(json.utf8))
    }

    // MARK: - The request

    /// The rule the whole feature rests on: a terminal started from the phone
    /// must outlive the phone's SSH session and type nothing into it.
    @Test("every program is started with no parent and no notes", arguments: [
        HcRunRequest.Program.shell, .line("claude"), .template(name: "pi-env", task: "run the tests"),
    ])
    func detached(program: HcRunRequest.Program) {
        let params = HcRunRequest(program: program).params
        #expect(params["no_parent"] == .bool(true))
        #expect(params["no_notify"] == .bool(true))
        // No identity: the core's, as every other terminal. No labels
        // without a space.
        #expect(params["env"] == nil)
        #expect(params["labels"] == nil)
    }

    @Test("a shell is an empty argv, a command is a line, a template is its name and task")
    func programs() {
        #expect(HcRunRequest(program: .shell).params["argv"] == .array([]))
        #expect(HcRunRequest(program: .line("npm run dev")).params["line"] == .string("npm run dev"))
        #expect(HcRunRequest(program: .line("npm run dev")).params["argv"] == nil)
        #expect(
            HcRunRequest(program: .template(name: "pi-env", task: "  run the tests \n")).params["argv"]
                == .array([.string("pi-env"), .string("run the tests")])
        )
        #expect(HcRunRequest(program: .template(name: "pi-env", task: " ")).params["argv"] == .array([.string("pi-env")]))
    }

    @Test("name, directory and the phone's grid go when given, and only then")
    func optionalParams() {
        let full = HcRunRequest(program: .shell, name: "api", cwd: "/home/pi/api", size: TerminalGrid(cols: 53, rows: 30)).params
        #expect(full["name"] == .string("api"))
        #expect(full["cwd"] == .string("/home/pi/api"))
        #expect(full["size"] == .object(["cols": .number(53), "rows": .number(30)]))

        let bare = HcRunRequest(program: .shell, name: "", cwd: "", size: TerminalGrid(cols: 0, rows: 0)).params
        #expect(bare["name"] == nil)
        #expect(bare["cwd"] == nil)
        #expect(bare["size"] == nil)
    }

    @Test("the reply, as captured, gives the new terminal's address")
    func capturedReply() throws {
        let reply = try json("hc-run.json")
        #expect(try HcRunRequest.address(inReply: reply) == "t64")
        #expect(throws: DecodingError.self) { try HcRunRequest.address(inReply: .object([:])) }
    }

    /// A directory that does not exist is blamed on the shell; the app checks
    /// the directory first so this message is not what the user reads.
    @Test("a missing directory, as captured, is a spawn failure that blames the program")
    func spawnFailure() throws {
        let error = try JSONDecoder().decode(HcError.self, from: Fixture.data("hc-run-spawn-failed.json"))
        #expect(error.kind == "spawn_failed")
        #expect(error.message.contains("/bin/sh"))
    }

    @Test("names are 1–32 of a-z 0-9 - _ .")
    func names() {
        #expect(HcRunRequest.isValidName("api-server_2.dev"))
        #expect(!HcRunRequest.isValidName(""))
        #expect(!HcRunRequest.isValidName("Api"))
        #expect(!HcRunRequest.isValidName("my api"))
        #expect(!HcRunRequest.isValidName(String(repeating: "a", count: 33)))
        #expect(!HcRunRequest.isValidName("café"))
    }

    /// The core expands no `~` (live: it fails as "cannot start /bin/sh").
    @Test("a typed directory resolves against the host's home")
    func directories() {
        let home = "/home/pi"
        #expect(HcRunRequest.resolve(directory: "", home: home) == "/home/pi")
        #expect(HcRunRequest.resolve(directory: "~", home: home) == "/home/pi")
        #expect(HcRunRequest.resolve(directory: "~/developer/api", home: home) == "/home/pi/developer/api")
        #expect(HcRunRequest.resolve(directory: "developer", home: home) == "/home/pi/developer")
        #expect(HcRunRequest.resolve(directory: " /srv/app ", home: home) == "/srv/app")
        #expect(HcRunRequest.resolve(directory: "~/x", home: "/home/pi/") == "/home/pi/x")
    }

    // MARK: - Herdr.app's spaces

    /// Herdr.app shows only terminals labeled with a space; with no tab label
    /// it gives the terminal a new tab there. Never `herdr.tab`.
    @Test("a space is the herdr.space label, with seen at 0 as a new terminal's")
    func spaceLabels() {
        let params = HcRunRequest(program: .shell, space: "spa4f8").params
        #expect(params["labels"] == .object(["herdr.space": .string("spa4f8"), "herdr.seen": .string("0")]))
        #expect(HcRunRequest(program: .shell, space: "").params["labels"] == nil)
    }

    @Test("spaces, as captured from Herdr.app's document, read in its order")
    func capturedSpaces() throws {
        let spaces = HerdrSpace.list(inReply: try json("hc-doc-herdr-app.json"))
        #expect(spaces.count == 6)
        #expect(spaces.first?.name == "acme-health")
        #expect(spaces.first?.id == "sp0c76818d68b5426ba2b46194c2d3a72a")
        #expect(spaces[3].folder == "/Users/robin/Developer/acme")
    }

    @Test("a core Herdr.app never wrote to has no spaces, and a space that does not read is left out")
    func noSpaces() {
        #expect(HerdrSpace.list(inReply: .object(["value": .null, "version": .number(0)])).isEmpty)
        let reply = HcJSON.object(["value": .object(["spaces": .array([
            .object(["id": .string("sp1"), "folder": .string("/a")]),
            .object(["name": .string("no id")]),
            .string("not a space"),
        ])])])
        #expect(HerdrSpace.list(inReply: reply) == [HerdrSpace(id: "sp1", name: "", folder: "/a")])
    }

    @Test("an unnamed space is called after its folder, Herdr.app's way")
    func spaceNames() {
        #expect(HerdrSpace(id: "a", name: "web", folder: "/srv/web").displayName(home: nil) == "web")
        #expect(HerdrSpace(id: "a", name: "", folder: "/home/pi/developer/api/").displayName(home: "/home/pi") == "api")
        #expect(HerdrSpace(id: "a", name: "", folder: "/home/pi").displayName(home: "/home/pi") == "~")
    }

    @Test("a directory's spaces are the ones whose folder is that directory, not a parent")
    func spacesForFolder() {
        let spaces = [
            HerdrSpace(id: "acme", name: "", folder: "/u/dev/acme"),
            HerdrSpace(id: "links", name: "", folder: "/u/dev/acme/links"),
            HerdrSpace(id: "acme2", name: "Acme again", folder: "/u/dev/acme/"),
            HerdrSpace(id: "none", name: "", folder: ""),
        ]
        #expect(HerdrSpace.spaces(for: "/u/dev/acme", in: spaces).map(\.id) == ["acme", "acme2"])
        #expect(HerdrSpace.spaces(for: "/u/dev/acme/links/", in: spaces).map(\.id) == ["links"])
        #expect(HerdrSpace.spaces(for: "/u/dev/acme/links/src", in: spaces).isEmpty, "a parent's space does not count")
        #expect(HerdrSpace.spaces(for: "/u/dev/acme-other", in: spaces).isEmpty)
    }

    @Test("a trailing slash is the same folder, for naming and resolving")
    func trailingSlashes() {
        let space = HerdrSpace(id: "a", name: "", folder: "/u/dev/")
        #expect(space.displayName(home: "/u/dev/") == "~")
        #expect(HcRunRequest.resolve(directory: "x", home: "/u/dev/") == "/u/dev/x")
    }

    @Test("a new space id is in Herdr.app's form, and new every time")
    func newSpaceID() {
        let id = HerdrSpace.newID()
        #expect(id.count == 34 && id.hasPrefix("sp"))
        #expect(id.dropFirst(2).allSatisfy { $0.isHexDigit && !$0.isUppercase })
        #expect(HerdrSpace.newID() != id)
    }

    // MARK: - Templates

    @Test("templates, as captured, read by name")
    func capturedTemplates() throws {
        let templates = HcTemplate.list(inReply: try json("hc-templates.json"))
        #expect(templates.map(\.name) == ["pi-env"])
        #expect(templates.first?.command == "claude")
    }

    @Test("a template the core cannot use, or that does not read, is left out")
    func unusableTemplates() {
        let reply = HcJSON.object(["templates": .array([
            .object(["name": .string("b"), "description": .string(""), "command": .string("x")]),
            .object(["name": .string("broken"), "description": .string(""), "command": .string(""), "error": .string("bad front matter")]),
            .object(["name": .string("a"), "description": .string(""), "command": .string("y")]),
            .string("not a template"),
        ])])
        #expect(HcTemplate.list(inReply: reply).map(\.name) == ["a", "b"])
        #expect(HcTemplate.list(inReply: .object([:])).isEmpty)
    }

    // MARK: - Suggestions

    @Test("directories and commands come from the running terminals, most used first, shells and home left out")
    func suggestions() throws {
        let terminals = try [
            terminal(#"{"address":"t1","cwd":"/home/pi","foreground":{"argv":["claude"],"cwd":"/home/pi/api"}}"#),
            terminal(#"{"address":"t2","cwd":"/home/pi/api","foreground":{"argv":["/usr/local/bin/claude","--resume"]}}"#),
            terminal(#"{"address":"t3","cwd":"/home/pi","foreground":{"argv":["-zsh"],"cwd":"/home/pi"}}"#),
            terminal(#"{"address":"t4","cwd":"/srv/web","argv":["npm","run","dev"]}"#),
            terminal(#"{"address":"t5","cwd":"/"}"#),
        ]
        #expect(HcRunSuggestions.directories(from: terminals, excluding: "/home/pi") == ["/home/pi/api", "/srv/web"])
        #expect(HcRunSuggestions.commands(from: terminals) == ["claude", "npm"])
    }

    @Test("a terminal's program is one name for the row and the suggestions")
    func programName() throws {
        #expect(try terminal(#"{"address":"t1","foreground":{"argv":["/usr/local/bin/claude","--resume"]}}"#).programName == "claude")
        #expect(try terminal(#"{"address":"t2","foreground":{"argv":["-zsh"]}}"#).programName == "zsh")
        // An empty foreground argv falls back to how it was started.
        #expect(try terminal(#"{"address":"t3","argv":["npm","run"],"foreground":{"argv":[]}}"#).programName == "npm")
        #expect(try terminal(#"{"address":"t4"}"#).programName == nil)
        #expect(try terminal(#"{"address":"t4"}"#).displayName == "t4")
    }

    @Test("paths under home show as ~")
    func abbreviation() {
        #expect(HcRunSuggestions.abbreviate("/home/pi/api", home: "/home/pi") == "~/api")
        #expect(HcRunSuggestions.abbreviate("/home/pi", home: "/home/pi") == "~")
        #expect(HcRunSuggestions.abbreviate("/home/pierre", home: "/home/pi") == "/home/pierre")
        #expect(HcRunSuggestions.abbreviate("/srv", home: nil) == "/srv")
    }

    // MARK: - Asking the host

    @Test("home is printed through /bin/sh, and only an absolute answer counts")
    func home() {
        #expect(HostDirectory.home == #"/bin/sh -c 'printf "%s" "$HOME"'"#)
        #expect(HostDirectory.home(inOutput: "/home/pi\n") == "/home/pi")
        #expect(HostDirectory.home(inOutput: "") == nil)
    }

    /// A shell whose startup prints refused every directory when the whole
    /// output had to be "yes".
    @Test("a banner before the answer is skipped")
    func banners() {
        #expect(HostDirectory.home(inOutput: "Welcome to adam\n/home/pi") == "/home/pi")
        #expect(HostDirectory.physical(inOutput: "Welcome to adam\n/home/pi/api\n") == "/home/pi/api")
        #expect(HostDirectory.physical(inOutput: "/home/pi, welcome\nno\n") == nil)
        #expect(HostDirectory.physical(inOutput: "") == nil)
    }
}
