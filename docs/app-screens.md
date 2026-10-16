# App screens: connecting, lists, layout, previews, pairing UI

> Moved verbatim from `CLAUDE.md` on 1 Oct 2026. Where the text says "this file", "above" or "below", it means the old single file; a **bold** section name can be found with `grep -r docs/`.

## Connecting to a paired peer (Phase 2)

`PeerConnection.connect` is where the pairing record pays off: everything the
connection needs was learned once, out of band — which machine this is (the host
key), where it answers, who to log in as, and where `herdr` lives. Nothing
prompts, guesses, or trusts anything on first sight.

- **One live connection at a time**, held by `ConnectionStore`. A phone drills
  into a single host, and every screen in that drill-down wants the same SSH
  session rather than a handshake each. No host being browsed releases it —
  re-entering costs a handshake, an idle SSH session left open on someone's Mac
  costs their trust.
  - **What "no host is being browsed" means moved with the sidebar**, and the
    old reading became actively harmful. It used to be `PeersView.task`, on the
    premise that being back at the root was the only way to see that list; with
    a permanent sidebar the list appears **once, at launch**, so the release
    would never fire again — and a rotation or a Slide Over resize that
    re-mounted it would release a connection out from under a live pane.
    `RootView` watches `NavigationRouter.selectedPeer` going nil instead, which
    is the condition in both layouts. Switching straight from one host to
    another needs nothing: `connection(for:)` already releases before dialling
    a different host key.
- **Keeping that promise takes more than a stored reference, because a dial
  cannot be called off.** `PeerConnector` races in a detached task precisely so
  a slow address cannot hold up a fast one, so a handshake started for a screen
  the user has already left will still finish. Two guards follow: concurrent
  callers **join** the dial in flight rather than starting a second (otherwise
  a pull-to-refresh during the first load races every endpoint twice and leaks
  whichever transport loses the assignment), and a dial that completes after
  `release()` **closes itself** instead of installing. `SSHTransport.disconnect`
  documents the same hazard for its own dial; the store reproduced it one level
  up before this.
- **A release takes what it is responsible for *before* it suspends.** It
  awaits the endpoint refresh, bounded only by an already-running SSH command —
  the `tailscale` probe's watchdog is five seconds — and it is started by a
  screen going away rather than by anything anybody waits on, so a later caller
  can dial and install inside that window. Reading `connecting` and `current`
  *after* the await and closing whatever was found there meant a release could
  disconnect a brand new connection to a **different host**: back out of one
  Mac, pick another within a few seconds, and its list screens fail against a
  transport that call had closed under them. Clearing both up front makes a
  later dial invisible to it. The `pending` cancel moved up for the same
  reason — `connected(for:)` re-checks `task.isCancelled` before installing,
  and that check is only worth anything if the cancellation has already
  happened.
- **A dial claims its place before it closes the old connection.**
  `connected(for:)` used to `await release()` and only then set
  `connecting` — and a release suspends, disconnecting the old connection.
  A second caller arriving in that window found no connection and no dial in
  flight, so it dialled too; both installed, and the first was overwritten
  without being closed: an SSH session left open on the host with nothing
  referring to it. After a network change, a pull-to-refresh overlapping a
  screen's own `.task` load was enough, and so was the host's load read until
  it stopped dialling (found in review of the load-on-connect change, not
  observed). Now `detach()` takes the old state synchronously, the dial's own
  task closes it before dialling, and `connecting` is set before the first
  suspension, so the second caller joins. `release()` is `close(detach())`.
  `RelayedStoreTests.concurrentCallersShareOneDial` pins it — the relay's
  `.release` is the suspension — and failed on the old code with a third
  connection where there should be a second.
- **A cached connection is keyed by link state as well as host key.** It is
  raced once and then pinned to the address that won, so one made on Wi-Fi
  against a `.local` name can only fail after the phone moves to cellular —
  and the overlay address that would have worked never gets a turn, because the
  cache answers first. `ConnectionPolicy` holds this and the "is this error
  fatal to the connection?" rule, in `BleatKit` where both are tested.
- **A `HerdrError` does not discard the connection.** The host was reached and
  said no. Reconnecting on it would cost a handshake per retry and hide the
  real problem behind a reconnection that always succeeds. `TransportError`
  does discard it, which is what lets a retry re-race after a network change.
- **Every list load carries a generation.** Pull-to-refresh and the initial
  `task` overlap, and without one a slow first load finishing late overwrites a
  successful refresh with its own failure — an error banner over rows that
  arrived perfectly well. Refreshing also keeps the rows on screen: `refreshable`
  draws its own spinner, and replacing the list underneath it is a downgrade.
