#if !os(iOS)   // see main.swift: the console tool runs on macOS and Linux
import BleatKit
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation

/// `bleat pair` on a host without herdr-core: offers to run herdr-core's
/// official installer here, then carries on pairing.
///
/// The same command the app runs over SSH (`HerdrCoreInstall`), so the two
/// cannot drift. Asked, never assumed: it fetches a script from the network
/// and runs it as this user. Default no.
enum HerdrCoreOffer {
    /// Asks, and installs on a yes.
    ///
    /// - Returns: true when the installer ran and exited 0; the caller looks
    ///   for herdr-core again rather than trusting that.
    /// - Throws: `ToolFailure` when the installer ran and failed.
    static func offer() throws -> Bool {
        print("herdr-core (hc) is not installed on this host, and Bleat needs it.")
        print("It can be installed now with herdr-core's official installer:")
        print("")
        print("  \(HerdrCoreInstall.displayCommand)")
        print("")
        // A pipe or a script gets no prompt, and so no install: a yes nobody
        // typed is not a yes.
        guard isatty(STDIN_FILENO) == 1 else {
            print("Run it, then `bleat pair` again.")
            fflush(stdout)
            return false
        }
        print("Install herdr-core? [y/N] ", terminator: "")
        fflush(stdout)
        let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased()
        guard answer == "y" || answer == "yes" else {
            print("Not installed. Run the command above, then `bleat pair` again.")
            fflush(stdout)
            return false
        }
        try run()
        return true
    }

    /// Runs the installer with this terminal's stdout and stderr, so its
    /// progress and its reasons are shown as it prints them.
    private static func run() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", HerdrCoreInstall.command]
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ToolFailure("the herdr-core installer failed (exit \(process.terminationStatus)); its reason is above")
        }
        print("")
    }
}
#endif
