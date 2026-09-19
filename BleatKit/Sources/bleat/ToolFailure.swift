#if !os(iOS)   // see main.swift: the console tool runs on macOS and Linux
/// Something the tool cannot do, phrased for the person who typed the command.
///
/// A message rather than a case per cause: these are printed and never
/// switched on. The typed errors — `HerdrError`, `TransportError`,
/// `PairingError` — all come from `BleatKit` and describe themselves; this one
/// exists for the failures that belong to the command line itself.
struct ToolFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
#endif