- **Reachability is two questions, not one**, and `LinkState` carries both: is
  a local network directly attached, and is there a tunnel. It used to be the
  single question "is this Wi-Fi or Ethernet", which quietly assumed anything
  private needs the attached link — true until a VPN routes the private subnet,
  which is exactly what a zero-trust client does. `Reachability` lives in
  `BleatUI` rather than `BleatKit` — `Network` is Apple-only — while `LinkState`
  and the rules it feeds are in `BleatKit` where they are tested.
  - **The tunnel question needs its own `NWPathMonitor(requiredInterfaceType:
    .other)`.** Asking the default path with `usesInterfaceType(.other)` gets
    the wrong answer for the case that matters: Twingate and most zero-trust
    clients split-tunnel, claiming routes only for configured resources, so the
    **default** path stays on cellular and does not use the tunnel at all. A
    monitor with a required interface type reports satisfied when such an
    interface exists and can carry traffic, which is the question being asked.
  - **`LinkState` is the cache key for a live connection**, not just an input to
    the race. A tunnel coming up widens the candidate list, so a connection made
    before it connected was raced over a strictly smaller set; reusing it would
    pin the phone to that set for as long as the screen stays open — the same
    shape of bug the Wi-Fi/cellular half was added to fix.
    - Compared through **`LinkState.candidateIdentity`**, not as a whole. On the
      local link every endpoint is a candidate whatever the tunnel is doing, so
      a tunnel change there cannot alter the raced list — and comparing it would
      discard a working connection for nothing. An on-demand VPN profile
      connecting and dropping while the app sits on Wi-Fi would otherwise tear
      down the live SSH session and re-handshake on every request.
- **"No address to try here" is not "nothing answered."** A LAN-only peer on
  cellular was not dialled and failed; it was ruled out, and the remedy is a
  different network or an overlay endpoint rather than a host that needs
  starting. The two get different messages.
- **`herdrPath` can still be discovered**, for a record made before pairing
  stored it, and the transport learns it in place rather than being rebuilt —
  a second handshake to carry one string would be absurd.
- **Write-backs after a successful connection are targeted mutations, never a
  `save` of an edited copy.** `save` merges, and a merge takes the newer
  record's `lastGoodEndpoint`; a copy loaded a moment earlier carries the
  *previous* winner, so saving it undoes the one just recorded. Both
  `recordSuccess` and `recordHerdrPath` edit the stored record in place.

The watch uses this same store with a relay in place of the dial — see
[`watch.md`](watch.md).

## The list screens (Phase 2)

Sessions, workspaces and agents are the same screen three times, so the loading
is written once: `RemoteList` holds the generation token, the cancelled-screen
silence, the drop-a-dead-connection rule and the keep-rows-through-a-refresh
rule. Three copies of that would drift, and each way it drifts is a bug the user
sees rather than a crash anyone catches. `RemoteListView` does the same for the
three states a fetched list has — a result that is empty is not a failure, a
failure needs a way back, and neither should look like the other.

- **Session selection does not cost a reconnect.** `HERDR_SESSION` is a command
  prefix, not something the handshake settles, so `SSHTransport.useSession`
  changes it on a live connection. Making the session part of the connection's
  identity instead would have meant a fresh handshake on every drill-down from
  the session list. It assumes one drill-down at a time, which is what the app
  does.
- **`pane_id` is already the full target.** The host sends
  `"pane_id":"w2:p1"` next to `"workspace_id":"w2"` — in the fixtures and live —
  so joining the two gives `w2:w2:p1` and every attach fails. `Agent.target`
  exists to stop that being rebuilt by hand, which is exactly how it went wrong
  once. A test that built its own `Agent` with a bare `"p1"` passed happily
  while the property was wrong; the test reads the fixture now. **Build model
  test data from `Fixtures/`, not from memory** — CLAUDE.md already said to look
  at the fixture before writing a model, and this is what skipping it costs.
- **A failed refresh keeps the rows it had.** `Loadable.stale` carries the last
  value alongside the failure, because replacing a good agent list with an
  error page over one dropped packet is a worse lie than showing slightly old
  data and saying so. An empty-state overlay is `allowsHitTesting(false)` for a
  related reason: it covers the whole list, and "no agents are running here" is
  precisely the message a user wants to pull-to-refresh out of.
- **A failed load says which of the three error classes it was.** CLAUDE.md's
  conventions name them — `HerdrError` (host said no), `TransportError`
  (network), `DecodingError` (contract drift) — and `RemoteListView` used one
  title for all three: *Could not reach the host*. Found on a live host, 8 Sept
  2026: a `phone` session whose herdr server was a protocol version behind the
  client answered with exactly what was wrong and how to fix it, and the phone
  reported it as a network failure over the top of that message. The user is
  sent to check a network that is working perfectly — the same lie
  `TransportError.authenticationFailed` was added to stop one layer down.
  - `Loadable` carries a `LoadFailure` now rather than a bare string, and
    `ErrorMessage.failure(of:)` does the classification in one place.
    `LoadFailureTests` pins it, on the real protocol-mismatch text.
  - A `HerdrError` shows **herdr's own `message`**, not `description`, which
    prefixes `herdr workspace list failed (1):`. That is right in a terminal
    and noise on a phone; herdr's sentence is usually the whole fix.
- **Ordering is not restated in the UI.** `HerdrClient.agents()` returns them
  already sorted by attention and `workspaces()` likewise, so the app cannot
  disagree with the console tool about what "blocked first" means.
- **`Agent.displayTitle` is in `BleatKit`**, because both the app and
  `bleat agents` have to choose among Herdr's three names — stripped title, raw
  title, agent kind — and each can be missing *or empty*. The tool's own version
  fell back to an empty string, so an untitled pane printed as a blank column;
  the shared one falls back to the pane id, which is at least unique.
