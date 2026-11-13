import Foundation
import Testing
@testable import BleatKit

@Suite("Work that must answer in time")
struct DeadlineRunTests {
    @Test("an answer in time is the answer, and a failure in time is the failure")
    func inTime() async throws {
        #expect(try await Deadline.run(within: .seconds(5)) { 7 } == 7)
        await #expect(throws: ShellError.self) {
            try await Deadline.run(within: .seconds(5)) { () async throws -> Int in
                throw ShellError(command: "x", exitCode: 1, stderr: "")
            }
        }
    }

    /// The work ignores cancellation, as a call waiting on a dead session
    /// does; the answer still comes at the deadline.
    @Test("work that never finishes gives way at the deadline")
    func overran() async {
        let started = ContinuousClock.now
        await #expect(throws: TransportError.self) {
            try await Deadline.run(within: .milliseconds(100)) { () async throws -> Int in
                await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
                return 0
            }
        }
        #expect(ContinuousClock.now - started < .seconds(5))
    }
}
