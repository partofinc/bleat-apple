import Foundation
import Testing
@testable import BleatKit

@Suite("Errors parsed from stderr")
struct HerdrErrorTests {

    private func error(_ stderr: String, exitCode: Int32 = 1) -> HerdrError {
        HerdrError.fromStderr(
            command: ["workspace", "list"],
            exitCode: exitCode,
            stderr: Data(stderr.utf8)
        )
    }

    @Test("the structured body is preferred over raw text")
    func structured() {
        // Real output from herdr 0.8.2 against a stopped session.
        let raw = #"{"id":"cli:workspace:list","error":{"code":"server_not_running","message":"no herdr server is running at /x/herdr.sock"}}"#
        let parsed = error(raw)
        #expect(parsed.code == "server_not_running")
        #expect(parsed.message == "no herdr server is running at /x/herdr.sock")
        #expect(parsed.exitCode == 1)
        // stderr is never discarded, even when the body parsed.
        #expect(parsed.stderr == raw)
    }

    @Test("an error line is found among noise")
    func amongNoise() {
        // A login shell can print banners before herdr says anything.
        let parsed = error("""
        Warning: something unrelated
        not json at all
        {"id":"cli:agent:list","error":{"code":"bad_target","message":"no such pane"}}
        """)
        #expect(parsed.code == "bad_target")
        #expect(parsed.message == "no such pane")
    }

    @Test("non-JSON stderr falls back to raw text rather than throwing")
    func plainText() {
        let parsed = error("env: herdr: No such file or directory\n")
        #expect(parsed.code == nil)
        #expect(parsed.message == nil)
        #expect(parsed.stderr.contains("No such file or directory"))
        // The description must still be useful with no structured body.
        #expect(parsed.description.contains("No such file or directory"))
    }

    @Test("empty stderr still produces a usable error")
    func empty() {
        let parsed = error("", exitCode: 127)
        #expect(parsed.code == nil)
        #expect(parsed.exitCode == 127)
        #expect(parsed.description.contains("workspace list"))
    }

    @Test("a non-error JSON line is not mistaken for a body")
    func ignoresNonErrorJSON() {
        // HerdrErrorEnvelope requires `error`, so a success payload must not latch.
        let parsed = error(#"{"id":"cli:workspace:list","result":{"workspaces":[]}}"#)
        #expect(parsed.code == nil)
        #expect(parsed.message == nil)
    }

    @Test("description leads with the command and exit code")
    func description() {
        let parsed = error(#"{"error":{"code":"x","message":"boom"}}"#, exitCode: 2)
        #expect(parsed.description.contains("herdr workspace list"))
        #expect(parsed.description.contains("(2)"))
        #expect(parsed.description.contains("boom"))
    }
}
