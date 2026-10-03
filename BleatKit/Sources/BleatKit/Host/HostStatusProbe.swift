import Foundation

/// Asking a host what it is and how busy it is.
///
/// Plain shell rather than herdr, because herdr reports none of it but its own
/// version: so this goes through `ConnectionStore.shell`, and leaves the
/// session prefix alone exactly as the pairing commands do.
///
/// **One command, one exec channel.** Everything below is a dozen small reads,
/// and a channel each would be a dozen round trips over a cellular link for a
/// section nobody is waiting on.
///
/// **The host's tools print; this file reads.** The script does no arithmetic
/// and no parsing — it tags each tool's raw output with where it came from and
/// sends it back. That keeps the shell small enough to run under every shell it
/// will meet, and puts the part that can be wrong where a test can reach it,
/// fed from `Fixtures/host-status-*.txt`.
///
/// Measured 1 Oct 2026 against macOS 27.0.1 (M1) and Debian 13 on a Raspberry
/// Pi CM5:
///
/// - **A Mac gives no temperature to an unprivileged user.** `powermetrics`
///   needs root, `pmset -g therm` reports only whether a thermal *warning* has
///   been recorded, and there is no `sysctl` for it on Apple silicon.
/// - **CPU usage needs two readings a moment apart**, on both. Linux's
///   `/proc/stat` counts since boot, and so does the first line of `iostat` —
///   on a Mac that had been at 100% for minutes it read 73% idle. So the
///   probe takes one second, and that second is the sample.
/// - **Memory "used" is not total minus free on a Mac**: free was 60 MB of
///   16 GB, because macOS keeps file cache in what would be free. Used here is what Activity Monitor calls it
///   — anonymous pages that cannot be purged, wired, and what the compressor
///   occupies. On Linux it is `MemTotal - MemAvailable`, for the same reason.
/// - **Disk is the volume under `$HOME`**, and used is total minus available.
///   On APFS `/` is the sealed system volume — 14% used on a disk that was 82%
///   full — and a volume's own "Used" leaves out its siblings in the container.
public enum HostStatusProbe {
    /// Tags every line worth reading. A login shell's banner carries none.
    static let prefix = "bleat-host:"

    /// The script, for `/bin/sh`.
    ///
    /// **No single quote and no backslash-quote anywhere in it**, because it
    /// travels inside single quotes — see `command(herdrPath:)`.
    ///
    /// - `PATH` is set rather than inherited. Resolving `df` through the
    ///   user's `PATH` is a way to run something else entirely, and these four
    ///   directories hold every tool named here on both kinds of host.
    /// - `exec 2>/dev/null`: half of these are expected to be missing on any
    ///   one host, and each would say so.
    /// - The trailing `true` is what makes absence an answer: `ShellRunner`
    ///   throws on a non-zero exit, and the last read failing is ordinary.
    /// - `/proc/device-tree/model` ends in a NUL and no newline, so it is
    ///   stripped and given one, or the next line is glued to it.
    /// - `$2`, when set, leaves out the processor sample: the one read that
    ///   takes a second, and the one pairing has no use for.
    static let script = """
        exec 2>/dev/null
        PATH=/usr/bin:/bin:/usr/sbin:/sbin
        h=$1
        i=$2
        p() { sed "s/^/\(prefix)$1:/"; }
        uname -srm | p uname
        [ -n "$h" ] && "$h" --version | p herdr
        getconf _NPROCESSORS_ONLN | p cores
        df -Pk "$HOME" | p df
        case $(uname -s) in
        Darwin)
          sw_vers | p sw_vers
          sysctl -n hw.model | p model
          ioreg -rc IOPlatformDevice -k product-name | grep product-name | p product
          sysctl -n hw.memsize | p memsize
          sysctl -n kern.boottime | p boottime
          date +%s | p now
          vm_stat | p vm_stat
          [ -z "$i" ] && iostat -n0 -c 2 -w 1 | p iostat
          ;;
        Linux)
          cat /etc/os-release | p os-release
          { tr -d "\\000" < /proc/device-tree/model; echo; } | p model
          cat /sys/devices/virtual/dmi/id/product_name | p model
          grep -E "^Mem(Total|Available):" /proc/meminfo | p meminfo
          cat /proc/uptime | p uptime
          cat /proc/loadavg | p loadavg
          for z in /sys/class/thermal/thermal_zone*; do
            echo "$(cat "$z/type") $(cat "$z/temp")"
          done | p thermal
          if [ -z "$i" ]; then
            head -n 1 /proc/stat | p stat
            sleep 1
            head -n 1 /proc/stat | p stat
          fi
          ;;
        esac
        true
        """

