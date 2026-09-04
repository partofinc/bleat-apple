import BleatKit
import Foundation

// Phase 1 console tool. Transport wiring lands with SSHTransport; until then
// this binary exists so the target builds and the CLI surface has a home.
let args = Array(CommandLine.arguments.dropFirst())

guard let command = args.first else {
    print("""
    bleat — native remote for Herdr

    Usage:
      bleat hosts add <name> <user@host[:port]> --key PATH
      bleat sessions <host>
      bleat agents <host>
      bleat attach <host> <target> [--takeover]
      bleat schema <host>
    """)
    exit(0)
}

FileHandle.standardError.write(Data("bleat: '\(command)' needs a transport; not wired yet\n".utf8))
exit(2)
