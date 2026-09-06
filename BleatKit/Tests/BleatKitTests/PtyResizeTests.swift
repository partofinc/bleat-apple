import Foundation
import Testing
@testable import BleatKit

@Suite("Resizing a pane's pty")
struct PtyResizeTests {

    /// The one thing that actually reflows a pane. `observe --cols` crops and
    /// no stream client can change a pane's grid, but the program inside wraps
    /// to its *pty* — and a pty can be resized from outside. Verified live: a
    /// pane's pty set to 40 columns and observed at 40 came back genuinely
    /// wrapped, with a continuation line rather than a cut one.
    @Test("the command sets the tty of the pane's process")
    func buildsTheCommand() throws {
        let command = try #require(PtyResize.command(pid: 91461, cols: 53, rows: 48))
        #expect(command.contains("ps -o tty= -p 91461"))
        #expect(command.contains("stty -f \"/dev/$t\" rows 48 cols 53"))
    }

    /// Best effort throughout: a pane whose program has no controlling terminal
    /// simply cannot be resized, and the stream should open anyway at whatever
    /// size the pane already has.
    @Test("it never fails the caller")
    func neverFails() throws {
        let command = try #require(PtyResize.command(pid: 1, cols: 40, rows: 30))
        #expect(command.contains("\"$t\" != \"??\""))
        #expect(command.hasSuffix("true"))
    }

    /// The pid arrives as JSON from the host and is interpolated into a command
    /// that host will run, so it is checked rather than trusted — the same
    /// posture as `TranscriptCommand` and `AuthorizedKeys.Marker`.
    @Test(
        "implausible values are refused",
        arguments: [(0, 80, 24), (-1, 80, 24), (99_999_999, 80, 24),
                    (100, 0, 24), (100, 80, 0), (100, 99_999, 24)]
    )
    func refusesImplausible(pid: Int, cols: Int, rows: Int) {
        #expect(PtyResize.command(pid: pid, cols: cols, rows: rows) == nil)
    }

    /// **Growing is allowed.** An earlier version refused, on the strength of
    /// an experiment against a buffer already corrupted by a stray command.
    /// Re-measured on a clean pane: a 53-column pty grown to 100 reflowed and
    /// came back 100 wide. herdr's rect is not a ceiling on the pty.
    @Test("it matches the screen, growing or shrinking")
    func matchesTheScreen() {
        let pane = TerminalGrid(cols: 53, rows: 48)
        #expect(PtyResize.target(viewport: TerminalGrid(cols: 100, rows: 21), pane: pane)
                == TerminalGrid(cols: 100, rows: 21))
        #expect(PtyResize.target(viewport: TerminalGrid(cols: 40, rows: 30), pane: pane)
                == TerminalGrid(cols: 40, rows: 30))
    }

    /// A pane already the right shape must not be touched — a resize costs a
    /// repaint, and repainting for nothing flickers.
    @Test("a pane already this size is left alone")
    func leavesAMatchingPaneAlone() {
        let pane = TerminalGrid(cols: 53, rows: 48)
        #expect(PtyResize.target(viewport: pane, pane: pane) == nil)
    }

    /// `pane process-info` nests one level deeper than the other commands, and
    /// falls back to the shell when nothing is running in front of it — a plain
    /// pane still has a pty worth sizing.
    @Test("process info yields a pid, foreground first")
    func decodesProcessInfo() async throws {
        let json = Data("""
        {"id":"cli:pane:process_info","result":{"process_info":{
          "foreground_process_group_id":91461,
          "foreground_processes":[{"argv":["claude"],"cmdline":"claude","pid":91461}],
          "pane_id":"w1:p1","shell_pid":90844},"type":"pane_process_info"}}
        """.utf8)
        let client = HerdrClient(transport: FakeTransport(
            responses: ["pane process-info --pane w1:p1": json]
        ))
        let info = try await client.paneProcessInfo(target: "w1:p1")
        #expect(info.pid == 91461)
        #expect(info.shellPID == 90844)
    }

    @Test("a pane with no foreground process falls back to its shell")
    func fallsBackToShell() async throws {
        let json = Data("""
        {"result":{"process_info":{"pane_id":"w1:p1","shell_pid":90844},
         "type":"pane_process_info"}}
        """.utf8)
        let client = HerdrClient(transport: FakeTransport(
            responses: ["pane process-info --pane w1:p1": json]
        ))
        let info = try await client.paneProcessInfo(target: "w1:p1")
        #expect(info.pid == 90844)
    }
}
