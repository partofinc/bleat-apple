#if DEBUG
import BleatKit
import Foundation

/// What a host says about itself, for previews.
///
/// Hand-written rather than read from `Fixtures/` — those are not bundled with
/// the app and a preview cannot reach them — but shaped like the captured
/// `host-status-*.txt` output. herdr-core's terminals are in
/// `PreviewTerminals.swift`.

extension HostInfo {
    /// As captured from the dev Mac — `Fixtures/host-status-macos.txt`.
    static var sampleMac: HostInfo {
        HostInfo(
            system: "macOS 27.0.1", kernel: "Darwin 27.0.0", architecture: "arm64",
            model: "MacBookAir10,1", modelName: "MacBook Air (M1, 2020)"
        )
    }

    /// As captured from the Pi — `Fixtures/host-status-linux.txt`.
    static var sampleLinux: HostInfo {
        HostInfo(
            system: "Debian GNU/Linux 13 (trixie)", kernel: "Linux 6.18.50+rpt-rpi-2712",
            architecture: "aarch64", model: "Raspberry Pi Compute Module 5 Rev 1.0"
        )
    }
}

extension HostLoad {
    /// A Mac with its memory mostly spoken for. No temperature: a Mac does not
    /// say.
    static var sampleMac: HostLoad {
        HostLoad(
            cores: 8, cpuUsage: 0.34, loadAverage: 2.61,
            memory: Usage(used: 14_080_163_840, total: 17_179_869_184),
            disk: Usage(used: 410_624_946_176, total: 494_353_338_368),
            uptime: .seconds(192_518)
        )
    }

    /// An idle Pi, which does say how warm it is.
    static var sampleLinux: HostLoad {
        HostLoad(
            cores: 4, cpuUsage: 0.02, loadAverage: 0.08,
            memory: Usage(used: 794_132_480, total: 8_453_963_776),
            disk: Usage(used: 7_897_923_584, total: 30_172_868_608),
            temperature: 48.5, uptime: .seconds(439_391)
        )
    }
}

extension Invitation {
    /// A code for the everyday peer, with five minutes on it and no key on
    /// any host behind it.
    static var preview: Invitation {
        let peer = PairedPeer.preview
        return Invitation(
            payload: PairingPayload(
                name: peer.name, username: peer.username, endpoints: peer.endpoints,
                enrollmentSeed: SSHKeyPair().rawRepresentation, hostKey: peer.hostKey
            ),
            marker: AuthorizedKeys.enrollmentMarker(),
            deadline: .now.addingTimeInterval(Invitation.window)
        )
    }
}
#endif
