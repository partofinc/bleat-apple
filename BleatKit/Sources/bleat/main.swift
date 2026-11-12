// The `bleat` console tool runs on macOS and Linux, never iOS: it drives a real
// terminal (the pairing code's screen) and spawns `hc connect` as a child process.
// SwiftPM cannot gate a target by platform, and a whole-package iOS build
// compiles every target, so the guard is how this target states what it is. The `#if`
// ban in CLAUDE.md is about BleatKit, which exists to be platform-free.
#if !os(iOS)
import BleatKit
import BleatProcess
import Foundation

let usage = """
bleat \(bleatVersion) — the host side of Bleat, a native remote for herdr-core (hc)

Hosts:
  bleat hosts add <name> <user@host[:port]> --key PATH
  bleat hosts list
  bleat hosts remove <name>

On herdr-core (omit <host> for this machine's hc; --hc PATH says which hc):
  bleat terminals  [host] [--watch]          # live terminals, most urgent first

Pairing (host side):
  bleat pair    [--port N] [--endpoint HOST[:PORT]]... [--timeout SECONDS]
  bleat inspect [--port N] [--endpoint HOST[:PORT]]...

Keys this machine accepts (local only — it edits ~/.ssh/authorized_keys):
  bleat keys list
  bleat keys revoke <marker>...

Pairing (the side a phone takes; here for testing the host side):
  bleat redeem <bleat://pair?d=...>
  bleat unpair <name>                       # revoke this device's key, then forget
  bleat peers

  bleat --version
"""

struct Options {
    var port: Int?
    var timeout: Int?
    var endpoints: [String] = []
    var keyPath: String?
    var hcPath: String?
    var watch = false
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
        case "--key":      options.keyPath = next()
        case "--hc":       options.hcPath = next()
        case "--watch":    options.watch = true
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
        case "--timeout":
            guard let text = next() else { fail("--timeout needs a value") }
            guard let seconds = Int(text), seconds > 0 else {
                fail("not a valid timeout: \(text)  (expected whole seconds)")
            }
            options.timeout = seconds
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

/// The SSH transport for a saved host.
func transport(for entry: HostEntry) throws -> SSHTransport {
    SSHTransport(
        host: try entry.host(),
        privateKey: try SSHTransport.privateKey(atPath: (entry.keyPath as NSString).expandingTildeInPath)
    )
}

func describe(_ error: HostArgumentError) -> String {
    switch error {
    case .unknownHost(let name, let known):
        let list = known.isEmpty ? "none saved yet" : known.joined(separator: ", ")
        return "unknown host '\(name)'. Saved hosts: \(list).\nAdd one with: bleat hosts add \(name) user@host --key PATH"
    case .missingTarget:
        return "this command needs a target"
    case .unexpectedArguments(let extra):
        return "unexpected argument(s): \(extra.joined(separator: " "))"
    }
}

let argv = Array(CommandLine.arguments.dropFirst())
// Asked for, so stdout and exit 0. Anywhere on the line, not only first:
// `pair` ignores positionals, so `bleat pair --help` would otherwise install
// an enrollment key and show a live code.
if argv.isEmpty || argv.first == "help" || argv.contains("-h") || argv.contains("--help") {
    print(usage)
    exit(0)
}
// The bare number, so an installer or a Homebrew `test do` can compare it.
// Only the flag: a bare `version` could be a host's name.
if argv.first == "--version" { print(bleatVersion); exit(0) }
let command = argv[0]
var options = parse(Array(argv.dropFirst()))

do {
    if command == "hosts" {
        try Hosts.run(registry: registry, options: options)
        exit(0)
    }

    if command == "inspect" {
        try await Inspect.run(options: options)
        exit(0)
    }

    if command == "pair" {
        try await Pair.run(options: options)
        exit(0)
    }

    // Local, and not `[host]`-taking like the commands below it. See `Keys`:
    // this edits the file that decides who may reach the machine, and doing
    // that down a channel the file itself authorises means a mistake takes away
    // the connection that would fix it.
    if command == "keys" {
        try Keys.run(options: options)
        exit(0)
    }

    // The phone's side. Kept in the tool so the swap — install the device key,
    // verify it, and only then delete the enrollment key — can be run against a
    // real `bleat pair` before there is an app to run it from.
    if command == "redeem" {
        guard options.positional.count == 1 else {
            fail("redeem takes exactly one pairing URL (bleat://pair?d=...)")
        }
        try await Redeem.run(code: options.positional[0])
        exit(0)
    }

    // The phone's side of unpairing. Here for the same reason `redeem` is:
    // taking access away has one failure worth catching — reporting success
    // over a key that still works — and only a real host can show it.
    if command == "unpair" {
        guard options.positional.count == 1 else {
            fail("unpair takes exactly one peer name, as shown by `bleat peers`")
        }
        try await Redeem.unpair(name: options.positional[0], peers: .standard())
        exit(0)
    }

    if command == "peers" {
        try Redeem.list(peers: .standard())
        exit(0)
    }

    if command == "terminals" {
        let (selection, _) = try HostArguments.resolve(
            positional: options.positional, expectsTarget: false, hosts: try registry.all()
        )
        switch selection {
        case .local:
            guard let path = LocalHc.resolve(options.hcPath) else {
                fail("bleat: hc is not on PATH or in ~/.local/bin. Pass --hc PATH.")
            }
            try await Terminals.run(opener: LocalHc(), hcPath: path, watch: options.watch)
        case .saved(let entry):
            let transport = try transport(for: entry)
            // The path is the host's, found the way the app's gate finds it:
            // a bare `hc` misses `~/.local/bin`, which a non-login exec
            // channel does not have on PATH.
            var hcPath = options.hcPath
            if hcPath == nil, case .installed(let found, _) = try await HerdrCoreCheck.find(over: transport) {
                hcPath = found
            }
            guard let hcPath else { fail("bleat: herdr-core is not installed on that host. Pass --hc PATH if it is.") }
            try await Terminals.run(opener: transport, hcPath: hcPath, watch: options.watch)
        }
        exit(0)
    }

    // stderr: this is an error, and a script capturing stdout must not
    // mistake the usage for output.
    FileHandle.standardError.write(Data(("bleat: unknown command '\(command)'\n\n" + usage + "\n").utf8))
    exit(2)
} catch let error as HostArgumentError {
    fail("bleat: \(describe(error))")
} catch let error as HcError {
    fail("bleat: herdr-core: \(error)")
} catch let error as HcProtocolError {
    fail("bleat: \(error)")
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
