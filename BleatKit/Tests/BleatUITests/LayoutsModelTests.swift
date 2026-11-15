import BleatKit
import Foundation
import Testing
@testable import BleatUI

/// The Layouts sheet's model against a shell that answers as `herdr-layout`
/// does. No network.
@Suite("A Mac's saved layouts, from the phone")
@MainActor
struct LayoutsModelTests {

    /// Answers each command from a script of replies, in order, and records them.
    final class Shell: ShellRunner, @unchecked Sendable {
        private let lock = NSLock()
        private var replies: [Result<String, any Error>]
        private var asked: [String] = []
        init(_ replies: [Result<String, any Error>]) { self.replies = replies }
        var commands: [String] { lock.withLock { asked } }
        func run(shell command: String) async throws -> String {
            let reply = lock.withLock { () -> Result<String, any Error> in
                asked.append(command)
                return replies.isEmpty ? .success("[]") : replies.removeFirst()
            }
            return try reply.get()
        }
    }

    /// `Fixtures/herdr-layout-list.json`, as the script prints it.
    private static let list: String = {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Fixtures/herdr-layout-list.json")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }()
    private static let missing = ShellError(command: "", exitCode: 127, stderr: "sh: line 5: herdr-layout: command not found\n")

    private func model(_ shell: Shell) -> LayoutsModel {
        LayoutsModel(hostName: "kestrel", hcPath: "/Users/robin/.local/bin/hc", shell: { shell })
    }

    @Test("a host with the script has layouts")
    func available() async {
        let layouts = model(Shell([.success(Self.list)]))
        await layouts.load()
        #expect(layouts.availability == .available)
        #expect(layouts.layouts.map(\.name) == ["Clinic", "Studio", "Garage"])
    }

    @Test("a host without it has none, and no button")
    func absent() async {
        let layouts = model(Shell([.failure(Self.missing)]))
        await layouts.load()
        #expect(layouts.availability == .absent)
        #expect(layouts.layouts.isEmpty)
    }

    @Test("a read that fails otherwise keeps what was known, and says why")
    func failedReadKeeps() async {
        let layouts = model(Shell([.success(Self.list), .failure(TransportError.channelClosed)]))
        await layouts.load()
        await layouts.load()
        #expect(layouts.availability == .available)
        #expect(layouts.layouts.count == 3)
        #expect(layouts.loadProblem == "the connection closed")
    }

    @Test("a restore says what it did, and the list is read again")
    func restore() async {
        let shell = Shell([
            .success("restored Clinic: 5/5 space(s), 5 pane(s), 5 Claude (5 by session id, 0 with --continue)\n"),
            .success(Self.list),
        ])
        let layouts = model(shell)
        await layouts.perform(.restore, on: "Clinic")?.value
        #expect(layouts.outcome?.failed == false)
        #expect(layouts.outcome?.message.hasPrefix("restored Clinic: 5/5") == true)
        #expect(shell.commands.count == 2)
        #expect(shell.commands[0].hasSuffix("'restore' 'Clinic'"))
        #expect(shell.commands[1].hasSuffix("'list' '--json'"))
        #expect(layouts.running == nil)
    }

    @Test("one action at a time")
    func oneAtATime() async {
        let layouts = model(Shell([]))
        let first = layouts.perform(.update, on: "Studio")
        #expect(layouts.perform(.restore, on: "Clinic") == nil)
        await first?.value
    }

    @Test("a close refused for working agents offers to close anyway, which forces it")
    func stillWorking() async {
        let busy = ShellError(
            command: "", exitCode: 1,
            stderr: "herdr-layout: 1 agent(s) still working in studio: wait, or close anyway with --force\n"
        )
        let shell = Shell([.failure(busy), .success(Self.list), .success("closed Studio: 1 space(s), saved first\n")])
        let layouts = model(shell)
        await layouts.perform(.close, on: "Studio")?.value
        #expect(layouts.stillWorking == "Studio")
        #expect(layouts.outcome == nil)
        await layouts.perform(.closeAnyway, on: "Studio")?.value
        #expect(shell.commands[2].hasSuffix("'close' 'Studio' '--force'"))
        #expect(layouts.outcome?.message == "closed Studio: 1 space(s), saved first")
    }

    @Test("any other refusal is shown in the script's words")
    func refusal() async {
        let open = ShellError(
            command: "", exitCode: 1,
            stderr: "herdr-layout: Studio is already open: `herdr-layout show Studio` goes to it (--force opens another copy, which runs its Claude sessions twice)\n"
        )
        let layouts = model(Shell([.failure(open)]))
        await layouts.perform(.restore, on: "Studio")?.value
        #expect(layouts.outcome?.failed == true)
        #expect(layouts.outcome?.message.hasPrefix("Studio is already open") == true)
    }

    @Test("the command puts the directory hc was found in on PATH")
    func hcDirectory() async {
        let shell = Shell([.success("[]")])
        await model(shell).load()
        #expect(shell.commands.first?.contains("sh '/Users/robin/.local/bin' 'list'") == true)
    }
}
