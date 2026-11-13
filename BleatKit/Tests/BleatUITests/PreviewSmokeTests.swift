#if canImport(UIKit)
import BleatKit
import SwiftUI
import Testing
import UIKit
@testable import BleatUI

/// Every `#Preview`, laid out for real.
///
/// **A preview that compiles can still trap at render**, and the ways it does
/// are exactly the ways this app's previews could go wrong: a screen reading
/// `AppContext` out of an environment that has none, or a seeded model whose
/// `load` runs anyway and replaces the state somebody wanted to look at. Both
/// are invisible to `swift build` and neither shows up until the canvas is
/// opened, one preview at a time.
///
/// The seam itself — a parked `HcPaneModel` that does not attach — is
/// asserted directly, in `parkedModels`. The render tests are the second
/// half of that: they put each screen through a **real appearance lifecycle**,
/// so the `.task` modifiers that do the fetching actually run. Without a window
/// they do not run at all, which made an earlier version of this suite pass
/// whether the seam worked or not — verified with a probe view whose only
/// content was a `.task`: false before and after a sleep, hosted bare; true
/// immediately, hosted in a key window.
@Suite("Previews render", .serialized)
@MainActor
struct PreviewSmokeTests {

    /// The context the `.sampleData` trait injects, built the same way.
    private func sampleContext(peers: [PairedPeer] = PairedPeer.samples) -> AppContext {
        let store = PeerStore(registry: .sample(peers))
        store.reload()
        return AppContext(peers: store, checksHerdrCore: false)
    }

    /// Gives anything the tasks started a moment to land, then checks nothing
    /// connected.
    ///
    /// The wait is what gives this teeth. A dial is asynchronous, so asserting
    /// the instant a render returns would pass even for a screen that had just
    /// started one — and `PairedPeer.preview` carries this Mac's real LAN
    /// address, so on the network these tests run on, a broken seam really does
    /// reach a host that answers.
    private func settle(_ context: AppContext) async {
        try? await Task.sleep(for: .milliseconds(750))
        #expect(context.connections.endpoint == nil, "a preview screen opened a connection")
    }

