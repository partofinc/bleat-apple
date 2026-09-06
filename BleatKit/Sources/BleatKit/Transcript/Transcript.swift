import Foundation

/// Parses an agent's JSONL transcript into readable turns.
///
/// Shape verified against a real Claude Code transcript, 6 Sept 2026: 22,064
/// records, 183MB. Every record is one JSON object on one line with `type`,
/// `uuid`, `timestamp` and `message.content`; a content block carries its own
/// `type` — `text`, `thinking`, `tool_use`, `tool_result`.
///
/// **Only `text` blocks are kept, and that is the whole idea.** In that file the
/// conversation was 1,493 of 22,064 records — under 7%. The rest is attachments,
/// tool traffic and bookkeeping (`pr-link`, `atis-latch`, `file-history-snapshot`
/// and a dozen more), and the size is all in the tail: the median record is 548
/// bytes and the largest is 1.3MB.
public enum Transcript {
    /// Turns, oldest first.
    ///
    /// **Every kind of damage is skipped rather than thrown on.** The input is
    /// the *tail* of a file being appended to by a live process, fetched through
    /// a filter — so a truncated first line, a record whose shape has moved, and
    /// a type this build has never heard of are all expected, and none of them
    /// is a reason to show the user nothing. A transcript reader that failed
    /// closed would go blank exactly when the agent was busiest.
    public static func entries(from data: Data) -> [TranscriptEntry] {
        String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { entry(fromLine: $0) }
    }

    private static func entry(fromLine line: Substring) -> TranscriptEntry? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let role = (object["type"] as? String).flatMap(TranscriptEntry.Role.init(rawValue:)),
              let id = object["uuid"] as? String
        else { return nil }

        // Injected by the harness rather than typed or spoken — command output,
        // reminders, hook results. They are addressed to the agent, not to the
        // person reading over its shoulder.
        if object["isMeta"] as? Bool == true { return nil }

        let text = self.text(fromMessage: object["message"])
        // A turn that was only a tool call has no prose. Rendering it as a blank
        // row would space the conversation out with nothing in the gaps.
        guard !text.isEmpty else { return nil }

        return TranscriptEntry(
            id: id,
            role: role,
            text: text,
            timestamp: (object["timestamp"] as? String).flatMap(date(fromISO8601:)),
            isSidechain: object["isSidechain"] as? Bool ?? false
        )
    }

    /// The prose in a message, and nothing else.
    ///
    /// `content` is usually an array of blocks but is sometimes a bare string —
    /// both forms occur in one file, so both are read.
    private static func text(fromMessage message: Any?) -> String {
        guard let message = message as? [String: Any] else { return "" }
        if let plain = message["content"] as? String {
            return plain.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let blocks = message["content"] as? [[String: Any]] else { return "" }
        return blocks
            // `thinking` is deliberately not among these. It is the agent
            // talking to itself, it is the second-largest block kind in the
            // file, and putting it in a reader buries the answer under the
            // working out.
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Fractional seconds are present in practice, but a parser configured for
    /// them rejects a stamp without them, so both are tried. The timestamp is
    /// decoration — a missing one costs a line of a header, not the turn.
    ///
    /// `Date.ISO8601FormatStyle` rather than `ISO8601DateFormatter`: the latter
    /// is a class with mutable state and is not `Sendable`, so it cannot be a
    /// `static let` in a package built under strict concurrency.
    private static func date(fromISO8601 string: String) -> Date? {
        if let date = try? withFraction.parse(string) { return date }
        return try? plain.parse(string)
    }

    private static let withFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let plain = Date.ISO8601FormatStyle()
}
