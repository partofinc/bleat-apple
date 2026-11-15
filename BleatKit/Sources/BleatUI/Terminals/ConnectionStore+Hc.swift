import BleatKit

extension ConnectionStore {
    /// An `hc connect` stream to this peer's core, on the shared connection,
    /// and that connection. The one opener the terminal list and a terminal's
    /// screen both use (from review), so a change to how a stream is reached
    /// is made once.
    func openHc(for peer: PairedPeer) async throws -> (stream: any DuplexStream, link: any PeerLink) {
        guard let hcPath = peer.herdrCore?.path else { throw HcPaneFailure.notChecked }
        let link = try await link(for: peer)
        guard let opener = link as? any HcStreamOpening else { throw HcPaneFailure.noRoute }
        return (try await opener.openHcConnection(hcPath: hcPath), link)
    }
}
