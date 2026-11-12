import Foundation
@testable import BleatKit

/// A shell that answers each command from a script, in the order asked, and
/// records what was asked. Shared by the herdr-core check and install tests.
final class ScriptedShell: ShellRunner, @unchecked Sendable {
    var replies: [Result<String, any Error>]
    private(set) var asked: [String] = []

    init(_ replies: [Result<String, any Error>]) { self.replies = replies }

    func run(shell command: String) async throws -> String {
        asked.append(command)
        return try replies.removeFirst().get()
    }
}