- **A pane's `foreground_cwd` is shown in preference to `cwd`**, because it
  follows the running process, and it is truncated at the **head**: every row
  starts `/Users/…/Developer/…`, so truncating at the tail throws away the only
  part that distinguishes one checkout from another.

## Two columns on an iPad, one stack on a phone (Phase 3, 20 Sept 2026)

`RootView` is a `NavigationSplitView`: the paired hosts in the sidebar, and
everything below a host in the detail column's `NavigationStack`. On a phone the
split view collapses into the single stack the app already was, with picking a
host standing in for the first push.

- **Two columns, not three, and the drill-down is why.** It is five screens deep
  — hosts → sessions → workspaces → agents → pane — and a split view has at most
  three columns, so something has to stay a stack whatever is chosen. Apple's
  shape for that is a selection in the sidebar and a stack in the detail, which
  is also the arrangement that collapses predictably. A three-column version
  (hosts | sessions→workspaces→agents | pane) would give the pane the widest
  column and keep the agent list beside it, which is the better *iPad* layout
  and the one to revisit — it needs the middle column to nest a stack of its
  own, and the collapse path is then nobody's documented case.
- **The router is a selection plus a path**, not one path. `selectedPeer` is a
  host key; `path` is everything under it.
  - **Changing the selection clears the path in the same write**, which is why
    it is a computed property over a private stored one rather than an
    `onChange` in the view. SwiftUI evaluates the detail column from the new
    selection and the old path together, so clearing afterwards draws one host's
    workspaces under another host's name for a frame.
  - **Re-writing the same host key is not a change.** A `List(selection:)`
    re-asserting its value would otherwise throw away the screens the user is
    standing on.
- **`Route.peer` is now the detail column's root and is never pushed.** It stays
  a route so `RouteView` remains the single place a route becomes a screen —
  including its answer for a host unpaired while its screens were up.
- **Unpairing leaves a host's screens only if they are the ones on display.**
  `popToRoot()` is gone; `leave(hostKey)` replaces it. Before, the only way to
  reach the unpair swipe was a peer list with nothing pushed over it, so popping
  unconditionally was right. With the host list permanently on screen a host can
  be unpaired while a *different* one is being browsed, and an unconditional pop
  throws away screens for something that did not happen to them.
- **`PeersView` is a `List(selection:)`, not a `NavigationLink` per row.** A
  link there pushes onto the *sidebar*, leaving the detail column showing
  nothing. Collapsed, SwiftUI turns the same selection into the push the list
  used to make itself.
- **The detail root carries `.id(hostKey)`, and leaving it off shipped a bug.**
  Every screen below it is *pushed*, so it gets a fresh view and fresh `@State`
  by construction; the root is **reused** when the selection changes — same
  type, same position — so `PeerDetailView` kept the `RemoteList` holding the
  previous host's sessions, and its plain `.task` never re-ran because the view
  never re-appeared. What reached the iPad was one host's name over another
  host's sessions. A `.task(id:)` would have fixed the list and left the rest —
  a half-typed session name, an armed confirmation, a start in flight —
  attached to the host that had been left. `DetailIdentityTests` keeps the
  broken shape beside the fixed one, as `ColorSchemeTests` does.
- **Releasing the connection needs a second trigger on an iPad, and the
  selection alone would have left a session open forever.** A split view that
  never collapses has no gesture that deselects — tapping the highlighted row
  rewrites the same host key, which is not a change — so `selectedPeer` goes
  nil essentially never there. `RootView` also releases on `scenePhase ==
  .background`. Not `.inactive`: that is an app-switcher glance or a
  notification banner, and it would cost a handshake every time the user looked
  away.
- **`rootCollapsed` and `rootExpanded` render it in both shapes**, and getting
  that to mean anything took three attempts, each worth not repeating:
  - **A window's frame does not set the size class.** The first version only
    made the window 1210 points wide; `NavigationSplitView` collapses on
    `horizontalSizeClass`, which UIKit takes from the scene and the device
    idiom, so both calls exercised the collapsed tree while the comment claimed
    they covered both.
  - **`.environment(\.horizontalSizeClass, .regular)` is necessary but not
    sufficient.** Without it the test fails even on an iPad simulator — a
    `UIWindow` built in a test has no scene to inherit from. With it, it still
    fails on an iPhone simulator; the idiom wins. So `rootExpanded` is
    `.enabled(if: UIDevice.current.userInterfaceIdiom == .pad)` and says so,
    rather than being quietly weakened into something every destination passes.
  - **Do not assert on rendered text.** SwiftUI does not back a `Text` with a
    `UILabel`, so an accessibility walk over a correctly expanded iPad window
    returned `["Bleat"]` — the navigation bar's title and nothing else — while
    the columns were demonstrably there. A test built on that walk passed alone,
    failed in a full run, and measured nothing either way.
    `UISplitViewController.isCollapsed` is what the question is actually about
    and UIKit answers it directly.
  - Both select no host **deliberately**: selecting one mounts `PeerDetailView`
    with a live `RemoteList`, and `PairedPeer.preview` carries this Mac's real
    LAN address, so the render would dial. `NavigationRouterTests` covers the
    selection rules without a window.

