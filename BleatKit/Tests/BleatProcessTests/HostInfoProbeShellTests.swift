#if os(macOS)
import BleatKit
import Foundation
import Testing

/// The probe pairing runs, against this Mac's own shell.
@Suite("Asking a host what it is, against a real shell")
struct HostInfoProbeShellTests {

    @Test("without the processor sample it says what the host is, and does not wait a second")
    func infoOnly() async throws {
        let shell = LocalShell(home: URL(fileURLWithPath: NSHomeDirectory()))
        let started = ContinuousClock.now
        let output = try await shell.run(shell: HostStatusProbe.command(herdrPath: nil, sampling: false))
        let elapsed = ContinuousClock.now - started

        let status = HostStatusProbe.status(fromOutput: output)
        #expect(status.info.kernel?.hasPrefix("Darwin") == true)
        #expect(status.info.system?.hasPrefix("macOS") == true)
        #expect(status.info.model != nil)
        #expect(status.load.cpuUsage == nil)
        // The sample alone is a second; everything else is a few reads.
        #expect(elapsed < .milliseconds(800))
    }
}
#endif
