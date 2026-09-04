// The `bleat` console tool is macOS-only: it drives a real terminal (termios
// raw mode, SIGWINCH) and spawns `herdr` as a child process. SwiftPM cannot
// gate a target by platform, and a whole-package iOS build compiles every
// target, so the guard is how this target states what it already is. The `#if`
// ban in CLAUDE.md is about BleatKit, which exists to be platform-free.
#if os(macOS)
import BleatKit
import BleatProcess
import Foundation

let usage = """
bleat — native remote for Herdr (Phase 1)

Hosts:
  bleat hosts add <name> <user@host[:port]> --key PATH [--herdr PATH] [--session NAME]
  bleat hosts list
  bleat hosts remove <name>

Against a host (omit <host> to use the local herdr):
  bleat sessions   [host]
  bleat workspaces [host] [--session NAME]
  bleat agents     [host] [--session NAME]
  bleat attach     [host] <target> [--takeover] [--cols N] [--rows M]
  bleat schema     [host]

Pairing:
  bleat inspect [--port N] [--endpoint HOST[:PORT]]...

Ctrl-] detaches: sends terminal.release and exits cleanly.
"""

struct Options {
    var session: String?
    var port: Int?
    var endpoints: [String] = []
    var keyPath: String?
    var herdrPath: String?
    var takeover = false
    var cols: Int?
    var rows: Int?
    var positional: [String] = []
}

func parse(_ argv: [String]) -> Options {
    var options = Options()
    var index = argv.startIndex
    while index < argv.endIndex {
        func next() -> String? {
            index += 1
            return index < argv.endIndex ? argv[index] : nil
        }
        switch argv[index] {
        case "--session":  options.session = next()
        case "--key":      options.keyPath = next()
        case "--herdr":    options.herdrPath = next()
        case "--takeover": options.takeover = true
        case "--cols":     options.cols = next().flatMap(Int.init)
        case "--rows":     options.rows = next().flatMap(Int.init)
        case "--port":
            // Validated here, not passed through: an out-of-range port makes
            // `Endpoint(string:)` reject every endpoint the QR carries, so the
            // scan fails as "damaged code" with nothing pointing at the port.
            // A non-numeric value used to become 22 silently, which is worse
            // than refusing it.
            guard let text = next() else { fail("--port needs a value") }
            guard let port = Int(text), (1...65535).contains(port) else {
                fail("not a valid port: \(text)  (expected 1-65535)")
            }
            options.port = port
        // Overlays like Twingate never tell the host its own resolvable name,
        // so those endpoints are supplied rather than detected.
        case "--endpoint":
            // A missing value is the same class of mistake as an invalid one;
            // silently ignoring `--endpoint` at the end of the line would drop
            // an endpoint the user believes they supplied.
            guard let text = next() else { fail("--endpoint needs a value") }
            // Validated now for a prompt error, but kept as text: the default
            // port is not known until --port has been seen, and it may appear
            // after this flag.
            guard Endpoint(string: text) != nil else {
                fail("not a valid endpoint: \(text)  (expected host, host:port or [v6]:port)")
            }
            options.endpoints.append(text)
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

let registry = HostRegistry.standard()

/// Builds the transport for a resolved host.
///
/// With no host the local `herdr` is used, which is what makes the tool usable
/// on the machine running Herdr without inventing a loopback SSH hop.
func makeTransport(_ selection: HostSelection, session: String?) throws -> any HerdrTransport {
    switch selection {
    case .local:
        return LocalProcessTransport(session: session)
    case .saved(let entry):
        return SSHTransport(
            host: try entry.host(),
            privateKey: try SSHTransport.privateKey(atPath: (entry.keyPath as NSString).expandingTildeInPath),
            herdrPath: entry.herdrPath,
            session: session ?? entry.session
        )
    }
}

func describe(_ error: HostArgumentError) -> String {
    switch error {
    case .unknownHost(let name, let known):
        let list = known.isEmpty ? "none saved yet" : known.joined(separator: ", ")
        return "unknown host '\(name)'. Saved hosts: \(list).\nAdd one with: bleat hosts add \(name) user@host --key PATH"
    case .missingTarget:
        return "attach needs a target, e.g. w1:p1"
    case .unexpectedArguments(let extra):
        return "unexpected argument(s): \(extra.joined(separator: " "))"
    }
}

let argv = Array(CommandLine.arguments.dropFirst())
guard let command = argv.first else { print(usage); exit(0) }
var options = parse(Array(argv.dropFirst()))

do {
    if command == "hosts" {
        try Hosts.run(registry: registry, options: options)
        exit(0)
    }

    if command == "inspect" {
        try Inspect.run(options: options)
        exit(0)
    }

    let (selection, rest) = try HostArguments.resolve(
        positional: options.positional,
        expectsTarget: command == "attach",
        hosts: try registry.all()
    )
    let client = HerdrClient(transport: try makeTransport(selection, session: options.session))

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
        let target = rest[0]
        try await Attach.run(
            client: client,
            target: target,
            cols: options.cols ?? 80,
            rows: options.rows ?? 24,
            takeover: options.takeover
        )

    default:
        print(usage)
        exit(2)
    }
} catch let error as HostArgumentError {
    fail("bleat: \(describe(error))")
} catch let error as HerdrError {
    fail("\(error)")
} catch let error as TransportError {
    fail("bleat: \(Describe.transport(error))")
} catch {
    fail("bleat: \(error)")
}

extension String {
    func padded(_ width: Int) -> String {
        count >= width ? self : self + String(repeating: " ", count: width - count)
    }
}

#endif
