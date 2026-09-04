import Foundation

/// Extracts usable endpoints from `ifconfig` output.
///
/// Parsing text rather than calling `getifaddrs` keeps this in `BleatKit`,
/// where it compiles for iOS and can be tested against a captured fixture. The
/// caller runs the command; see `HostInspector`.
public enum InterfaceAddresses {

    /// Interfaces that never carry a usable SSH endpoint.
    ///
    /// `awdl0` and `llw0` are Apple Wireless Direct Link — AirDrop and
    /// Continuity, not general routing — and `lo0` reaches nothing but the
    /// machine itself.
    static let ignoredInterfaces: Set<String> = ["lo0", "awdl0", "llw0"]

    /// Every address worth offering as an endpoint, in the order `ifconfig`
    /// listed them.
    ///
    /// Four kinds are dropped, and the third is the one that would otherwise
    /// produce a mysterious bug:
    ///
    /// - Loopback and AWDL interfaces, which reach nothing useful.
    /// - Link-local addresses (`fe80::…`, `169.254.…`). They need a scope id to
    ///   be usable at all, and the host's `.local` name covers the same link
    ///   better.
    /// - **`temporary` addresses.** These are RFC 4941 privacy addresses and
    ///   they rotate by design, so pinning one as an endpoint gives a peer that
    ///   works today and fails tomorrow with no visible cause. Only the stable
    ///   `secured` address is kept.
    /// - `deprecated` addresses, which the stack is already retiring.
    public static func endpoints(ifconfigOutput: String, port: Int = 22) -> [Endpoint] {
        var result: [Endpoint] = []
        var interface = ""

        for rawLine in ifconfigOutput.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if let name = interfaceName(of: line) {
                interface = name
                continue
            }
            guard !ignoredInterfaces.contains(interface) else { continue }

            // ifconfig indents address lines with a tab, so splitting on
            // spaces alone leaves "\tinet" as the first field.
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 2, fields[0] == "inet" || fields[0] == "inet6" else { continue }
            guard !fields.contains("temporary"), !fields.contains("deprecated") else { continue }

            // `fe80::1463:…%en0` — the scope id is part of the printed address.
            let address = String(fields[1].split(separator: "%", maxSplits: 1)[0])
            guard !address.isEmpty else { continue }
            guard !isLinkLocal(address) else { continue }

            let endpoint = Endpoint(host: address, port: port)
            if !result.contains(endpoint) { result.append(endpoint) }
        }
        return result
    }

    /// `en0: flags=8863<…> mtu 1500` — a line starting at column zero with a
    /// name and a colon.
    static func interfaceName(of line: String) -> String? {
        guard let first = line.first, first != " ", first != "\t" else { return nil }
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let name = String(line[line.startIndex..<colon])
        guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." }) else { return nil }
        return name
    }

    static func isLinkLocal(_ address: String) -> Bool {
        if address.lowercased().hasPrefix("fe80:") { return true }
        if address.hasPrefix("169.254.") { return true }
        if address == "127.0.0.1" || address == "::1" { return true }
        return false
    }
}
