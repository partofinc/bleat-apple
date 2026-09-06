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

    /// **Never wider than herdr's own pane buffer.** herdr renders the pane at
    /// its rect and the program writes into that buffer, so a wider pty makes
    /// the program emit lines herdr then wraps — corruption, not a crop:
    /// characters in the wrong columns and one-letter fragments down the far
    /// edge. Seen on device in landscape, when a phone that could show 100
    /// columns asked a 54-column pane for 100.
    @Test("it shrinks to fit and never grows")
    func neverGrows() {
        let pane = TerminalGrid(cols: 54, rows: 48)
        // Portrait: narrower, so it fits — minus the column herdr keeps.
        #expect(PtyResize.target(viewport: TerminalGrid(cols: 53, rows: 49), pane: pane)
                == TerminalGrid(cols: 53, rows: 48))
        // Landscape on a narrow pane: wider than the pane, so leave it alone.
        #expect(PtyResize.target(viewport: TerminalGrid(cols: 100, rows: 21), pane: pane)
                == TerminalGrid(cols: 53, rows: 21))
        // Wider *and* taller: nothing to do at all.
        #expect(PtyResize.target(viewport: TerminalGrid(cols: 100, rows: 60), pane: pane) == nil)
    }

    /// A session already the right shape must not be touched.
    @Test("a pane that already fits is left alone")
    func leavesAFittingPaneAlone() {
        let pane = TerminalGrid(cols: 54, rows: 48)
        #expect(PtyResize.target(viewport: TerminalGrid(cols: 54, rows: 48), pane: pane) == nil)
        #expect(PtyResize.target(viewport: TerminalGrid(cols: 80, rows: 50), pane: pane) == nil)
    }

    /// One column of the rect belongs to herdr — measured, not assumed: a
    /// 54-column rect is a 53-column pty.
    @Test("herdr's reserved column is accounted for")
    func reservesAColumn() {
        let fit = PtyResize.target(
            viewport: TerminalGrid(cols: 200, rows: 10), pane: TerminalGrid(cols: 54, rows: 48)
        )
        #expect(fit?.cols == 53)
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