### Two things the sidebar makes reachable that were not (open)

Neither is new *behaviour* — both are existing rules meeting a new affordance —
and neither is fixed. Written down rather than discovered twice.

- **Unpairing a host takes the connection away from the host being browsed.**
  `UnpairModel` revokes over `connections.shell(for:)`, and `ConnectionStore`
  holds one connection at a time, so unpairing B releases A's. Before the
  sidebar this could not happen: the unpair swipe lived on a root list with
  nothing pushed over it. Now a swipe in the sidebar can do it while A's
  screens are up. The list screens recover by themselves — they re-dial on the
  next load — so the casualty is a **live pane**, whose `observe` stream dies
  under it. `leave(hostKey)` deliberately does *not* pop A: being thrown out of
  the host you are watching is the worse everyday outcome, and the old
  unconditional `popToRoot()` did exactly that. Revisit if the pane's ended
  state turns out to read as a bug rather than as what happened.
- **Toggling the sidebar resizes a live pane's pty on someone's Mac.** The
  pane's grid comes from the terminal view's bounds and `PaneModel.start()`
  `stty`s the host to match, so the detail column's width is now a function of
  `columnVisibility` — a button. This is the hazard the `PaneKeyBar` note
  already states ("anything in a safe area is layout, and layout here is the
  stream's size"), and rotation has always been able to trigger it; the sidebar
  button is a new way in, not a new failure. The fix, when it is wanted, is the
  one the keyboard path already uses: freeze the grid while the pane is held
  and thaw when it is released.

## A host's screen is its sessions; everything else is a sheet (Phase 2)

(Since 1 Oct 2026 the sheet also says what the host runs, and the screen
carries a bar with how busy it is — see the next section.)

`PeerDetailView` used to be a `Form` with the sessions on top and four sections
of pairing detail under them — user, `herdr` path, host key fingerprint,
addresses, device marker, unpair. It is the sessions and a bottom bar now, and
the rest is `PeerSettingsView` behind the load bar (behind a gear until
3 Oct 2026).

- **It is a `RemoteListView` like the workspaces and agents screens.** The
  section it used to be drew its spinner *in a row* on purpose, so the details
  below stayed readable while the host was being reached. With nothing below,
  that reasoning is spent and the four states belong in the shared list view —
  which is also where "an empty answer is not a failure" and "a failed refresh
  keeps its rows" are written once rather than twice. `SessionsSection` was
  deleted with it; `SessionLink` and `SessionRow` are unchanged.
- **`PeerSettingsRouter` is the third root-level router, for the third time for
  the same reason.** The sheet is opened from a swipe on the peer list *and*
  from the load bar on a peer's own screens, and those two are in the navigation
  stack at the same time — a `.sheet` on each would be two presentations of one
  intent, of which SwiftUI raises whichever it reaches first and silently drops
  the other. `PeerSettingsFlow` presents it at the root beside `.unpairFlow()`
  and `.pairingFlow()`.
- **Unpairing from inside the sheet closes it first, and that ordering is
  load-bearing.** The confirmation dialog is presented at the root, *underneath*
  this sheet, so one raised while it is still up is covered by it and never
  seen — the Unpair button would appear to do nothing. The router holds the
  request instead and `PeerSettingsFlow` starts it from the sheet's
  `onDismiss`, which fires only once the dismissal has finished. A plain close
  clears it, or a later dismissal would unpair a host nobody asked about.
  `PreviewSmokeTests.unpairFromSettingsClosesTheSheet` pins both halves.
- **The sheet yields to a `bleat://` link**, exactly as the device-key sheet
  does: SwiftUI will not raise a second sheet over one already presented, so a
  pairing request arriving while settings is up would be lost *and* leave
  `PairingRouter.isPresented` true with nothing on screen — which makes the
  Pair button a no-op until the app is relaunched.
- **The swipe on a peer row still only asks.** It has two actions now, Unpair
  and Settings, and Unpair is declared first so it stays what a full swipe
  reaches — which is what `onDelete` did before. That is safe to trigger by
  accident precisely because it opens a confirmation rather than acting; see
  the unpair section for why a swipe must never revoke a key on its own.
- **The plus starts a session, in a cover rather than an overlay.** A scrim over
  the whole screen with one field above the keyboard and a checkmark beside it.
  A `fullScreenCover` with `.presentationBackground(.clear)`, because on iOS 26
  the bottom bar floats above the screen's content — an `.overlay` would leave
  the navigation bar undimmed and, worse, leave the plus button that opened it
  drawn on top of the scrim and still tappable. The scrim is the only way out
  and is **inert while the launch is in flight**, for the reason the pairing
  sheet cannot be dismissed mid-swap: this is the only place the outcome is
  reported. See **Starting a session** in
  [`creating-from-the-phone.md`](creating-from-the-phone.md) for the command.
- **The load bar opens the settings; the gear is gone** (3 Oct 2026, asked
  for). The bar is the host, so tapping it — on the host's screen, a
  session's or a workspace's — opens what is known about it, and the gear's
  corner went to **Pair Another Device** (a QR). With no connection there is
  no bar, so an unreachable host's settings are the swipe on its row in the
  list — the one case where they are a step further away.
- **The sheet zooms out of the bar.** `matchedTransitionSource` on the bar,
  `.zoom` on the sheet, keyed by host key so it grows out of the bar for
  *that* host. The namespace cannot be local: the sheet is presented at the
  root and the bar is two or more screens down, so `PeerSettingsFlow`
  declares it and publishes it through `EnvironmentValues.peerSettingsNamespace`.
  Optional, because a `Namespace.ID` cannot be minted outside a `@Namespace` —
  a preview of `PeerDetailView` alone has none, and the swipe on the peer list
  has no bar on screen to grow from. A zoom with an absent source falls back
  to a plain presentation. **`.zoom` is unavailable on macOS** while
  `matchedTransitionSource` is not, so the platform branch lives in
  `zoomTransition` rather than at each call site.

## What a host says about itself (Phase 3, 1 Oct 2026)

One probe, two halves with different lifetimes — `HostStatus` is a `HostInfo`
and a `HostLoad`.

- **`HostInfo` sticks to the host**: system, kernel, architecture, model, herdr
  version. Stored on the peer record (`PairedPeer.hostInfo`), so it survives a
  disconnect and a relaunch.
  - **The host list shows it without connecting to anything**: a mark for the
    kind of machine in front of the name, and the system (`macOS 27.0.1`) where
    `user@address` used to be. A peer that has never been connected to has said
    nothing yet, so its row keeps `user@address` and a generic mark.
  - **Pairing asks too** (3 Oct 2026), so a host arrives in the list already
    saying what it is. `PairingClient` runs the probe over the device session
    before closing it, with `sampling: false`: the processor sample is the
    one read that waits a second, and pairing has no use for a load. Best
    effort — the pairing has succeeded by then. A re-pair lays its report
    over the record (`PairedPeer.merging`) rather than replacing it.
  - **The load bar is headed by `user@name`, with the machine trailing it**
    in secondary (`pi@adam … Raspberry Pi CM5`), so the numbers under it say
    whose they are. Not on the watch, where the screen's title already does.
  - **The machine is `HostInfo.shortModel`**: the name a Mac is sold as when
    it gives one, else the model without a Pi's board revision and with
    "Compute Module" shortened to CM. The sold-as name is `product-name` from
    `ioreg -rc IOPlatformDevice` (`MacBook Air (M1, 2020)`), stored as
    `HostInfo.modelName`; only Apple silicon has it, so an Intel Mac shows its
    identifier. Added 3 Oct 2026, asked for from the phone.
  - **All of it is in the settings sheet**, under **System**, with the pairing
    detail it belongs beside.
  - **Laid over, never replaced.** `HostInfo.updated(with:)` is field by field
    and a missing field never erases a known one: each part of the probe fails
    alone, so a reply without a model is a tool that did not answer this time.
    `PeerRegistry.recordHostInfo` writes only when something changed — it runs
    after every reading — and `PeerStore` reloads only then, because a reload
    redraws every list of hosts.
  - **The mark is `HostInfo.platform`**, from the kernel's name and, for a Pi,
    the model. A Mac gets `apple.logo`. **SF Symbols has nothing for a
    Raspberry Pi or for Linux**, so a Pi gets `berry`, a custom symbol, and
    other Linux hosts `server.rack`.
  - **`berry` is a drawing of the fruit, not the Raspberry Pi logo and not a
    variation on it.** Their trademark rules (read 1 Oct 2026; last updated
    17 June 2026, <https://www.raspberrypi.com/trademark-rules/>) allow the
    logo only "in connection with the sale or distribution of genuine
    Raspberry Pi products or services", require a licence for commercial use,
    and separately forbid "a name or logo which is so similar to the Raspberry
    Pi Marks that it may confuse or mislead". So drawing something close to it
    is no safer than using it. The logo is one outline cut into segments under
    two broad leaves; `berry` is loose round drupelets under a five-pointed
    calyx and a stem. **Do not redraw it towards the logo.** The official one
    needs a licence from Raspberry Pi first.
  - **It is generated**: `swift Design/symbols.swift` writes an SF Symbols
    template into `BleatUI/Resources/Symbols.xcassets`. Only Regular-M is
    drawn; Xcode accepted that and derives the rest.
    `PreviewSmokeTests.berrySymbol` checks it loads from the package's bundle
    *as a symbol* — `Image(_:bundle:)` draws nothing for a name it cannot find,
    so a rejected template would be a gap beside every Pi and fail no build.
    The catalog is a resource of the package, not the app, so previews and the
    render tests find it. `swift build` on a Mac copies the catalog without
    compiling it; nothing there draws.
- **`HostLoad` is live**: processor, load average, memory, disk, temperature,
  uptime. Never stored.
  - **It is a bar, `.safeAreaBar(edge: .bottom)`, carried down the
    drill-down**: the host's screen, a session's, a workspace's
    (`hostLoadBar(for:)`). The processor is one line — share busy, load
    average, and the temperature with its own icon when the host has one.
    Memory and disk are gauges: amount used, share in brackets, a bar that
    turns orange at 75% and red at 90%. Uptime is read and not shown.
  - **On a watch it is the list's first row, not a bar** (`HostLoadSection`).
    See [watch](watch.md).
  - **Not on a pane.** Layout there is the stream's size, and a bar that comes
    and goes with the connection would resize the pty on someone's Mac.
  - **One reading, in `AppContext.hostLoad`**, not per-screen state: three
    screens deep in one machine show what the last one read. A screen
    appearing reads again only if the reading is older than ten seconds; a
    pull-to-refresh always reads, and holds its spinner for the probe's second.
    There is no timer.
  - **It never dials, and is shown only while connected.**
    `HostLoadStore.refresh` returns at once unless `ConnectionStore.liveShell`
    has a connection to this host that it could reuse as it stands, and `load(for:)` is nil the moment the
    connection goes — a number about a machine nobody is talking to is not
    worth showing. **A reading is tied to the connection it was read over**
    (`ConnectionStore.connectionID`), not just to the host: the app releases
    its connection in the background, and matched on the host alone an
    hour-old reading came back as live when the same host was dialled again.
    (Found in review.) That also keeps previews and the render tests off the
    network: they have no connection, so a read willing to open one would dial
    a real host from the canvas. `PreviewSmokeTests.hostLoadBar` pins it.
  - **A reading is asked for each time a connection comes up**:
    `hostLoadBar(for:)` carries `.task(id: connectionID)`, on the watch as
    well. Each screen also asks after its own list loads, which covers a pop
    back to it; a read in flight on the same connection, or one under ten
    seconds old, turns the extra asks away.
    - **Fixed 3 Oct 2026, reported from a phone:** arriving on a host, the bar
      stayed empty until a pull-to-refresh. A reading used to be tagged with
      the connection that was live when it was asked for. But asking for the
      shell can replace that connection — `ConnectionStore` re-dials when the
      network has changed since its dial, and a tunnel coming up just after
      the first connection is the usual case. So the reply came back over the
      new connection, looked stale, and was dropped, and nothing asked again.
      Now the read never goes through `shell(for:)`:
      `ConnectionStore.liveShell` hands over the live connection and its
      number together, or nothing when that connection could not be reused,
      and the list's own load does the re-dial. The new connection's number
      starting a read of its own (`.task(id:)`) is what fills the bar. Not
      reproduced on a simulator, which cannot bring a tunnel up under a
      connection: the cause is read from the code.
    - **The first version of that fix read through `shell(for:)` and re-read
      the number afterwards** — and with the read now starting beside the
      list's load rather than after it, the two raced into
      `connected(for:)` after a network change: each released, each dialled
      before either had set `connecting`, and the second install orphaned the
      first SSH session on the host. (Found in review, not observed.) A load
      read that cannot dial cannot race one — and `connected(for:)` itself
      now cannot be raced either; see the store's bullets above.
  - **Best effort and silent.** A failed read keeps the last reading. It does
    not call `ConnectionStore.handle`: the list above reports the same dropped
    connection, and two loads each releasing it would have the slower tear down
    what the faster one's retry had just dialled.
  - **The bar appears about a second after the first list on a host**, which
    moves the bottom of that list once. Deeper screens have it from the start.

The probe:

- **One shell command, `HostStatusProbe.command`, over
  `ConnectionStore.liveShell`.** herdr reports none of this but its own version, so
  it is plain shell like pairing and the directory check, and it leaves the
  session prefix alone. No change to `HerdrTransport`.
- **The script tags raw tool output and the phone parses it.** Every line comes
  back as `bleat-host:<tag>:<the tool's own line>`; the shell does no
  arithmetic. The parser is fed from `Fixtures/host-status-macos.txt` and
  `host-status-linux.txt`, which are the command's real output on the dev Mac
  and the Pi. Untagged lines — a profile's banner — are ignored, and each field
  parses or is absent on its own.
- **It is wrapped in `/bin/sh -c '…'`**, because an exec channel runs through
  the account's login shell and the script is POSIX. The login shell then only
  has to read one single-quoted string, so the script holds no single quote and
  no `\\`. Run under zsh, bash, dash and macOS's `sh`; **not run under fish**,
  which is not installed on either host.
- **`PATH` is set to the four system directories**, not inherited, so `df` is
  the system's `df`. herdr is therefore not searched for: the probe is handed
  `peer.herdrPath`, and leaves the version out when the peer has none yet.
- **What each host can and cannot say** (measured, both on herdr 0.9.3):

  | | macOS 27.0.1 (M1) | Debian 13 (Pi CM5) |
  |---|---|---|
  | system | `sw_vers` | `PRETTY_NAME` in `/etc/os-release` |
  | kernel, arch | `uname -srm` | `uname -srm` |
  | model | `sysctl hw.model` | `/proc/device-tree/model`, else DMI `product_name` |
  | model name | `product-name` from `ioreg` (Apple silicon) | none |
  | cores | `getconf _NPROCESSORS_ONLN` | the same |
  | processor | last line of `iostat -n0 -c 2 -w 1` | two reads of `/proc/stat`, 1 s apart |
  | load | the same `iostat` line | `/proc/loadavg` |
  | memory | `vm_stat` + `hw.memsize` | `MemTotal − MemAvailable` |
  | disk | `df -Pk "$HOME"` | the same |
  | temperature | **not available** | `/sys/class/thermal/thermal_zone*` |
  | uptime | `kern.boottime` against `date +%s` | `/proc/uptime` |

  - **A Mac gives no temperature without root.** `powermetrics` needs `sudo`,
    `pmset -g therm` only says whether a thermal warning was ever recorded, and
    Apple silicon has no `sysctl` for it. The row is simply absent.
  - **Processor usage costs one second.** Both hosts count since boot, so one
    reading is an average over days: the first `iostat` line said 73% idle on a
    Mac whose second line said 0%. The second is the sample. The whole probe
    took 1.4 s from this Mac to the Pi over SSH.
  - **Mac memory "used" is anonymous pages less purgeable, plus wired, plus what
    the compressor occupies** — Activity Monitor's definition. Total less free
    would read 16 GB of 16 GB on any Mac that has been up for an hour.
  - **Disk used is total less available, on the volume under `$HOME`.** `/` on
    APFS is the sealed system volume (14% used on a disk that was 82% full), and
    a volume's own "Used" leaves out its siblings in the container.
  - **The herdr version is the client binary's** (`herdr --version`), which is
    what runs this phone's commands. A server started before an update can be
    older; `herdr status --json` reports both and `restart_needed`, and is not
    read yet.

## Previews (Phase 2)

Every view has a `#Preview`, and they all take `traits: .sampleData`. The trait
injects an `AppContext` — which every screen above a row reads from the
environment, so without one a preview of anything crashes on the missing value.
`.noHosts` is the same context with nothing paired, for the empty state that is
the first screen on a fresh install.

- **The context is real; the registry is not.** `PeerRegistry.sample()` writes
  the sample hosts into a fresh directory under `NSTemporaryDirectory()`, one
  per call. Never `applicationSupport()`: `AddEndpointView` and the unpair flow
  both *write*, so a preview pointed at the real registry edits the device's own
  peer list from the canvas. An earlier `AddEndpointView` preview built a plain
  `PeerStore()`, which is exactly that. A fresh directory per call rather than
  one wiped and reused, because Xcode keeps more than one preview alive and a
  shared path means the one being edited has its file rebuilt underneath it the
  moment another renders.
- **No preview reaches the network**, and that needs a seam rather than a
  promise: `ConnectionStore` is real, and every list screen loads in `.task`.
  `RemoteList.init(previewing:)` hands the rows in and makes `load` a no-op, and
  the screens that own one take a `#if DEBUG` initialiser that uses it. The
  guard is the **first** thing `load` does — after `state = .loading` it would
  show a spinner where a seeded `.failed` was meant to be. `PaneModel`,
  `TranscriptModel`, `PairingModel` and `UnpairModel` take the same treatment,
  parked in a phase; `PaneModel.start()` and `TranscriptModel.follow` return
  early, since a canvas that opened an `observe` stream would hold an exec
  channel on the Mac for as long as the preview lived.
- **The states worth previewing are the ones a working host never produces.**
  A failed refresh over rows that already arrived, a `done` agent, a host that
  refused the device key, a pane whose stream ended, a `bleat pair` that could
  not reach the local network. Those are most of the writing on these screens
  and none of them can be reached by pointing the app at a healthy Mac.
- **`PreviewSmokeTests` lays every one of them out**, in `BleatUITests`, for the
  reason `PaneGeometryTests` exists: a preview that compiles can still trap at
  render, and nothing mechanical would catch it. It also pins the promise —
  `ConnectionStore.endpoint` stays nil through every render, which is what says
  no screen dialled.
- Sample data lives in `Previews/`, `#if DEBUG`, in `BleatUI` rather than
  `BleatKit` so the domain layer ships none. It is hand-written rather than read
  from `Fixtures/` — those are not bundled with the app — but shaped like the
  captured output: `pane_id` already carrying its workspace, opaque workspace
  ids of both lengths, and all five agent states, since a sample list that was
  all `idle` would leave the screen this app is organised around with nothing to
  show.
- Five files have no preview and say why in place: `QRScannerView` and
  `TerminalHost`/`PaneTerminalView` need a camera or a live stream, and
  `PairingFlow`/`UnpairFlow`/`PeerSettingsFlow` present rather than draw —
  `RootView` exercises them, and each previews what it presents.

## The pairing UI (Phase 2)

`PeersView` is the app's first screen and there is no manual host list any more.
Adding a host by typing an address existed because there was no other way to
acquire one; pairing is the way now, and the promise is zero host setup beyond
Herdr. `HostRegistry` stays in `BleatKit` for the console tool.

- **Two ways in, and both are needed.** The camera, and a pasted
  `bleat://pair?d=…` link. `bleat pair` falls back to printing that link when
  the window is too small for a QR or is not a terminal at all, and a fallback
  nothing can consume is not a fallback.
- **A refused camera is not a dead end.** The scan section says what happened
  and offers Settings; the paste field is still there below it.
- **Claiming a scanned code is synchronous.** A camera reports the same QR many
  times a second and each frame spawns a `Task`, so checking "have we tried
  this?" and marking it must happen in one non-suspending step. An `await`
  between them is a place the second frame runs — and the enrollment key is
  single-use, so two redemptions would race to install and then delete it.
- **A code that is not addressed to Bleat is ignored, not failed.** A camera
  sees whatever is in front of it, and turning a Wi-Fi QR into "pairing failed"
  buries the real errors and takes the viewfinder away while the user is still
  aiming. `PairingPayload.looksLikeAPairingCode` checks only scheme and host —
  anything that *claims* to be a pairing code and will not decode is a damaged
  or newer code, and that is worth reporting.
- **"Try again" clears the codes already tried.** Otherwise the button does
  nothing at all: the failure being retried is nearly always transient, so the
  user points the camera at the *same* QR, and every frame of it is filtered.
  For the same reason the paste path must not mark a code as attempted — a
  failed paste would block the camera from ever reading that QR.
- **The sheet cannot be dismissed mid-swap**, by the button or by swiping. A
  pairing left running with nobody watching loses the two outcomes that matter
  most: a host key that does not match the code — the whole point of the
  out-of-band pin — and a peer the host accepted but the phone could not record.
- **The capture session is owned by one `nonisolated ... @unchecked Sendable`
  type and never handed out.** AVFoundation's classes are not `Sendable` and
  cannot be, so every `DispatchQueue.async` that captured one was a
  strict-concurrency diagnostic. `@preconcurrency import` silences the question
  rather than answering it; owning the objects and capturing only `self` answers
  it, and the invariant `@unchecked` stands for — everything touching the
  session happens on its queue — is the serialisation AVFoundation asks for
  anyway.
- **The scanner starts in `viewWillAppear`, not `viewDidLoad`.** SwiftUI
  recycles the rows a representable lives in; started once, a detached and
  re-attached preview comes back permanently black, and the view above has no
  state for "camera stopped" — it would show a viewfinder that can never fire.
- **An app's files go under Application Support, never `~/.bleat`.** On iOS
  `NSHomeDirectory()` is the app container's **read-only root** — only
  `Documents/`, `Library/` and `tmp/` inside it can be written — so a
  home-relative dot-directory cannot be created at all. Found on device, at the
  worst possible moment: the pairing had installed the key, proven it with a
  second handshake and deleted the enrollment key, and then failed to write the
  record with `NSCocoaErrorDomain 513`, leaving a key on the host the phone had
  no memory of. `PeerRegistry.applicationSupport()` is correct on both
  platforms with no branch; `standard()` stays `~/.bleat` for the console tool,
  as do `HostRegistry` and `KnownHostsStore`, and all three now say so.
  The directory is **excluded from backup**: the device key is `ThisDeviceOnly`
  and does not restore to a new phone, so a peer list that did would name hosts
  this device can no longer authenticate to.
- **`PeerStore.deviceKey()` throws instead of writing the shared `failure`.**
  Sharing one error property meant opening the key sheet cleared an
  unreadable-peer-file banner, after which the list said "No hosts yet" —
  confidently wrong, and an invitation to pair again into the same broken file.
- **The result screen shows the host key fingerprint**, because `bleat pair`
  prints the same string above the QR. Matching them by eye is the one check no
  software in this flow can do for the user.
- **`TransportError` describes itself** now, in `BleatKit`. The console tool's
  private rendering could not be reached from the app, so a failed connection
  arrived at the user as `connectionFailed("…")`, enum case and all. The tool
  keeps only the advice it alone can give — which `known_hosts` line to delete
  after an intentional rekey; the phone has no such file.
- **The camera purpose string is `INFOPLIST_KEY_NSCameraUsageDescription`** on
  the app target, and there is still no `INFOPLIST_KEY_` for `CFBundleURLTypes`
  — the generated set covers a fixed list of keys and URL types is not on it.
- **`bleat://` is registered, and a real `Info.plist` does *not* fight
  `GENERATE_INFOPLIST_FILE`** (verified 7 Sept 2026). This file used to say it
  did, which is why the scheme was deferred; the two compose. Setting
  `INFOPLIST_FILE = Support/Info.plist` alongside `GENERATE_INFOPLIST_FILE = YES`
  merges the generated keys *into* that file — checked in the built product,
  where `CFBundleURLTypes` and `NSCameraUsageDescription` and the scene manifest
  are all present. So `Support/Info.plist` carries the one key that cannot be a
  build setting and nothing else (two, with `NSBonjourServices`), and it sits outside `App/` so the target's
  synchronized group does not also copy it in as a resource.
  - The scheme string is duplicated between that file and
    `PairingPayload.urlScheme`, which is what `bleat pair` puts in the QR. No
    test can read the app target's plist from the package, so the coupling is
    stated in both places and here.
  - **A registered scheme that leads nowhere is worse than none**, so the app
    acts on it: `PairingRouter` is at the root next to the unpair flow, because
    a link can arrive while the user is several screens deep inside a host —
    where `PeersView` is not being evaluated and an `onOpenURL` on it would
    never fire. A link arriving while the sheet is already up is **refused, not
    queued**: a pairing in flight holds a single-use enrollment key it is part
    way through redeeming.
  - Verified end to end on the simulator: `simctl openurl bleat://pair?d=…`
    launched the app, raised the sheet, redeemed the code without a second tap,
    and reported the decode failure for the deliberately bogus payload. Note
    iOS shows an "Open in Bleat?" confirmation when the app is *not* frontmost
    and none when it is.
