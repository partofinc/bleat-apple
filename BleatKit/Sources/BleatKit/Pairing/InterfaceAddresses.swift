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

    /// Interface families that carry host-only addresses.
    ///
    /// A Mac running Parallels, VMware Fusion, UTM or `vmnet` has `bridge100`,
    /// `vmnet1` or `vnic0` holding addresses like `192.168.64.1` that pass
    /// every other filter. Offering one costs the phone a connect timeout, and
    /// worse — if its own LAN overlaps that range it reaches an unrelated
    /// device and fails host key verification instead of merely failing to
    /// connect, which reads as a security warning rather than a bad address.
    static let ignoredPrefixes = ["bridge", "vmnet", "vnic", "vboxnet"]

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
        var usable = false

        for rawLine in ifconfigOutput.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if let name = interfaceName(of: line) {
                usable = isUsableInterface(name: name, headerLine: line)
                continue
            }
            guard usable else { continue }

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

    /// Whether an interface can carry an endpoint at all.
    ///
    /// A down or non-running interface still prints its last address, so
    /// without the flag check a disconnected Wi-Fi or a dormant VPN
    /// contributes a stale address that the phone will patiently time out on.
    static func isUsableInterface(name: String, headerLine: String) -> Bool {
        guard !ignoredInterfaces.contains(name) else { return false }
        guard !ignoredPrefixes.contains(where: { name.hasPrefix($0) }) else { return false }
        guard let open = headerLine.firstIndex(of: "<"),
              let close = headerLine[open...].firstIndex(of: ">")
        else { return false }
        let flags = headerLine[headerLine.index(after: open)..<close].split(separator: ",")
        return flags.contains("UP") && flags.contains("RUNNING")
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

    /// `fe80::/10` is `fe80`–`febf`, not just `fe80`. macOS only ever prints
    /// `fe80`, but matching the actual range costs nothing and stops the check
    /// being wrong on a platform that does not.
    static func isLinkLocal(_ address: String) -> Bool {
        let lower = address.lowercased()
        if lower.hasPrefix("169.254.") { return true }
        if lower == "127.0.0.1" || lower == "::1" { return true }
        guard let colon = lower.firstIndex(of: ":") else { return false }
        let group = lower[lower.startIndex..<colon]
        guard group.count == 4, let value = UInt16(group, radix: 16) else { return false }
        return (0xfe80...0xfebf).contains(value)
    }
}