    /// - Parameter herdrPath: where herdr is on the host, as the peer records
    ///   it. nil leaves the version out; it is not searched for, because
    ///   `PATH` here is deliberately not the user's.
    ///
    /// **Handed to `/bin/sh` rather than run by the login shell.** An exec
    /// channel goes through whatever shell the account logs into, and the
    /// script is POSIX: `case`, a function, `$(…)`. Wrapped like this, the
    /// login shell only has to understand a single-quoted string — which zsh,
    /// bash and fish all do. Run under zsh, bash, dash and macOS's `sh`.
    ///
    /// - Parameter sampling: false leaves out the processor's usage, which
    ///   costs a second of waiting on the host. Pairing asks only what the
    ///   host is, and the user is watching a spinner while it does.
    public static func command(herdrPath: String?, sampling: Bool = true) -> String {
        "/bin/sh -c '\(script)' sh \(quote(herdrPath ?? ""))" + (sampling ? "" : " info")
    }

    /// Reads a reply. Lines without the prefix are ignored, and so is anything
    /// that does not parse: each field stands or falls alone.
    public static func status(fromOutput output: String) -> HostStatus {
        var tagged: [Substring: [Substring]] = [:]
        for line in output.split(whereSeparator: \.isNewline) where line.hasPrefix(prefix) {
            let rest = line.dropFirst(prefix.count)
            guard let colon = rest.firstIndex(of: ":") else { continue }
            tagged[rest[..<colon], default: []].append(rest[rest.index(after: colon)...])
        }
        func lines(_ tag: Substring) -> [Substring] { tagged[tag] ?? [] }

        var status = HostStatus()

        // `uname -srm`: three words, none of which can hold a space.
        let uname = fields(lines("uname").first)
        if uname.count == 3 {
            status.info.kernel = "\(uname[0]) \(uname[1])"
            status.info.architecture = String(uname[2])
        }

        // `herdr 0.9.3`.
        let herdr = fields(lines("herdr").first)
        if herdr.count == 2, herdr[0] == "herdr" { status.info.herdrVersion = String(herdr[1]) }

        status.load.cores = number(lines("cores").first)
        status.info.model = lines("model").lazy.map(trimmed).first { !$0.isEmpty }
        status.info.modelName = productName(lines("product"))
        status.info.system = macSystem(lines("sw_vers")) ?? linuxSystem(lines("os-release"))
        status.load.disk = disk(lines("df"))
        status.load.memory = macMemory(vmStat: lines("vm_stat"), memsize: lines("memsize").first)
            ?? linuxMemory(lines("meminfo"))
        status.load.uptime = macUptime(boottime: lines("boottime").first, now: lines("now").first)
            ?? linuxUptime(lines("uptime").first)
        status.load.temperature = temperature(lines("thermal"))

        if let sample = macSample(lines("iostat")) {
            status.load.cpuUsage = sample.usage
            status.load.loadAverage = sample.load
        } else {
            status.load.cpuUsage = linuxUsage(lines("stat"))
            status.load.loadAverage = fields(lines("loadavg").first).first.flatMap { Double($0) }
        }
        return status
    }

    // MARK: - Both

    /// The data row of `df -Pk`, found from the capacity column backwards: a
    /// filesystem's name may hold spaces (`map auto_home`, a network share)
    /// and the three numbers before `82%` cannot.
    private static func disk(_ lines: [Substring]) -> HostLoad.Usage? {
        guard let row = lines.last.map({ fields($0) }),
              let capacity = row.firstIndex(where: { $0.hasSuffix("%") }), capacity >= 3,
              let total = Int64(row[capacity - 3]), total > 0,
              let available = Int64(row[capacity - 1]), available <= total
        else { return nil }
        return HostLoad.Usage(used: (total - available) * 1024, total: total * 1024)
    }

    // MARK: - macOS

    /// `"product-name" = <"MacBook Air (M1, 2020)">`, from `ioreg`: the
    /// property is a byte string, which `ioreg` prints quoted inside angle
    /// brackets. Absent on an Intel Mac, which has no such property.
    private static func productName(_ lines: [Substring]) -> String? {
        for line in lines where line.contains("\"product-name\"") {
            guard let open = line.range(of: "<\""),
                  let close = line.range(of: "\">", range: open.upperBound..<line.endIndex)
            else { continue }
            let name = trimmed(line[open.upperBound..<close.lowerBound])
            if !name.isEmpty { return name }
        }
        return nil
    }

    /// `ProductName:\t\tmacOS` and `ProductVersion:\t\t27.0.1`.
    private static func macSystem(_ lines: [Substring]) -> String? {
        let values = keyed(lines, separator: ":")
        guard let name = values["ProductName"], let version = values["ProductVersion"] else {
            return nil
        }
        return "\(name) \(version)"
    }

    private static func macMemory(vmStat: [Substring], memsize: Substring?) -> HostLoad.Usage? {
        // `Mach Virtual Memory Statistics: (page size of 16384 bytes)`
        guard let total: Int64 = number(memsize), total > 0,
              let header = vmStat.first,
              let pageSize = fields(header).lazy.compactMap({ Int64($0) }).first
        else { return nil }
        // `Pages wired down:      181788.` — a count with a full stop after it.
        let pages = keyed(vmStat, separator: ":").compactMapValues {
            Int64($0.trimmingCharacters(in: CharacterSet(charactersIn: ".")))
        }
        guard let anonymous = pages["Anonymous pages"],
              let wired = pages["Pages wired down"],
              let compressor = pages["Pages occupied by compressor"]
        else { return nil }
        let used = (anonymous - (pages["Pages purgeable"] ?? 0) + wired + compressor) * pageSize
        return HostLoad.Usage(used: min(max(used, 0), total), total: total)
    }

