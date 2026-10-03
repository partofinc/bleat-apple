import Foundation
import Testing
@testable import BleatKit

/// Both fixtures are the probe's own output, captured 1 Oct 2026 by running
/// `HostStatusProbe.command` on the host: a MacBook Air (macOS 27.0.1) and a
/// Raspberry Pi CM5 (Debian 13).
@Suite("Reading what a host says about itself")
struct HostStatusProbeTests {

    @Test("a Mac's reply")
    func mac() throws {
        let status = HostStatusProbe.status(fromOutput: try Fixture.text("host-status-macos.txt"))
        #expect(status.info.system == "macOS 27.0.1")
        #expect(status.info.kernel == "Darwin 27.0.0")
        #expect(status.info.architecture == "arm64")
        #expect(status.info.model == "MacBookAir10,1")
        #expect(status.info.modelName == "MacBook Air (M1, 2020)")
        #expect(status.info.herdrVersion == "0.9.3")
        #expect(status.load.cores == 8)
        // Anonymous less purgeable, wired, and the compressor, in 16 KiB pages
        // — not total less free, which would read 16 GB used.
        #expect(status.load.memory == .init(used: 859_385 * 16_384, total: 17_179_869_184))
        // Total less available: the volume's own "Used" leaves out the other
        // volumes in its container.
        #expect(status.load.disk == .init(used: 401_000_924 * 1024, total: 482_766_932 * 1024))
        #expect(status.load.uptime == .seconds(192_518))
        // The second line of `iostat`, not the first, which is since boot and
        // says 27%.
        #expect(status.load.cpuUsage == 1)
        #expect(status.load.loadAverage == 53.98)
        // A Mac does not say.
        #expect(status.load.temperature == nil)
    }

    @Test("a Linux host's reply")
    func linux() throws {
        let status = HostStatusProbe.status(fromOutput: try Fixture.text("host-status-linux.txt"))
        #expect(status.info.system == "Debian GNU/Linux 13 (trixie)")
        #expect(status.info.kernel == "Linux 6.18.50+rpt-rpi-2712")
        #expect(status.info.architecture == "aarch64")
        #expect(status.info.model == "Raspberry Pi Compute Module 5 Rev 1.0")
        #expect(status.info.modelName == nil)
        #expect(status.info.herdrVersion == "0.9.3")
        #expect(status.load.cores == 4)
        #expect(status.load.memory == .init(used: 775_520 * 1024, total: 8_255_824 * 1024))
        #expect(status.load.disk == .init(used: 7_712_816 * 1024, total: 29_465_692 * 1024))
        #expect(status.load.uptime == .seconds(439_391))
        // Every tick between the two readings was idle.
        #expect(status.load.cpuUsage == 0)
        #expect(status.load.loadAverage == 0.08)
        #expect(status.load.temperature == 48.5)
    }

    @Test("usage is what was busy between two readings")
    func usageBetweenReadings() {
        // 400 ticks apart: 100 idle, 20 waiting on a disk, 280 busy.
        let status = HostStatusProbe.status(fromOutput: """
            bleat-host:stat:cpu  1000 0 500 8000 100 0 0 0 0 0
            bleat-host:stat:cpu  1200 0 580 8100 120 0 0 0 0 0
            """)
        #expect(status.load.cpuUsage == 0.7)
    }

    /// A single reading is ticks since boot, which is an average over days.
    @Test("one reading is not a usage")
    func oneReading() {
        let status = HostStatusProbe.status(
            fromOutput: "bleat-host:stat:cpu  1000 0 500 8000 100 0 0 0 0 0"
        )
        #expect(status.load.cpuUsage == nil)
    }

    @Test("the processor's zone is preferred, and the hottest stands in for it")
    func thermalZones() {
        let named = HostStatusProbe.status(fromOutput: """
            bleat-host:thermal:acpitz 27800
            bleat-host:thermal:x86_pkg_temp 61000
            bleat-host:thermal:iwlwifi_1 72000
            """)
        #expect(named.load.temperature == 61)
        let unnamed = HostStatusProbe.status(fromOutput: """
            bleat-host:thermal:acpitz 27800
            bleat-host:thermal:soc 44000
            """)
        #expect(unnamed.load.temperature == 44)
    }

    /// sshd runs an exec command through the login shell, and profiles print.
    @Test("a banner around the reply is ignored")
    func banner() throws {
        let reply = try Fixture.text("host-status-linux.txt")
        let status = HostStatusProbe.status(fromOutput: "Welcome to adam\n\(reply)\nbye: 1\n")
        #expect(status == HostStatusProbe.status(fromOutput: reply))
    }

