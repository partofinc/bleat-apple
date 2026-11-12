import Foundation
import Testing
@testable import BleatKit

@Suite("Installing herdr-core from Bleat")
struct HerdrCoreInstallTests {

    private final class ScriptedShell: ShellRunner, @unchecked Sendable {
        var replies: [Result<String, any Error>]
        private(set) var asked: [String] = []

        init(_ replies: [Result<String, any Error>]) { self.replies = replies }

        func run(shell command: String) async throws -> String {
            asked.append(command)
            return try replies.removeFirst().get()
        }
    }

    private let endpoint = Endpoint(host: "pi.local")

    @Test("the user is shown herdr-core's own one-liner")
    func displayCommand() {
        #expect(HerdrCoreInstall.displayCommand == "curl -fsSL https://releases.herdr.dev/core/install.sh | sh")
    }

    /// Piped, a failed download is an empty script that exits 0.
    @Test("what runs fetches the same script to a file, so a failed download fails")
    func commandFetchesFirst() {
        #expect(HerdrCoreInstall.command == #"/bin/sh -c 'f=$(mktemp) || exit 1; curl -fsSL https://releases.herdr.dev/core/install.sh -o "$f" && sh "$f"; s=$?; rm -f "$f"; exit $s'"#)
    }

    @Test("an install that worked is followed by the lookup, and reads installed")
    func installed() async {
        let shell = ScriptedShell([
            .success("hc 0.1.20 installed into /home/pi/.local/bin/herdr-core.\n"),
            .success("/home/pi/.local/bin/hc\n"),
            .success("hc 0.1.20\n"),
        ])
        let outcome = await HerdrCoreInstall.install(over: shell, endpoint: endpoint)
        #expect(outcome == .installed(.installed(path: "/home/pi/.local/bin/hc", version: "0.1.20"), endpoint: endpoint))
        #expect(shell.asked == [HerdrCoreInstall.command, HerdrCoreLookup.locate, "'/home/pi/.local/bin/hc' --version"])
    }

    @Test("the installer's own reason is what a failure says")
    func installerRefused() async {
        let refused = ShellError(command: HerdrCoreInstall.command, exitCode: 1, stderr: "hc: no build for armv7l")
        let shell = ScriptedShell([.failure(refused)])
        #expect(await HerdrCoreInstall.install(over: shell, endpoint: endpoint) == .failed("hc: no build for armv7l"))
        #expect(shell.asked == [HerdrCoreInstall.command])
    }

    @Test("an installer that exits 0 and leaves no herdr-core is a failure, with what it printed")
    func stillMissing() async {
        let shell = ScriptedShell([.success("Add /x to your PATH to use hc.\n"), .success(""), .success("")])
        guard case .failed(let message) = await HerdrCoreInstall.install(over: shell, endpoint: endpoint) else {
            Issue.record("expected failed")
            return
        }
        #expect(message.contains("still not found"))
        #expect(message.contains("Add /x to your PATH"))
    }

    @Test("the connection going during the install is unreachable, not failed")
    func dropped() async {
        let shell = ScriptedShell([.failure(TransportError.channelClosed)])
        guard case .unreachable = await HerdrCoreInstall.install(over: shell, endpoint: endpoint) else {
            Issue.record("expected unreachable")
            return
        }
    }

    @Test("a cancelled install records nothing")
    func cancelled() async {
        let shell = ScriptedShell([.failure(CancellationError())])
        #expect(await HerdrCoreInstall.install(over: shell, endpoint: endpoint) == .cancelled)
    }
}
