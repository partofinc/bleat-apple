import BleatKit
import Foundation
import Testing
@testable import BleatUI

/// Which of CLAUDE.md's three error classes a thrown error lands in.
///
/// **This is the test for a lie the app told on a real host.** A `phone`
/// session whose herdr server was one protocol version behind answered the
/// command and said exactly what was wrong — "restart the Herdr server before
/// using this command" — and the screen titled it *Could not reach the host*,
/// which sent the user to check a network that was working perfectly. Every
/// failure shared one title because `Loadable` carried only a string.
///
/// The same distinction `TransportError.authenticationFailed` exists for, one
/// layer up: reached and refused is not could not reach.
@Suite("Classifying a failed load")
struct LoadFailureTests {

    private func herdrError(code: String?, message: String?) -> HerdrError {
        HerdrError(
            command: ["workspace", "list"],
            exitCode: 1,
            stderr: #"{"id":"cli:workspace:list","error":{"code":"protocol_mismatch"}}"#,
            code: code,
            message: message
        )
    }

    /// Captured off the live host, 8 Sept 2026.
    private let protocolMismatch = "client protocol 22 is newer than server protocol 20; "
        + "restart the Herdr server before using this command."

    @Test("a herdr error is the host saying no, not the host being unreachable")
    func herdrErrorIsNotANetworkFailure() {
        let failure = ErrorMessage.failure(of: herdrError(code: "protocol_mismatch", message: protocolMismatch))
        #expect(failure.cause == .hostSaidNo)
        // Herdr's own sentence, not `description` — which prefixes "herdr
        // workspace list failed (1):", right in a terminal and noise on a
        // phone. The text the host wrote is the actionable part.
        #expect(failure.message == protocolMismatch)
    }

    /// A herdr error with no structured body still has to say something. The
    /// envelope is on stderr and can be absent — an older herdr, or a command
    /// that failed before it could write one.
    @Test("a herdr error with no message falls back rather than showing nothing")
    func herdrErrorWithoutAMessage() {
        let failure = ErrorMessage.failure(of: herdrError(code: nil, message: nil))
        #expect(failure.cause == .hostSaidNo)
        #expect(failure.message.contains("workspace list"))
        #expect(!failure.message.isEmpty)
    }

    @Test("a transport failure is the one that really is about the network")
    func transportErrorIsUnreachable() {
        let failure = ErrorMessage.failure(of: TransportError.connectionFailed("none of 3 addresses could be reached"))
        #expect(failure.cause == .unreachable)
    }

    /// Reached, answered, and the reply did not fit this build — CLAUDE.md's
    /// third class. Not a network problem and not the host refusing.
    @Test("contract drift is its own answer")
    func decodingErrorIsUnreadable() {
        let error = DecodingError.keyNotFound(
            HerdrCodingKey(stringValue: "workspaces")!,
            DecodingError.Context(codingPath: [], debugDescription: "")
        )
        let failure = ErrorMessage.failure(of: error)
        #expect(failure.cause == .unreadable)
        // Not a dump of coding keys.
        #expect(failure.message.contains("different version of herdr"))
    }

    /// The screen reads the failure off the state, so both cases that carry one
    /// have to hand it over — a `stale` refresh keeps its rows *and* has to say
    /// why the refresh failed.
    @Test("both failing states carry the cause, not just a message")
    func loadableExposesTheCause() {
        let failed = Loadable<[Int]>.failed(.hostSaidNo("no"))
        #expect(failed.failure?.cause == .hostSaidNo)
        #expect(failed.failureMessage == "no")

        let stale = Loadable.stale([1, 2], LoadFailure.unreachable("dropped"))
        #expect(stale.failure?.cause == .unreachable)
        #expect(stale.value == [1, 2])

        #expect(Loadable<[Int]>.loading.failure == nil)
        #expect(Loadable.loaded([1]).failure == nil)
    }
}

/// `DecodingError` needs a `CodingKey`, and the test has no model to borrow one
/// from that would not tie this to that model's shape.
private struct HerdrCodingKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}
