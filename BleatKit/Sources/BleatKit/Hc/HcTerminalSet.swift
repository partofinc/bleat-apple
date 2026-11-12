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
///
/// **Decoded once per change.** Each record's `HcTerminal` is cached and
/// re-read only when an event touched that record. Re-reading every record on
/// every event cost a JSON round trip per terminal, mirrors and finished ones
/// included, on the main actor.
public struct HcTerminalSet: Sendable, Equatable {
    private var records: [String: HcJSON] = [:]
    /// Each record read as a terminal; absent when the record does not read.
    private var decoded: [String: HcTerminal] = [:]
    /// The sequence the set is current at. Events at or below it are already
    /// in it — the snapshot that follows a `missed` carries its own `seq`.
    public private(set) var seq: Int = 0

    public init() {}

    /// Starts over from a snapshot: the reply to `events.subscribe`, or the
    /// params of a `missed` notification. Both are `{seq, terminals}`.
    public mutating func reset(to snapshot: HcJSON) {
        records = [:]
        decoded = [:]
        if case .array(let terminals)? = snapshot["terminals"] {
            for record in terminals {
                if let address = record["address"]?.string { store(record, at: address) }
            }
        }
        seq = snapshot["seq"]?.int ?? 0
    }

    /// Applies one `event` notification's params: `{type, terminal, seq, data}`.
    ///
    /// - Returns: whether anything changed.
    @discardableResult
    public mutating func apply(event params: HcJSON) -> Bool {
        if let eventSeq = params["seq"]?.int {
            guard eventSeq > seq else { return false }
            seq = eventSeq
        }
        guard let kind = params["type"]?.string, let address = params["terminal"]?.string else {
            return false
        }
        let data = params["data"] ?? .null
        switch kind {
        case "created", "restarted":
            store(data, at: address)
            return true
        case "removed":
            decoded[address] = nil
            return records.removeValue(forKey: address) != nil
        default:
            guard case .object(var record)? = records[address] else { return false }
            let before = record
            Self.apply(kind, data: data, to: &record)
            guard record != before else { return false }
            store(.object(record), at: address)
            return true
        }
    }

    private mutating func store(_ record: HcJSON, at address: String) {
        records[address] = record
        decoded[address] = try? record.decode(HcTerminal.self)
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
        Array(decoded.values)
    }

    /// What a host's list shows: its own live terminals, most urgent first.
    ///
    /// Mirrors of machines this host federates are left out — Bleat pairs
    /// those directly, and would list them twice — and so are finished ones.
    /// One definition, for the app's list and `bleat terminals` alike.
    public var listed: [HcTerminal] {
        decoded.values.filter { $0.isLocal && $0.isLive }.sortedByAttention()
    }
}
