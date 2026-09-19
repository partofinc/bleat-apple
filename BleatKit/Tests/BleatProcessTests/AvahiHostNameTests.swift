#if os(macOS)
import Testing
@testable import BleatProcess

/// `bleat pair` asks avahi for the name it publishes rather than assuming the
/// hostname, because avahi renames on a collision. This is the reading of its
/// answer; the reply shape is busctl's, captured on a Raspberry Pi.
@Suite("Avahi host name")
struct AvahiHostNameTests {

    @Test("busctl's string reply gives the published name")
    func reads() {
        #expect(HostInspector.avahiHostName(busctlOutput: "s \"adam\"\n") == "adam")
        // What a second `raspberrypi` on the network is renamed to.
        #expect(HostInspector.avahiHostName(busctlOutput: "s \"raspberrypi-2\"") == "raspberrypi-2")
    }

    /// This string becomes an endpoint the phone dials, so anything that is
    /// not plainly a name is refused rather than trimmed into one.
    @Test("anything but a plain name is refused", arguments: [
        "", "s \"\"", "adam", "s \"adam", "b true",
        "s \"adam.local\"", "s \"a b\"", "s \"adam;reboot\"",
        "Failed to connect to bus: No such file or directory",
    ])
    func refuses(output: String) {
        #expect(HostInspector.avahiHostName(busctlOutput: output) == nil)
    }
}
#endif
