import Foundation
import Testing
@testable import BleatKit

@Suite("Host argument resolution")
struct HostArgumentsTests {

    private let hosts = [
        HostEntry(name: "dev", spec: "ravil@10.0.0.5", keyPath: "~/k"),
        HostEntry(name: "box", spec: "ravil@box:2222", keyPath: "~/k"),
    ]

    private func resolve(
        _ positional: [String],
        expectsTarget: Bool = false
    ) throws -> (host: HostSelection, rest: [String]) {
        try HostArguments.resolve(positional: positional, expectsTarget: expectsTarget, hosts: hosts)
    }

    @Test("no argument means the local herdr")
    func localByDefault() throws {
        #expect(try resolve([]).host == .local)
    }

    @Test("a saved name selects that host")
    func savedHost() throws {
        let resolved = try resolve(["dev"])
        #expect(resolved.host == .saved(hosts[0]))
        #expect(resolved.rest.isEmpty)
    }

    @Test("an unknown host is an error, never a silent fallback to local")
    func unknownHostIsFatal() {
        // The bug this guards: `bleat agents devv` used to list *local* agents
        // as though the remote had answered.
        #expect(throws: HostArgumentError.unknownHost("devv", known: ["box", "dev"])) {
            try resolve(["devv"])
        }
    }

    @Test("attach with one argument treats it as the target")
    func attachLocalTarget() throws {
        let resolved = try resolve(["w1:p1"], expectsTarget: true)
        #expect(resolved.host == .local)
        #expect(resolved.rest == ["w1:p1"])
    }

    @Test("attach with host and target")
    func attachRemote() throws {
        let resolved = try resolve(["dev", "w1:p1"], expectsTarget: true)
        #expect(resolved.host == .saved(hosts[0]))
        #expect(resolved.rest == ["w1:p1"])
    }

    @Test("attach with an unknown host does not silently retarget locally")
    func attachUnknownHost() {
        // Previously `bleat attach devv w1:p1` attached to a local pane named
        // "devv" and dropped the real target on the floor.
        #expect(throws: HostArgumentError.unknownHost("devv", known: ["box", "dev"])) {
            try resolve(["devv", "w1:p1"], expectsTarget: true)
        }
    }

    @Test("attach with a host but no target says the target is missing")
    func attachHostOnly() {
        #expect(throws: HostArgumentError.missingTarget) {
            try resolve(["dev"], expectsTarget: true)
        }
    }

    @Test("attach with nothing at all")
    func attachNothing() {
        #expect(throws: HostArgumentError.missingTarget) {
            try resolve([], expectsTarget: true)
        }
    }

    @Test("surplus arguments are reported, not ignored")
    func surplus() {
        #expect(throws: HostArgumentError.unexpectedArguments(["extra"])) {
            try resolve(["dev", "extra"])
        }
        #expect(throws: HostArgumentError.unexpectedArguments(["extra"])) {
            try resolve(["dev", "w1:p1", "extra"], expectsTarget: true)
        }
    }
}