    /// Hosts a view at iPhone size, in a key window, and forces a layout pass.
    ///
    /// **The window is what makes this a test.** A hosting controller whose
    /// view is merely given a frame evaluates the body but never appears, so
    /// its `.task` modifiers never run — and `.task` is where every screen here
    /// loads. In a key window they run, synchronously enough that they have
    /// already started by the time `layoutIfNeeded` returns.
    ///
    /// Which is also why the seam has to hold: `PairedPeer.preview` has this
    /// Mac's real LAN address on it, so a broken seam would not merely fail —
    /// it would open an SSH connection from the test suite. No test touches the
    /// network.
    ///
    /// The size defaults to a phone. `rootScreens` passes an iPad's, which is
    /// the only way to lay a `NavigationSplitView` out in more than one column
    /// — collapsed and expanded are different view trees.
    @discardableResult
    private func render(
        _ context: AppContext,
        _ view: some View,
        size: CGSize = CGSize(width: 393, height: 759)
    ) -> UIWindow {
        // **Every previous window goes first, and that is not tidiness.** A
        // `UIWindow` made key and visible stays in the application's window
        // list, and this suite builds dozens. Left up, a window created later
        // does not reliably get a render: `rootExpanded` — the one test here
        // that reads the view hierarchy rather than merely surviving it —
        // passed alone and failed in a full run, finding an empty detail
        // column that had simply never been built. Every other test here only
        // asserts that rendering did not trap, so the pollution was invisible
        // until something looked.
        for stale in Self.windows {
            stale.isHidden = true
            stale.rootViewController = nil
        }
        Self.windows.removeAll()

        let window = TestWindow.make(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = UIHostingController(rootView: view.environment(context))
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        Self.windows.append(window)
        return window
    }

    /// Held only so the next `render` can take them down. The suite is
    /// `.serialized`, so there is never more than one in flight.
    private static var windows: [UIWindow] = []

    /// Which layout `NavigationSplitView` actually chose.
    ///
    /// **The honest probe, after two dishonest ones.** Asserting on rendered
    /// *text* was the obvious idea and does not work: SwiftUI does not back a
    /// `Text` with a `UILabel`, so an accessibility walk over a correctly
    /// expanded iPad window returned `["Bleat"]` — the navigation bar's title
    /// and nothing else — while the columns were demonstrably there
    /// (`size=(1210, 834)`, `horizontalSizeClass=.regular`). A test built on
    /// that walk passed alone, failed in a full run, and measured nothing
    /// either way.
    ///
    /// `UISplitViewController.isCollapsed` is the thing the question is
    /// actually about, and UIKit answers it directly.
    private func splitViewController(in window: UIWindow) -> UISplitViewController? {
        func find(_ controller: UIViewController) -> UISplitViewController? {
            if let split = controller as? UISplitViewController { return split }
            for child in controller.children {
                if let found = find(child) { return found }
            }
            return nil
        }
        return window.rootViewController.flatMap(find)
    }


    @Test("the sample context has the hosts the previews are drawn against")
    func sampleData() {
        let context = sampleContext()
        #expect(context.peers.peers.count == 3)
        #expect(context.peers.failure == nil)
        #expect(context.peers.peers.contains { $0.name == "kestrel.air" })
    }

    /// **The location, not the contents.** `AddEndpointView` and the unpair
    /// flow both write, so a preview pointed at `applicationSupport()` edits
    /// the device's own peer list from the canvas — which an earlier version of
    /// that view's preview did. Asserting on the peers cannot catch it: they
    /// are seeded into whatever registry `sample()` is handed, so the same
    /// three hosts appear either way. Only the path tells the two apart.
    @Test("the sample registry is in the temporary directory, never the app's own")
    func sampleRegistryIsThrowaway() {
        let path = PeerRegistry.sample().fileURL.path
        #expect(path.hasPrefix(NSTemporaryDirectory()), "sample registry at \(path)")
        #expect(path != PeerRegistry.applicationSupport().fileURL.path)
        // Distinct per call, so one preview does not rebuild the file another
        // is editing.
        #expect(PeerRegistry.sample().fileURL != PeerRegistry.sample().fileURL)
    }

    @Test("the empty trait has nothing paired")
    func noHosts() {
        #expect(sampleContext(peers: []).peers.peers.isEmpty)
    }

    /// **The load-bearing assumption of every render test below.**
    ///
    /// They are only worth anything if the `.task` modifiers run, and hosting a
    /// controller without a window does not run them — measured: a probe view
    /// whose only content was `Text("hi").task { ran = true }` reported false
    /// immediately and still false after a second. If SwiftUI ever changes when
    /// tasks fire, this fails loudly rather than quietly turning the rest of
    /// the suite back into a compile check.
    @Test("rendering runs the screens' tasks")
    func renderRunsTasks() {
        final class Ran: @unchecked Sendable { var value = false }
        let ran = Ran()
        render(sampleContext(), Text("probe").task { ran.value = true })
        #expect(ran.value, "`.task` did not run — the render tests below prove nothing")
    }

    /// The split view collapsed — a phone, and what every destination can
    /// check.
    ///
    /// **No host is selected, deliberately.** Selecting one mounts the gate,
    /// and `PairedPeer.preview` has herdr-core — so the terminal list would
    /// open, and dial the sample host's addresses.
    @Test("the root renders collapsed")
    func rootCollapsed() async {
        let context = sampleContext()
        let phone = render(context, RootView().environment(\.horizontalSizeClass, .compact))
        // Either SwiftUI built no split controller at all, or it built one and
        // collapsed it. Both are the single-stack tree; what must not happen
        // is two columns on a phone.
        #expect(splitViewController(in: phone)?.isCollapsed != false)
        #expect(context.navigation.selectedPeer == nil, "the root picked a host on its own")
        await settle(context)
    }

    /// The split view expanded — an iPad, where the sidebar and the detail
    /// column are on screen together.
    ///
    /// **It takes both an environment override and an iPad destination**, and
    /// each half was measured rather than reasoned about:
    ///
    /// - A window's **frame does not set the size class**. The first version
    ///   only made the window 1210 points wide, which exercised the collapsed
    ///   tree twice while the comment claimed it covered both.
    /// - The **override is necessary**: without
    ///   `.environment(\.horizontalSizeClass, .regular)` this fails even on an
    ///   iPad simulator, because a `UIWindow` built here has no scene to
    ///   inherit a regular size class from.
    /// - The **override is not sufficient**: with it, this still fails on an
    ///   iPhone simulator. The idiom wins.
    ///
    /// So it is skipped rather than quietly weakened when the destination
    /// cannot produce it — a test that cannot test what it is named after
    /// should say so. See `Package.swift` for the destination.
    @Test(
        "the root renders expanded",
        // The async form: the device's idiom is main-actor state, and the
        // `if:` condition is evaluated from a sendable closure off it.
        .enabled("the expanded column layout needs an iPad destination") {
            await UIDevice.current.userInterfaceIdiom == .pad
        }
    )
    func rootExpanded() async {
        let context = sampleContext()
        let pad = render(
            context,
            RootView().environment(\.horizontalSizeClass, .regular),
            size: CGSize(width: 1210, height: 834)
        )
        let split = splitViewController(in: pad)
        #expect(split != nil, "no split view controller — this is not the two-column tree")
        #expect(split?.isCollapsed == false, "the split view collapsed at iPad size")
        #expect(context.navigation.selectedPeer == nil, "the root picked a host on its own")
        await settle(context)
    }

    /// The bar is drawn from a reading somebody else took: no screen here may
    /// open a connection to get one.
    @Test("the host's load bar renders from a reading, and never dials for one")
    func hostLoadBar() async {
        let context = sampleContext()
        // Nothing read, nothing connected: no bar, and asking for a reading
        // must not be what dials.
        #expect(context.hostLoad.load(for: .preview) == nil)
        await context.hostLoad.refresh(for: .preview, force: true)
        #expect(context.hostLoad.load(for: .preview) == nil)

        context.hostLoad.preview(.sampleLinux, for: .preview)
        #expect(context.hostLoad.load(for: .preview) == .sampleLinux)
        // One host's reading is not another's.
        #expect(context.hostLoad.load(for: .previewSparse) == nil)
        // Each half of the bar on its own, and neither.
        for load in [
            HostLoad.sampleMac, .sampleLinux, HostLoad(loadAverage: 0.4),
            HostLoad(disk: .init(used: 9, total: 10)), HostLoad(),
        ] {
            render(context, List { Text("Row") }.safeAreaBar(edge: .bottom) { HostLoadBar(load: load) })
        }
        render(context, PeerSettingsView(hostKey: PairedPeer.preview.hostKey))
        await settle(context)
    }

    /// Only what the host said is drawn, so each line has to be able to be
    /// absent. The values themselves are the system's formatters.
    @Test("the bar's processor line is whatever of it the host said")
    func hostLoadText() {
        #expect(HostLoadBar(load: HostLoad()).cpuText == nil)
        #expect(HostLoadBar(load: HostLoad()).temperatureText == nil)
        #expect(HostLoadBar(load: HostLoad(loadAverage: 0.4)).cpuText?.hasPrefix("load ") == true)
        #expect(HostLoadBar(load: .sampleMac).cpuText?.contains(" · load ") == true)
        #expect(HostLoadBar(load: .sampleMac).temperatureText == nil)
        #expect(HostLoadBar(load: .sampleLinux).temperatureText != nil)
        for symbol in ["cpu", "thermometer.medium", "memorychip", "internaldrive"] {
            #expect(UIImage(systemName: symbol) != nil, "\(symbol)")
        }
    }

    /// `Image(_:bundle:)` draws nothing at all for a name it cannot find, so a
    /// catalog that did not compile, or a template Xcode refused, would show
    /// as a gap beside every Pi and fail no build.
    @Test("the Pi's mark is in the package's catalog, as a symbol")
    func berrySymbol() throws {
        let berry = try #require(
            UIImage(named: HostInfo.Platform.berry, in: .module, with: nil),
            "the custom symbol is not in BleatUI's bundle"
        )
        #expect(berry.isSymbolImage, "it loaded as a bitmap, so it will not follow the font")
        // And it takes a size from a font, which is what being a symbol is for.
        let small = berry.applyingSymbolConfiguration(.init(pointSize: 12))
        let large = berry.applyingSymbolConfiguration(.init(pointSize: 48))
        #expect((small?.size.height ?? 0) < (large?.size.height ?? 0))
        if let path = ProcessInfo.processInfo.environment["BLEAT_SYMBOL_PNG"] {
            let row = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 80)).image { _ in
                UIColor.white.setFill()
                UIRectFill(CGRect(x: 0, y: 0, width: 300, height: 80))
                var x = 10.0
                for size in [17.0, 22, 34, 56] {
                    for image in [berry, UIImage(systemName: "apple.logo")!] {
                        let drawn = image.applyingSymbolConfiguration(.init(pointSize: size))!
                            .withTintColor(.black, renderingMode: .alwaysOriginal)
                        drawn.draw(at: CGPoint(x: x, y: 70 - drawn.size.height))
                        x += drawn.size.width + 4
                    }
                }
            }
            try row.pngData()?.write(to: URL(fileURLWithPath: path))
        }
    }

    @Test("the peer screens render")
    func peerScreens() async {
        let context = sampleContext()
        render(context, NavigationSplitView { PeersView() } detail: { Text("Detail") })
        render(
            sampleContext(peers: []),
            NavigationSplitView { PeersView() } detail: { Text("Detail") }
        )
        // The gate for a host without herdr-core, and for one not checked
        // yet. Not for a ready one: that opens the terminal list, which dials.
        render(context, NavigationStack { HerdrCoreGateView(peer: .previewOverlayOnly) })
        render(context, NavigationStack { HerdrCoreGateView(peer: .previewSparse) })
        render(context, AddEndpointView(peer: .preview))
        render(context, PeerSettingsView(hostKey: PairedPeer.preview.hostKey))
        render(context, PeerSettingsView(hostKey: PairedPeer.previewOverlayOnly.hostKey))
        render(context, PeerSettingsView(hostKey: PairedPeer.previewSparse.hostKey))
        render(context, PeerSettingsView(hostKey: "ssh-ed25519 not-a-paired-host"))
        await settle(context)
        #expect(context.connections.endpoint == nil)
    }

    @Test("the terminal list renders, with spaces and without")
    func terminalList() async {
        let context = sampleContext()
        let hostKey = PairedPeer.preview.hostKey
        render(context, NavigationStack {
            TerminalsList(hostKey: hostKey, terminals: HcTerminal.samples.sortedByAttention())
        })
        render(context, NavigationStack {
            TerminalsList(hostKey: hostKey, terminals: HcTerminal.samplesWithoutSpaces)
        })
        render(context, NavigationStack { TerminalsList(hostKey: hostKey, terminals: []) })
        await settle(context)
        #expect(context.connections.endpoint == nil)
    }

    @Test("the new-terminal sheet renders, and its preview host dials nothing")
    func newTerminalSheet() async {
        let context = sampleContext()
        render(context, NewTerminalSheet(
            model: NewTerminalModel(hostName: "adam", terminals: HcTerminal.samples, host: PreviewTerminalHost()),
            onStarted: { _, _ in }
        ))
        await settle(context)
        #expect(context.connections.endpoint == nil)
    }

    @Test("the terminal screens render in every phase")
    func terminalScreens() async {
        let context = sampleContext()
        for phase: PanePhase in [.opening, .live, .ended, .failed("the connection closed before this finished")] {
            render(context, PaneSurface(model: HcPaneModel(previewing: phase), isActive: true))
            render(context, NavigationStack { HcTerminalScreen(title: "Backend", previewing: phase) })
        }
        await settle(context)
        #expect(context.connections.endpoint == nil)
    }

    @Test("the pairing and unpair sheets render")
    func sheets() async {
        let context = sampleContext()
        // `.waiting` is rendered through `PairingCaptureView` with the camera
        // answered rather than asked: the phase's own preview mounts a capture
        // session where access is already granted, and a test must not.
        render(context, NavigationStack {
            PairingCaptureView(model: PairingModel(previewing: .waiting), previewCamera: false)
        })
        render(context, NavigationStack {
            PairingPhaseView(model: PairingModel(previewing: .paired(.preview)))
        })
        render(context, NavigationStack {
            PairingPhaseView(model: PairingModel(previewing: .failed("nothing answered")))
        })
        render(context, UnpairSheet(model: UnpairModel(previewing: .working(.preview))))
        render(context, UnpairSheet(model: UnpairModel(previewing: .keyRemains(
            .preview, reason: "nothing answered",
            advice: .revoke(deviceMarker: PairedPeer.preview.deviceMarker, deviceFingerprint: nil)
        ))))
        render(context, UnpairSheet(model: UnpairModel(previewing: .hostRefusedKey(
            .previewSparse,
            advice: .check(deviceMarker: nil, deviceFingerprint: "SHA256:abc")
        ))))
        #expect(context.connections.endpoint == nil)
    }

    /// **A bar button's question opens out of that button.**
    ///
    /// On iOS 26 a confirmation dialog grows from the view it is attached to,
    /// so where the modifier sits is the whole of the behaviour — and it is
    /// invisible in a diff: attached to the screen instead, everything still
    /// compiles, still asks, and appears from nowhere near the finger. UIKit
    /// says which it was. The dialog is a popover, and its source is either a
    /// bar button item or it is not.
    ///
    /// Delete is the case that pins *which* button: it shares the bar with
    /// Start, and a dialog that hung off the bar rather than off its own
    /// button would open from the wrong corner.
    @Test("asking to unpair from the settings sheet closes it first")
    func unpairFromSettingsClosesTheSheet() {
        let router = PeerSettingsRouter()
        router.show(.preview)
        #expect(router.peer?.id == PairedPeer.preview.hostKey)

        router.requestUnpair(.preview)
        #expect(router.peer == nil, "the sheet was still up when the unpair was handed over")
        #expect(router.takePendingUnpair()?.hostKey == PairedPeer.preview.hostKey)
        // Consumed: a dismissal is the one moment it applies, and leaving it
        // set would unpair on the next one.
        #expect(router.takePendingUnpair() == nil)

        // An ordinary close must not leave one armed either.
        router.show(.preview)
        router.requestUnpair(.preview)
        router.close()
        #expect(router.takePendingUnpair() == nil, "a close left an unpair armed")
    }

    /// A parked model must stay parked: `show` and `retry` are both reachable
    /// from a render, and either one attaching would open an exec channel from
    /// a canvas.
    @Test("a parked terminal model opens nothing")
    func parkedModels() async {
        let pane = HcPaneModel(previewing: .live)
        pane.show(TerminalGrid(cols: 80, rows: 24))
        pane.retry()
        #expect(pane.phase == .live, "a parked model tried to attach")
    }
}
#endif
