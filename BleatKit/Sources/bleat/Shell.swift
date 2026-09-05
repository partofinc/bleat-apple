#if os(macOS)   // see main.swift: the console tool is macOS-only
import Foundation

/// Runs a shell command on **this** machine.
///
/// `bleat pair` and `bleat keys` both edit the host's own `authorized_keys`,
/// and both do it by running the very command strings `AuthorizedKeys` builds
/// for the phone rather than a local reimplementation. That is the point: one
/// definition of what a Bleat entry looks like, one definition of how it is
/// removed, and the same `mkdir` lock serialising a revocation against a
/// pairing that may be in flight.
enum Shell {
    /// Captures stderr and puts it in the error.
    ///
    /// CLAUDE.md's rule — never swallow stderr — earns its keep here: the
    /// failures users actually hit are an unwritable `~/.ssh`, a full disk or a
    /// failed `chmod`, and every one of them arrives as a bare non-zero status
    /// with the explanation on stderr. Reporting "exit 1" alone leaves nothing
    /// to act on.
    static func output(_ command: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        try process.run()
        // Read before waiting: a full pipe buffer would deadlock the child.
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errorData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw ToolFailure(detail.isEmpty
                ? "exit \(process.terminationStatus)"
                : "exit \(process.terminationStatus): \(detail)")
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
#endif
