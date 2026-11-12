import Foundation

/// The terminals on a host, kept current from `events.subscribe`.
///
/// **Records, not models.** Each terminal is kept as the JSON record the host
/// sent, and every event is applied the way herdr-core applies it to its own
/// mirrors (`remote.rs`, `apply`): `created` and `restarted` replace the
/// record, `removed` drops it, and every other event sets a fixed list of keys.
/// The typed `HcTerminal` is read out afterwards, so an event that sets a key
/// this build does not model still lands, and is there when a later build
/// reads it.
public struct HcTerminalSet: Sendable, Equatable {
    private var records: [String: HcJSON] = [:]
    /// The sequence the set is current at. Events at or below it are already
    /// in it — the snapshot that follows a `missed` carries its own `seq`.
    public private(set) var seq: Int = 0

    public init() {}

    /// Starts over from a snapshot: the reply to `events.subscribe`, or the
    /// params of a `missed` notification. Both are `{seq, terminals}`.
    public mutating func reset(to snapshot: HcJSON) {
        records = [:]
        if case .array(let terminals)? = snapshot["terminals"] {
            for record in terminals {
                if let address = record["address"]?.string { records[address] = record }
            }
        }
        seq = Int(snapshot["seq"]?.number ?? 0)
    }

    /// Applies one `event` notification's params: `{type, terminal, seq, data}`.
    ///
    /// - Returns: whether anything changed.
    @discardableResult
    public mutating func apply(event params: HcJSON) -> Bool {
        if let eventSeq = params["seq"]?.number.map(Int.init) {
            guard eventSeq > seq else { return false }
            seq = eventSeq
        }
        guard let kind = params["type"]?.string, let address = params["terminal"]?.string else {
            return false
        }
        let data = params["data"] ?? .null
        switch kind {
        case "created", "restarted":
            records[address] = data
            return true
        case "removed":
            return records.removeValue(forKey: address) != nil
        default:
            guard case .object(var record)? = records[address] else { return false }
            let before = record
            Self.apply(kind, data: data, to: &record)
            records[address] = .object(record)
            return record != before
        }
    }

    /// `remote.rs`'s `apply`, key for key.
    static func apply(_ kind: String, data: HcJSON, to record: inout [String: HcJSON]) {
        func set(_ keys: String...) {
            for key in keys { record[key] = data[key] ?? .null }
        }
        switch kind {
        case "finished", "lost":
            record["state"] = .string(kind == "lost" ? "live" : "finished")
            if kind == "lost" { record["pid"] = .null }
            set("reason", "exit_code", "signal", "finished_ms")
            record["foreground"] = nil
        case "status": set("status", "records", "reported")
        case "turn": set("turn")
        case "title": set("title")
        case "labels": set("labels")
        case "keep": set("keep")
        case "size": set("cols", "rows")
        case "foreground": record["foreground"] = data
        default: break
        }
    }

    /// Every terminal whose record reads as one. A record that does not is
    /// skipped, not fatal: one odd terminal must not empty the list.
    public var terminals: [HcTerminal] {
        records.values.compactMap { try? $0.decode(HcTerminal.self) }
    }
}
