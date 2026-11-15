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
        /// How long each reply takes, in order; none past the end.
        private var delays: [Duration]
        init(_ replies: [Result<String, any Error>], delays: [Duration] = []) {
            self.replies = replies
            self.delays = delays
        }
        var commands: [String] { lock.withLock { asked } }
        func run(shell command: String) async throws -> String {
            let (reply, delay) = lock.withLock { () -> (Result<String, any Error>, Duration?) in
                asked.append(command)
                return (replies.isEmpty ? .success("[]") : replies.removeFirst(), delays.isEmpty ? nil : delays.removeFirst())
            }
            if let delay { try? await Task.sleep(for: delay) }
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

    @Test("a rename sends both names, and the list is read again")
    func rename() async {
        let shell = Shell([.success("renamed Clinic to Clinic 2\n"), .success(Self.list)])
        let layouts = model(shell)
        await layouts.perform(.rename(to: "Clinic 2"), on: "Clinic")?.value
        #expect(shell.commands[0].hasSuffix("'rename' 'Clinic' 'Clinic 2'"))
        #expect(layouts.outcome?.message == "renamed Clinic to Clinic 2")
        #expect(shell.commands.count == 2)
    }

    @Test("a refused rename is shown in the script's words, and says Renaming… while it runs")
    func renameRefused() async {
        let taken = ShellError(command: "", exitCode: 1, stderr: "herdr-layout: there's already a layout called 'Studio'\n")
        let layouts = model(Shell([.failure(taken)]))
        let task = layouts.perform(.rename(to: "Studio"), on: "Clinic")
        #expect(layouts.running?.action.progress == "Renaming…")
        await task?.value
        #expect(layouts.outcome == .init(message: "there's already a layout called 'Studio'", failed: true))
        #expect(layouts.stillWorking == nil)
    }

    @Test("a name is sent as typed, trailing space and all")
    func renameAsTyped() async {
        let shell = Shell([.success("renamed Clinic to Clinic \n")])
        await model(shell).perform(.rename(to: "Clinic "), on: "Clinic")?.value
        #expect(shell.commands[0].hasSuffix("'rename' 'Clinic' 'Clinic '"))
    }

    // MARK: - From review

    @Test("a script that ran and failed is still there: the button shows, and the sheet says why")
    func scriptFailedStillAvailable() async {
        let failed = ShellError(command: "", exitCode: 1, stderr: "herdr-layout: herdr-app ls: no window\n")
        let layouts = model(Shell([.failure(failed)]))
        await layouts.load()
        #expect(layouts.availability == .available)
        #expect(layouts.loadProblem == "herdr-app ls: no window")
    }

    @Test("a host that could not be reached is still unknown")
    func unreachableUnknown() async {
        let layouts = model(Shell([.failure(TransportError.channelClosed)]))
        await layouts.load()
        #expect(layouts.availability == .unknown)
    }

    @Test("a 127 that does not name the script is the script failing, not missing")
    func envMissingPython() async {
        let noPython = ShellError(command: "", exitCode: 127, stderr: "env: python3: No such file or directory\n")
        let layouts = model(Shell([.failure(noPython)]))
        await layouts.load()
        #expect(layouts.availability == .available)
    }

    @Test("Close Anyway can be tapped while the list is read again")
    func closeAnywayDuringReload() async {
        let busy = ShellError(command: "", exitCode: 1, stderr: "herdr-layout: 1 agent(s) still working in studio: wait, or close anyway with --force\n")
        let shell = Shell(
            [.failure(busy), .success(Self.list), .success("closed Studio: 1 space(s), saved first\n")],
            delays: [.zero, .milliseconds(300)]
        )
        let layouts = model(shell)
        let first = layouts.perform(.close, on: "Studio")
        for _ in 0..<100 where layouts.stillWorking == nil { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(layouts.stillWorking == "Studio")
        let anyway = layouts.perform(.closeAnyway, on: "Studio")
        #expect(anyway != nil, "the reload after the refusal does not count as an action")
        await first?.value
        await anyway?.value
    }

    /// The first command waits until `release()`; the rest answer at once.
    final class GatedShell: ShellRunner, @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        private var gate: CheckedContinuation<Void, Never>?
        private var released = false
        let first: String, rest: String
        init(first: String, rest: String) { self.first = first; self.rest = rest }

        func run(shell command: String) async throws -> String {
            let isFirst = lock.withLock { calls += 1; return calls == 1 }
            guard isFirst else { return rest }
            await withCheckedContinuation { continuation in
                let open = lock.withLock { () -> Bool in
                    if released { return true }
                    gate = continuation
                    return false
                }
                if open { continuation.resume() }
            }
            return first
        }

        func release() {
            let waiting = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                released = true
                defer { gate = nil }
                return gate
            }
            waiting?.resume()
        }
    }

    @Test("overlapping reads keep the spinner until the last ends, and the latest answer")
    func overlappingLoads() async {
        let shell = GatedShell(first: #"[{"name":"Old"}]"#, rest: #"[{"name":"New"}]"#)
        let gated = LayoutsModel(hostName: "kestrel", hcPath: nil, shell: { shell })
        let slow = Task { await gated.load() }
        // The slow read is in flight before the fast one starts.
        for _ in 0..<100 where !gated.isLoading { await Task.yield() }
        await gated.load()
        #expect(gated.isLoading, "the slower read is still in flight")
        #expect(gated.layouts.map(\.name) == ["New"])
        shell.release()
        await slow.value
        #expect(!gated.isLoading)
        #expect(gated.layouts.map(\.name) == ["New"], "the older answer, arriving last, is dropped")
    }
}
