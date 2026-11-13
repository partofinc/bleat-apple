#if !os(iOS)
import BleatKit
import Foundation

/// `bleat terminals [host] [--watch]`: the terminals on a herdr-core host,
/// most urgent first, over one framed `hc connect` connection.
///
/// With `--watch` it stays subscribed and reprints the list on every change —
/// the events path the app's list runs on, where it can be watched by eye.
enum Terminals {
    static func run(opener: any HcStreamOpening, hcPath: String, watch: Bool) async throws {
        let client = try await HcClient.connect(over: try await opener.openHcConnection(hcPath: hcPath))
        let hello = await client.hello
        let subscription = try await client.subscribe()
        print(header(hello))
        // Each update is printed as it happens, to a pipe or file too.
        setvbuf(stdout, nil, _IOLBF, 0)
        for try await update in subscription.updates {
            switch update.cause {
            case .snapshot:
                print(render(update.terminals))
                guard watch else {
                    await client.close()
                    return
                }
            case .event(let kind, let address):
                print("\n— \(kind) \(address)")
                print(render(update.terminals))
            case .missed:
                print("\n— missed: fresh snapshot")
                print(render(update.terminals))
            }
        }
    }

    static func header(_ hello: HcClient.Hello?) -> String {
        "herdr-core \(hello?.version ?? "?") on \(hello?.coreName ?? "?")"
    }

    /// Live terminals on this core only; mirrors of federated machines are
    /// listed by connecting to those machines.
    static func render(_ set: HcTerminalSet) -> String {
        let rows = set.listed.map { terminal in
            let state = terminal.isUnseenDone ? "done*" : terminal.status.flatMap(\.state).map(label) ?? "-"
            let place = terminal.location.map { [$0.space, $0.tab].compactMap { $0 }.joined(separator: " / ") } ?? ""
            return "\(state.padded(8)) \(terminal.address.padded(6)) \(terminal.displayName.padded(28)) \(place)"
        }
        return rows.isEmpty ? "(no live terminals)" : rows.joined(separator: "\n")
    }

    private static func label(_ state: HcStatus.State) -> String {
        switch state {
        case .idle: "idle"
        case .working: "working"
        case .done: "done"
        case .blocked: "blocked"
        case .error: "error"
        case .other(let raw): raw
        }
    }
}
#endif
