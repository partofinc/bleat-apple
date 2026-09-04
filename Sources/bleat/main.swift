import BleatKit
import Foundation

// Phase 1 console tool. Transport is local-process for now; SSHTransport slots
// in behind the same `HerdrTransport` without touching anything below.

let usage = """
bleat — native remote for Herdr (Phase 1)

Usage:
  bleat sessions                       named sessions on this host
  bleat workspaces [--session NAME]    workspaces, by attention state
  bleat agents     [--session NAME]    agents, blocked first
  bleat attach <target> [--session NAME] [--takeover] [--cols N] [--rows M]
  bleat schema     [--session NAME]    print api schema JSON

Ctrl-] detaches: sends terminal.release and exits cleanly.
"""

struct Options {
    var session: String?
    var takeover = false
    var cols = 80
    var rows = 24
    var positional: [String] = []
}

func parse(_ argv: [String]) -> Options {
    var options = Options()
    var index = argv.startIndex
    while index < argv.endIndex {
        switch argv[index] {
        case "--session":  index += 1; options.session = index < argv.endIndex ? argv[index] : nil
        case "--takeover": options.takeover = true
        case "--cols":     index += 1; options.cols = Int(index < argv.endIndex ? argv[index] : "") ?? 80
        case "--rows":     index += 1; options.rows = Int(index < argv.endIndex ? argv[index] : "") ?? 24
        default:           options.positional.append(argv[index])
        }
        index += 1
    }
    return options
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let argv = Array(CommandLine.arguments.dropFirst())
guard let command = argv.first else { print(usage); exit(0) }
let options = parse(Array(argv.dropFirst()))

let client = HerdrClient(
    transport: LocalProcessTransport(session: options.session)
)

do {
    switch command {
    case "sessions":
        for session in try await client.sessions() {
            print("\(session.running ? "●" : "○") \(session.name)\(session.isDefault ? "  (default)" : "")")
        }

    case "workspaces":
        for workspace in try await client.workspaces() {
            print("\(workspace.agentStatus.rawValue.padded(9)) \(workspace.workspaceID.padded(18)) \(workspace.label)")
        }

    case "agents":
        for agent in try await client.agents() {
            let title = agent.terminalTitleStripped ?? agent.terminalTitle ?? ""
            print("\(agent.agentStatus.rawValue.padded(9)) \(agent.paneID.padded(18)) \(title.padded(24)) \(agent.cwd ?? "")")
        }

    case "schema":
        FileHandle.standardOutput.write(try await client.schema())

    case "attach":
        guard let target = options.positional.first else { fail("attach needs a target, e.g. w1:p1") }
        try await Attach.run(
            client: client,
            target: target,
            cols: options.cols,
            rows: options.rows,
            takeover: options.takeover
        )

    default:
        print(usage)
        exit(2)
    }
} catch let error as HerdrError {
    fail("\(error)")
} catch {
    fail("bleat: \(error)")
}

extension String {
    func padded(_ width: Int) -> String {
        count >= width ? self : self + String(repeating: " ", count: width - count)
    }
}