    @Test("a reply that is all banner is empty, and each field fails alone")
    func partial() {
        #expect(HostStatusProbe.status(fromOutput: "Last login: today\n").isEmpty)
        let status = HostStatusProbe.status(fromOutput: """
            bleat-host:uname:Linux 6.1.0 x86_64
            bleat-host:cores:many
            bleat-host:df:nonsense
            bleat-host:meminfo:MemTotal: 100 kB
            """)
        #expect(status.info.kernel == "Linux 6.1.0")
        #expect(status.load.cores == nil)
        #expect(status.load.disk == nil)
        #expect(status.load.memory == nil)
    }

    @Test("the kernel and the model say what kind of machine it is")
    func platform() throws {
        let mac = HostStatusProbe.status(fromOutput: try Fixture.text("host-status-macos.txt"))
        let pi = HostStatusProbe.status(fromOutput: try Fixture.text("host-status-linux.txt"))
        #expect(mac.info.platform == .mac)
        #expect(pi.info.platform == .raspberryPi)
        #expect(HostInfo(kernel: "Linux 6.1.0", model: "NUC11PAHi5").platform == .linux)
        #expect(HostInfo().platform == .unknown)
    }

    @Test("a row names the machine in a few words")
    func shortModel() throws {
        let mac = HostStatusProbe.status(fromOutput: try Fixture.text("host-status-macos.txt"))
        let pi = HostStatusProbe.status(fromOutput: try Fixture.text("host-status-linux.txt"))
        #expect(mac.info.shortModel == "MacBook Air (M1, 2020)")
        #expect(pi.info.shortModel == "Raspberry Pi CM5")
        #expect(HostInfo(model: "Raspberry Pi 4 Model B Rev 1.4").shortModel == "Raspberry Pi 4 Model B")
        // An Intel Mac has no marketing name to read, so its identifier stands.
        #expect(HostInfo(model: "MacBookPro16,1").shortModel == "MacBookPro16,1")
        #expect(HostInfo().shortModel == nil)
    }

    /// Each part of the probe fails alone, so a reply can be missing what the
    /// last one had.
    @Test("a newer report lays over an older one without erasing it")
    func updating() {
        let known = HostInfo(
            system: "macOS 27.0.1", kernel: "Darwin 27.0.0", model: "Mac14,2", modelName: "Mac mini (2023)"
        )
        let newer = HostInfo(system: "macOS 27.1", herdrVersion: "0.9.4")
        #expect(known.updated(with: newer) == HostInfo(
            system: "macOS 27.1", kernel: "Darwin 27.0.0", model: "Mac14,2",
            modelName: "Mac mini (2023)", herdrVersion: "0.9.4"
        ))
        #expect(known.updated(with: HostInfo()) == known)
    }

    @Test("usage is a share of the total, and never outside it")
    func fraction() {
        #expect(HostLoad.Usage(used: 3, total: 4).fraction == 0.75)
        #expect(HostLoad.Usage(used: 9, total: 4).fraction == 1)
        #expect(HostLoad.Usage(used: 1, total: 0).fraction == 0)
    }

    /// The script travels inside single quotes, so one of its own would end
    /// the string early — and fish reads a backslash before a quote or a
    /// backslash as an escape even there.
    @Test("the script can be single-quoted for any login shell")
    func quotable() {
        #expect(!HostStatusProbe.script.contains("'"))
        #expect(!HostStatusProbe.script.contains("\\\\"))
        let command = HostStatusProbe.command(herdrPath: "/opt/homebrew/bin/herdr")
        #expect(command.hasPrefix("/bin/sh -c '"))
        #expect(command.hasSuffix("' sh '/opt/homebrew/bin/herdr'"))
        #expect(HostStatusProbe.command(herdrPath: nil).hasSuffix("' sh ''"))
        #expect(HostStatusProbe.command(herdrPath: nil, sampling: false).hasSuffix("' sh '' info"))
    }

    /// A re-pair asks the host what it is, and that is laid over the record
    /// rather than replacing it.
    @Test("a re-pair's report lays over what was known")
    func repairLaysOver() throws {
        var known = PairedPeer(
            hostKey: "ssh-ed25519 AAAA", name: "adam", username: "pi", endpoints: [Endpoint(host: "adam.local")]
        )
        known.hostInfo = HostInfo(system: "Debian GNU/Linux 13 (trixie)", model: "Raspberry Pi Compute Module 5 Rev 1.0")
        var fresh = PairedPeer(
            hostKey: "ssh-ed25519 AAAA", name: "adam", username: "pi", endpoints: [Endpoint(host: "adam.local")]
        )
        fresh.hostInfo = HostInfo(kernel: "Linux 6.18.50+rpt-rpi-2712")
        let merged = try known.merging(fresh).hostInfo
        #expect(merged?.system == "Debian GNU/Linux 13 (trixie)")
        #expect(merged?.kernel == "Linux 6.18.50+rpt-rpi-2712")

        // A re-pair whose probe said nothing keeps the record as it was.
        fresh.hostInfo = nil
        #expect(try known.merging(fresh).hostInfo == known.hostInfo)
    }
}
