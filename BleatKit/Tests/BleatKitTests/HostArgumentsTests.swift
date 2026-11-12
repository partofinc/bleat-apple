import Foundation
import Testing
@testable import BleatKit

@Suite("Host argument resolution")
struct HostArgumentsTests {

    private let hosts = [
        HostEntry(name: "dev", spec: "robin@10.0.0.5", keyPath: "~/k"),
        HostEntry(name: "box", spec: "robin@box:2222", keyPath: "~/k"),
    ]

    private func resolve(_ positional: [String]) throws -> (host: HostSelection, rest: [String]) {
        try HostArguments.resolve(positional: positional, hosts: hosts)
    }

    @Test("no argument means this machine")
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

    @Test("surplus arguments are reported, not ignored")
    func surplus() {
        #expect(throws: HostArgumentError.unexpectedArguments(["extra"])) {
            try resolve(["dev", "extra"])
        }
    }
}
