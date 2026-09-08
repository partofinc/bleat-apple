import Foundation
import Testing
@testable import BleatKit

/// Creating a workspace on a host.
///
/// Everything here was read off herdr 0.9.0 on the dev Mac (8 Sept 2026) in a
/// disposable session, because the two facts that shape the design are both
/// things herdr does silently.
@Suite("Creating a workspace")
struct WorkspaceCreateTests {

    // MARK: - The reply

    /// Three objects from one command. The fixture is the host's own bytes.
    @Test("the reply carries the workspace, its tab and its first pane")
    func decodesTheReply() throws {
        let created = try JSONDecoder()
            .decode(HerdrEnvelope<WorkspaceCreated>.self, from: Fixture.data("workspace-create.json"))
            .result

        #expect(created.workspace.workspaceID == "w4")
        #expect(created.workspace.label == "captured")
        // A workspace is never empty: one tab, holding one pane.
        #expect(created.workspace.tabCount == 1)
        #expect(created.workspace.paneCount == 1)
        #expect(created.tab?.tabID == "w4:t1")
        #expect(created.rootPane?.paneID == "w4:p1")
        #expect(created.rootPane?.tabID == "w4:t1")
        #expect(created.rootPane?.cwd == "/Users/ravil/Developer")
    }

    /// The reason `tab` and `root_pane` are optional. A host answering in a
    /// shape this build does not know must not cost a workspace that was made
    /// perfectly well — it exists on someone's Mac either way, and throwing the
    /// reply away only means nobody is told about it.
    @Test("a reply carrying only the workspace still decodes")
    func toleratesAMissingTabAndPane() throws {
        let body = Data(#"""
        {"workspace":{"workspace_id":"w9","label":"x","number":9,"agent_status":"idle",
                      "focused":false,"pane_count":1,"tab_count":1}}
        """#.utf8)
        let created = try JSONDecoder().decode(WorkspaceCreated.self, from: body)
        #expect(created.workspace.workspaceID == "w9")
        #expect(created.tab == nil)
        #expect(created.rootPane == nil)
    }

    // MARK: - Where it actually landed

    /// **The measurement this whole design turns on.**
    ///
    /// ```
    /// $ herdr workspace create --cwd /no/such/dir --label ghost
    /// {"result":{"root_pane":{"cwd":"/Users/ravil",…},
    ///            "workspace":{"label":"ghost",…}}}
    /// ```
    ///
    /// Exit 0, no error, and a workspace in the home directory rather than the
    /// one that was asked for. So the reply is checked against the request
    /// rather than read as agreement.
    @Test("a pane that opened somewhere else is caught")
    func spotsTheSilentFallback() {
        let asked = WorkspaceDirectory("/no/such/dir")!
        let created = WorkspaceCreated(
            workspace: Workspace(workspaceID: "w1", label: "ghost", number: 1, agentStatus: .unknown),
            rootPane: pane(cwd: "/Users/ravil")
        )
        #expect(created.openedElsewhere(than: asked) == "/Users/ravil")
    }

    @Test("a pane that opened where it was asked to is not a complaint")
    func acceptsTheHappyPath() throws {
        let created = try JSONDecoder()
            .decode(HerdrEnvelope<WorkspaceCreated>.self, from: Fixture.data("workspace-create.json"))
            .result
        #expect(created.openedElsewhere(than: WorkspaceDirectory("/Users/ravil/Developer")!) == nil)
    }

    /// A missing answer is not a wrong one. `SessionStatus` makes the same
    /// distinction about a session it has not asked about yet: guessing here
    /// would report a perfectly good workspace as misplaced.
    @Test("a host that did not say where is not accused of getting it wrong")
    func silenceIsNotAnAccusation() {
        let created = WorkspaceCreated(
            workspace: Workspace(workspaceID: "w1", label: "x", number: 1, agentStatus: .idle)
        )
        #expect(created.openedElsewhere(than: WorkspaceDirectory("/tmp")!) == nil)
    }

    private func pane(cwd: String) -> Pane {
        let body = """
        {"pane_id":"w1:p1","workspace_id":"w1","tab_id":"w1:t1",
         "agent_status":"unknown","focused":false,"cwd":"\(cwd)"}
        """
        return try! JSONDecoder().decode(Pane.self, from: Data(body.utf8))
    }

    // MARK: - The directory

    @Test("an absolute path is what is wanted", arguments: [
        "/", "/tmp", "/Users/ravil/Developer", "/Users/ravil/a b/c", "/Users/ravil/it's",
    ])
    func acceptsAbsolutePaths(_ path: String) {
        #expect(WorkspaceDirectory(path) != nil, "\(path) should be a usable directory")
    }

    /// Silent, and unreasonable to expect a user to predict: herdr resolves a
    /// relative path against the **server process's** working directory.
    /// Measured — the CLI run from `/tmp` with `--cwd ../` produced a pane in
    /// `/Users/ravil/Developer/rawillk`, the parent of where `herdr server`
    /// had been started.
    @Test("a relative path is refused, because herdr resolves it somewhere unguessable", arguments: [
        "Developer", "./Developer", "../Developer", "",
    ])
    func refusesRelativePaths(_ path: String) {
        #expect(WorkspaceDirectory(path) == nil)
    }

    /// The one that looks absolute and is not. Arguments reach the host inside
    /// single quotes, so nothing expands `~` — herdr sees a directory that does
    /// not exist and falls back to the home directory, which for `~` alone is
    /// the right answer by accident and for `~/Developer` is not.
    @Test("a leading tilde is refused rather than silently landing in the home directory")
    func refusesTilde() {
        #expect(WorkspaceDirectory.problem(with: "~") == .tilde)
        #expect(WorkspaceDirectory.problem(with: "~/Developer") == .tilde)
    }

    @Test("an empty field is its own answer, not a bad path")
    func emptyIsItsOwnProblem() {
        // The field's resting state, reported separately so a blank one is not
        // shouted at as though the user had typed something wrong.
        #expect(WorkspaceDirectory.problem(with: "") == .empty)
        #expect(WorkspaceDirectory.problem(with: "   ") == .empty)
    }

    /// So `/Users/ravil/` and `/Users/ravil` are one directory rather than two
    /// that suggest different labels.
    @Test("trailing slashes are normalised away, except at the root")
    func normalisesTrailingSlashes() {
        #expect(WorkspaceDirectory("/Users/ravil/")?.path == "/Users/ravil")
        #expect(WorkspaceDirectory("/Users/ravil///")?.path == "/Users/ravil")
        #expect(WorkspaceDirectory("  /tmp  ")?.path == "/tmp")
        #expect(WorkspaceDirectory("/")?.path == "/")
    }

    /// herdr's own default, so the placeholder is not lying about what leaving
    /// the label blank will do. Every row here is a create with no `--label`
    /// run against herdr 0.9.0.
    @Test("the suggested label is the basename, which is what herdr would pick", arguments: [
        ("/Users/ravil/Developer/rawillk/bleat-apple", "bleat-apple"),
        ("/Users/ravil/Developer", "Developer"),
        ("/tmp", "tmp"),
        ("/", "/"),
    ])
    func suggestsTheBasename(path: String, label: String) {
        #expect(WorkspaceDirectory(path)?.suggestedLabel == label)
    }

    /// **The one place this is knowingly wrong, pinned so it is not mistaken
    /// for an oversight.** herdr labels the home directory `~` rather than its
    /// basename — measured — and the phone cannot tell which path that is:
    /// nothing in a peer record holds the host's home directory. Asking would
    /// be a round trip for a placeholder, so the hint is wrong on exactly one
    /// path, for a user who leaves the label blank there.
    @Test("the home directory is the exception, and the phone cannot know it")
    func cannotKnowTheHomeDirectory() {
        #expect(WorkspaceDirectory("/Users/ravil/")?.suggestedLabel == "ravil")
    }

    // MARK: - The command

    @Test("the directory and label are sent as herdr's own flags")
    func buildsTheCommand() async throws {
        let transport = RecordingTransport(reply: try Fixture.data("workspace-create.json"))
        _ = try await HerdrClient(transport: transport)
            .createWorkspace(in: WorkspaceDirectory("/Users/ravil/Developer")!, label: "captured")

        let args = try #require(transport.commands.first)
        #expect(args.contains("--cwd"))
        #expect(args.contains("/Users/ravil/Developer"))
        #expect(args.contains("--label"))
        #expect(args.contains("captured"))
    }

    /// Not the same as sending an empty one: herdr's default is the basename,
    /// which is exactly what the field offers, so an untouched label field must
    /// leave the flag off rather than name the workspace "".
    @Test("an empty label is omitted, so herdr uses the basename it would anyway")
    func omitsAnEmptyLabel() async throws {
        let transport = RecordingTransport(reply: try Fixture.data("workspace-create.json"))
        _ = try await HerdrClient(transport: transport)
            .createWorkspace(in: WorkspaceDirectory("/Users/ravil/Developer")!, label: "")
        #expect(try #require(transport.commands.first).contains("--label") == false)
    }

    /// **The flag that is about somebody else.** Focusing moves the view of
    /// whoever is at the Mac, which is why `agent focus` is banned outright.
    /// The measured default is already not to focus when another workspace
    /// holds it — but a default is not a promise, and this one is cheap.
    ///
    /// What the flag cannot do is stop the *first* workspace in an empty
    /// session being focused; herdr returns `focused: true` there whatever is
    /// asked, and that is the one case where focusing takes nothing from
    /// anybody. Asserted on the command rather than the reply for that reason.
    @Test("focus is never asked for, whoever is at the Mac")
    func neverFocuses() async throws {
        let transport = RecordingTransport(reply: try Fixture.data("workspace-create.json"))
        _ = try await HerdrClient(transport: transport)
            .createWorkspace(in: WorkspaceDirectory("/tmp")!)

        let args = try #require(transport.commands.first)
        #expect(args.contains("--no-focus"))
        #expect(args.contains("--focus") == false)
    }

    // MARK: - Asking whether the directory is there

    @Test("the check asks about the directory and exits 0 either way")
    func directoryCheckCommand() {
        let command = DirectoryCheck.command(for: WorkspaceDirectory("/Users/ravil/Developer")!)
        #expect(command.contains("test -d '/Users/ravil/Developer'"))
        // Both branches echo, so `ShellRunner` never sees a non-zero exit and
        // the answer never arrives as "the host rejected a command".
        #expect(command.contains(DirectoryCheck.present))
        #expect(command.contains(DirectoryCheck.absent))
    }

    /// The whole command is assembled here rather than passed as arguments, so
    /// nothing downstream will quote the path inside it.
    @Test("a path holding a quote cannot break out of the command")
    func quotesThePath() {
        let command = DirectoryCheck.command(for: WorkspaceDirectory("/Users/ravil/it's here")!)
        #expect(command.contains(#"'/Users/ravil/it'\''s here'"#))
    }

    /// **A token, never the whole of stdout.** sshd runs an exec command
    /// through a login shell, `.zshenv` is sourced for every non-interactive
    /// zsh, and profiles print banners — `PeerConnector` had a `printf ok`
    /// probe that any of that defeated. Comparing exactly would refuse every
    /// directory on a Mac with a chatty profile.
    @Test("a banner around the answer does not change it")
    func readsThroughABanner() {
        #expect(DirectoryCheck.exists(inOutput: "Welcome back!\n\(DirectoryCheck.present)\n"))
        #expect(DirectoryCheck.exists(inOutput: "\(DirectoryCheck.absent)\n") == false)
    }

    /// Absence is the default answer: creating a workspace is the side that
    /// should need proof, so a reply saying neither is not taken as a yes.
    @Test("a reply that says neither is not a yes")
    func silenceIsNotAYes() {
        #expect(DirectoryCheck.exists(inOutput: "") == false)
        #expect(DirectoryCheck.exists(inOutput: "some unrelated banner") == false)
    }
}