    /// `{ sec = 1790664100, usec = 851287 } Tue Sep 29 10:41:40 2026`, against
    /// the host's own clock — the phone's may disagree with it.
    private static func macUptime(boottime: Substring?, now: Substring?) -> Duration? {
        let words = fields(boottime)
        guard let sec = words.firstIndex(of: "sec"), words.count > sec + 2,
              let booted = Int64(words[sec + 2].trimmingCharacters(in: .punctuationCharacters)),
              let now: Int64 = number(now), now >= booted
        else { return nil }
        return .seconds(now - booted)
    }

    /// The last line of `iostat -n0 -c 2`: `us sy id  1m 5m 15m`. The first
    /// data line is the average since boot, which is why there are two.
    private static func macSample(_ lines: [Substring]) -> (usage: Double, load: Double?)? {
        guard lines.count >= 4 else { return nil }
        let row = fields(lines.last)
        guard row.count >= 3, let idle = Double(row[2]), (0...100).contains(idle) else {
            return nil
        }
        return (1 - idle / 100, row.count > 3 ? Double(row[3]) : nil)
    }

    // MARK: - Linux

    /// `PRETTY_NAME="Debian GNU/Linux 13 (trixie)"`.
    private static func linuxSystem(_ lines: [Substring]) -> String? {
        let values = keyed(lines, separator: "=")
        let quotes = CharacterSet(charactersIn: "\"'")
        if let pretty = values["PRETTY_NAME"]?.trimmingCharacters(in: quotes), !pretty.isEmpty {
            return pretty
        }
        guard let name = values["NAME"]?.trimmingCharacters(in: quotes), !name.isEmpty else {
            return nil
        }
        return name
    }

    /// `MemTotal:        8255824 kB`.
    private static func linuxMemory(_ lines: [Substring]) -> HostLoad.Usage? {
        let kilobytes = keyed(lines, separator: ":").compactMapValues {
            fields(Substring($0)).first.flatMap { Int64($0) }
        }
        guard let total = kilobytes["MemTotal"], total > 0,
              let available = kilobytes["MemAvailable"], available <= total
        else { return nil }
        return HostLoad.Usage(used: (total - available) * 1024, total: total * 1024)
    }

    /// `439391.32 1750887.37`: seconds up, then seconds idle summed over cores.
    private static func linuxUptime(_ line: Substring?) -> Duration? {
        guard let seconds = fields(line).first.flatMap({ Double($0) }), seconds >= 0 else {
            return nil
        }
        return .seconds(Int64(seconds))
    }

    /// Two readings of `cpu  user nice system idle iowait irq softirq steal …`,
    /// in ticks since boot. What was busy between them is what was not idle
    /// and not waiting on a disk.
    private static func linuxUsage(_ lines: [Substring]) -> Double? {
        func reading(_ line: Substring) -> (idle: Double, total: Double)? {
            let ticks = fields(line).dropFirst().prefix(8).compactMap { Double($0) }
            guard ticks.count >= 5 else { return nil }
            return (ticks[3] + ticks[4], ticks.reduce(0, +))
        }
        guard lines.count == 2, let first = reading(lines[0]), let second = reading(lines[1]),
              second.total > first.total
        else { return nil }
        let idle = (second.idle - first.idle) / (second.total - first.total)
        return min(max(1 - idle, 0), 1)
    }

    /// `cpu-thermal 48500`: a zone's type and millidegrees. The processor's
    /// zone if one says it is that; otherwise the hottest, which on a board
    /// with one sensor is the same thing.
    private static func temperature(_ lines: [Substring]) -> Double? {
        let zones: [(type: Substring, degrees: Double)] = lines.compactMap {
            let words = fields($0)
            guard words.count == 2, let milli = Double(words[1]), milli > 0 else { return nil }
            return (words[0], milli / 1000)
        }
        let processor = zones.first { $0.type.contains("cpu") || $0.type.contains("pkg") }
        return processor?.degrees ?? zones.map(\.degrees).max()
    }

    // MARK: - Reading

    private static func fields(_ line: Substring?) -> [Substring] {
        line?.split(whereSeparator: \.isWhitespace) ?? []
    }

    private static func trimmed(_ line: Substring) -> String {
        line.trimmingCharacters(in: .whitespaces)
    }

    private static func number<N: LosslessStringConvertible>(_ line: Substring?) -> N? {
        line.flatMap { N(trimmed($0)) }
    }

    /// `key<separator>value` lines as a dictionary, both sides trimmed. The
    /// first of a repeated key wins.
    private static func keyed(_ lines: [Substring], separator: Character) -> [String: String] {
        var values: [String: String] = [:]
        for line in lines {
            guard let split = line.firstIndex(of: separator) else { continue }
            let key = trimmed(line[..<split])
            if values[key] == nil { values[key] = trimmed(line[line.index(after: split)...]) }
        }
        return values
    }

    /// Single quotes for POSIX shells, the same rule as `SSHTransport.quote`.
    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
