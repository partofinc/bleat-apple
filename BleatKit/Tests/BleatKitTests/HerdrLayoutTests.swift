import Foundation
import Testing
@testable import BleatKit

@Suite("herdr-layout: a Mac's saved layouts")
struct HerdrLayoutTests {

    @Test("the list reads as the script prints it, newest first, open ones marked")
    func list() throws {
        let layouts = try HerdrLayout.list(inOutput: try Fixture.text("herdr-layout-list.json"))
        #expect(layouts.map(\.name) == ["Clinic", "Studio", "Garage"])
        #expect(layouts.map(\.isOpen) == [false, true, false])
        #expect(layouts[0].spaces.count == 5)
        #expect(layouts[0].claude == 5)
        #expect(layouts[2].panes == 7)
        #expect(layouts[0].savedAt == Date(timeIntervalSince1970: 1_794_719_194))
    }

    @Test("a banner before the list does no harm, and a record that does not read is skipped")
    func lenient() throws {
        let output = "Welcome to kestrel\n" + #"[{"name":"A","open":1},{"open":2},{"name":"B","saved_at":null}]"#
        let layouts = try HerdrLayout.list(inOutput: output)
        #expect(layouts.map(\.name) == ["A", "B"])
        #expect(layouts[1].savedAt == nil)
        #expect(layouts[1].spaces.isEmpty)
    }

    @Test("an empty list is no layouts; no list at all is contract drift")
    func emptyAndMissing() throws {
        #expect(try HerdrLayout.list(inOutput: "[]\n").isEmpty)
        #expect(throws: DecodingError.self) { try HerdrLayout.list(inOutput: "no saved layouts\n") }
    }

    @Test("each action is the script's own arguments")
    func arguments() {
        #expect(HerdrLayoutCommand.list.arguments == ["list", "--json"])
        #expect(HerdrLayoutCommand.restore("Clinic").arguments == ["restore", "Clinic"])
        #expect(HerdrLayoutCommand.update("Clinic").arguments == ["update", "Clinic"])
        #expect(HerdrLayoutCommand.close("Clinic", force: false).arguments == ["close", "Clinic"])
        #expect(HerdrLayoutCommand.close("Clinic", force: true).arguments == ["close", "Clinic", "--force"])
    }

    @Test("the script travels inside single quotes, so it holds none")
    func noSingleQuotes() {
        #expect(!HerdrLayoutCommand.script.contains("'"))
    }

    @Test("refusals read in the script's words, and the two that matter are told apart")
    func refusals() {
        let busy = ShellError(
            command: "", exitCode: 1,
            stderr: "herdr-layout: 2 agent(s) still working in clinic-api: wait, or close anyway with --force\n"
        )
        #expect(HerdrLayoutCommand.isStillWorking(busy))
        #expect(HerdrLayoutCommand.refusal(in: busy) == "2 agent(s) still working in clinic-api: wait, or close anyway with --force")
        let missing = ShellError(command: "", exitCode: 127, stderr: "sh: line 5: herdr-layout: command not found\n")
        #expect(HerdrLayoutCommand.isMissing(missing))
        #expect(!HerdrLayoutCommand.isStillWorking(missing))
        #expect(!HerdrLayoutCommand.isMissing(busy))
        // From review: `env` exits 127 too when the script is there and
        // python3 is not.
        let noPython = ShellError(command: "", exitCode: 127, stderr: "env: python3: No such file or directory\n")
        #expect(!HerdrLayoutCommand.isMissing(noPython))
    }

    @Test("the summary is the last line printed")
    func summary() {
        let output = "note: something\nrestored Clinic: 5/5 space(s), 5 pane(s), 5 Claude (5 by session id, 0 with --continue)\n\n"
        #expect(HerdrLayoutCommand.summary(inOutput: output)?.hasPrefix("restored Clinic: 5/5") == true)
        #expect(HerdrLayoutCommand.summary(inOutput: "\n") == nil)
    }

    // MARK: - The command, run for real against a stand-in script

    // macOS only: the package's tests also build for iOS, which has no
    // `Process`. `swift test` runs these.
    #if os(macOS)

    /// A `herdr-layout` that prints its arguments one per line, says
    /// something on stderr and exits with `status`, in a folder of its own.
    private func standIn(status: Int32) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "herdr-layout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let script = folder.appending(path: "herdr-layout")
        try "#!/bin/sh\nfor a in \"$@\"; do echo \"$a\"; done\necho \"herdr-layout: said no\" >&2\nexit \(status)\n"
            .write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return folder
    }

    /// Runs `command` as an SSH login would hand it to zsh, with a bare `PATH`.
    private func run(_ command: String) throws -> (status: Int32, out: String, err: String) {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/zsh")
        process.arguments = ["-c", command]
        process.environment = ["HOME": "/nonexistent", "PATH": "/usr/bin:/bin"]
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }

    @Test("it finds the script beside hc, passes a name intact, and keeps its status and stderr")
    func runsForReal() throws {
        let folder = try standIn(status: 1)
        defer { try? FileManager.default.removeItem(at: folder) }
        let name = "it's a layout"
        let result = try run(HerdrLayoutCommand.restore(name).command(hcPath: folder.appending(path: "hc").path))
        #expect(result.status == 1)
        #expect(result.out == "restore\n\(name)\n")
        #expect(result.err == "herdr-layout: said no\n")
    }

    @Test("a host without the script says not found, status 127")
    func missingForReal() throws {
        let result = try run(HerdrLayoutCommand.list.command(hcPath: nil))
        #expect(result.status == 127)
        #expect(result.out.isEmpty)
    }
    #endif
}
