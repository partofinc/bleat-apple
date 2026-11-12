import BleatKit
import Testing
@testable import BleatUI

@Suite("What an answer leaves of a host's problem")
@MainActor
struct HerdrCoreReadinessTests {
    private let installed = HerdrCore.installed(path: "/home/pi/.local/bin/hc", version: "0.1.20")

    /// Wiped, the gate put plain "Install herdr-core" back after every
    /// foreground and invited a retry of an install that cannot work.
    @Test("a failed install's reason survives the next 'missing'")
    func failedInstallSurvivesMissing() {
        let failed = HerdrCoreReadiness.State.installFailed("hc: no build for armv7l")
        #expect(HerdrCoreReadiness.problem(after: .missing, was: failed) == failed)
    }

    @Test("herdr-core being found clears every problem")
    func installedClears() {
        #expect(HerdrCoreReadiness.problem(after: installed, was: .installFailed("hc: x")) == nil)
        #expect(HerdrCoreReadiness.problem(after: installed, was: .unreachable("timeout")) == nil)
    }

    @Test("any answer clears a host being unreachable")
    func answerClearsUnreachable() {
        #expect(HerdrCoreReadiness.problem(after: .missing, was: .unreachable("timeout")) == nil)
        #expect(HerdrCoreReadiness.problem(after: .missing, was: nil) == nil)
    }
}
