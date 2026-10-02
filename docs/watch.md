# The watch app

Started 1 Oct 2026, ahead of the phase plan, because it was asked for. It is
the same screens as the phone — hosts, a host's sessions, a session's
workspaces, a workspace's agents — over a different transport.

## The watch cannot connect to anything, so the phone does it

**watchOS gives an ordinary app no direct connection.** Apple's TN3135,
"Low-level networking on watchOS" (read 1 Oct 2026):

> watchOS allows all apps to use high-level networking equally. However, it
> only allows an app to use low-level networking under specific circumstances

— streaming audio, a CallKit call, or a tvOS companion — and outside them:

> if a normal app attempts to start an `NWConnection`, that connection will
> stay in the `waiting(_:)` state with an error of `ENETDOWN`. […] The BSD
> sockets API doesn't work for networking on watchOS under any circumstances.

SSH is nothing but a direct connection, so the watch cannot reach a host. It
is also the device with no camera to pair with and no VPN to reach a host over.
The phone has all three, so **the watch asks the phone, and the phone runs the
command over its own SSH connection.**

- **The simulator does not show this.** The same technote: "the simulator
  always allows low-level networking". A watch app that dialled SSH itself
  would work on every simulator and on no watch.
- **`BleatKit` does build for watchOS, SSH and all** (Citadel, NIO, swift-crypto;
  `arm64` and `arm64_32`, release). It is linked and never called. The release
  watch app is 34 MB with it in; splitting the SSH half out of `BleatKit` would
  shrink it and has not been done.

## Where the cut is: the transport

`RelayRequest` is `HerdrTransport` and `ShellRunner` written down as data:

| request | what the phone does |
|---|---|
| `.peers` | replies with its paired hosts |
| `.herdr(hostKey, args, session)` | runs `herdr <args>` in that session, replies with stdout |
| `.shell(hostKey, command)` | runs the shell command — the host status probe |
| `.release(hostKey)` | closes the connection it opened for the watch |
| `.note(hostKey, PeerNote)` | records something the watch did on the host's record |

`RelayTransport` (in `BleatKit/Relay/`) is the second `HerdrTransport`: each
`run` is one request and one reply. Everything above it runs on the watch
unchanged — `HerdrClient`, `RemoteList`, `SessionControlModel`,
`HostLoadStore`, the transcript reader. `RelayResponder` is the phone's half:
bytes in, bytes out, with the connection supplied by closures so it is tested
without one.

- **The three error classes cross as themselves.** `HerdrError`, `ShellError`
  and `TransportError` are `Codable` and travel inside `RelayFailure`. A screen
  decides what to say, whether to drop the connection and whether a write may
  have happened from which one it caught; flattened to a sentence, herdr
  refusing a command would look like a dead network. Seen on the simulator:
  `herdr agent get w1:p1 failed (1): agent target w1:p1 not found`, on the
  watch, word for word.
- **The session travels with each command.** `HERDR_SESSION` is a prefix on
  the command and `useSession` is shared state on one transport. The phone
  answers with `PeerLink.run(_:inSession:)`, which names the session for that
  one command and leaves the selection alone.
- **There is no pane stream**, and so no terminal. A message is one request
  and one reply; a terminal is a channel held open both ways.
  `RelayTransport.openStream` throws. An agent's row still opens, because its
  conversation is a file read with one command: the pane screen on the watch
  is the chat alone, with no mode picker. A terminal's row is not a link.

## `ConnectionStore` on the watch

`ConnectionStore(peers:reachability:relay:)` takes the channel. With one, it
builds a `RelayTransport` where it would have raced the peer's addresses, and:

- needs no device key — the watch has none;
- records no winning endpoint and runs no endpoint refresh — the phone does
  both on its own connection;
- still numbers its connections, so a load reading is tied to one as on the
  phone, and still drops one on a `TransportError`.

"Connecting" costs nothing and cannot fail; the first command is what finds
out whether the phone and the host are there. `AppContext.isRelayed` is what a
view reads to leave out what the watch cannot do.

## The phone's side: `WatchRelayHost`

Started from `BleatApp.init`, not from a view: the system launches the app in
the background to deliver a watch's message, and no view appears then.
Verified on the simulators — with the phone app terminated, opening a host on
the watch launched it and the sessions arrived.

- **Its own `ConnectionStore`.** The app's holds one connection and closes it
  to open another, so a watch asking about one Mac would close the pane open
  to a different one on the phone.
- **Nothing is left open for a watch that has gone.** The watch sends
  `.release` when it leaves a host or goes to the background. A watch that
  walks out of range cannot, so the phone also closes the connection 15
  seconds after the last relayed command finishes.
- **Background time is held per command, and again for that wait — not as one
  span.** Without a hold the app is suspended the moment a reply is sent, with
  the session still up. The first version held one task from the first command
  to the end of the wait; under a watch that keeps asking it never ended, and
  its expiry closed the connection under a command in flight (caught in
  review, not observed). Not exercised on a device either way: it only matters
  with the phone locked or in the background.
- **The phone runs what the watch app sends, shell included.**
  WatchConnectivity connects an app only to its own counterpart, signed by the
  same team, so this is the app talking to itself — but it does mean the watch
  app has the phone's reach into every paired host.

## The hosts are the phone's; the watch has a copy

The watch pairs with nothing. The phone sends `[PairedPeer]` as the session's
application context whenever its list changes, and the watch asks for it with
`.peers` when it opens (which also wakes the phone). `PeerStore.mirror`
replaces the watch's file with what arrived.

**So anything recorded only on the watch is erased by the next copy.** What
the watch learns about a host — that it started or created a session, what the
host said it is — is written locally *and* sent to the phone as a `PeerNote`
(`PeerStore.upstream`). It goes as a message while the phone is reachable and
as a queued `transferUserInfo` when it is not, or when the message fails.

- **The message's handlers are passed from a `nonisolated` function, or the
  watch app dies.** WatchConnectivity calls a reply or error handler on its own
  queue. A closure written inside main-actor code is main-actor code, and
  Swift 6 checks that on entry, so handlers passed from the `upstream` closure
  trapped in `dispatch_assert_queue` when the phone answered. It reached the
  simulator — opening a host records what the host is, and the app crashed —
  and went unnoticed because the next screenshot was of a relaunch. Look in
  `~/Library/Logs/DiagnosticReports` after a simulator run, not only at the
  picture.
- **`mirror` compares against the file, not the loaded list**, which is empty
  until a screen has read it. The phone's copy can arrive first, and an empty
  one — the last host unpaired — would otherwise look like no change.
- The first version only queued, and on the simulator the note never arrived:
  a host opened on the watch showed its system and its mark until the next
  launch, when the phone's copy came back without them. `transferUserInfo`
  between simulators is not something to rely on; whether it delivers between
  real devices has not been checked here.

## What is on the watch, and what is not

Verified 1 Oct 2026 on paired simulators (iPhone 17, Apple Watch Ultra 4,
watchOS 27.0) against a scratch sshd and a scratch herdr session on this Mac:

- the host list, with the host's mark and system;
- a host's sessions, a session's workspaces, a workspace's agents and
  terminals;
- the load bar on all three, in a compact form — one number per icon, no
  amounts;
- herdr's own error text on a failed command.

Compiled and reachable, **not exercised** — nothing can tap a simulator from
the command line:

- stopping, starting and deleting a session from a swipe on its row;
- an agent's conversation.

Not on the watch:

- pairing, unpairing, the device key, a host's settings and addresses — these
  belong to the device that holds the key;
- the terminal;
- creating a session, a workspace or an agent. The forms are iOS-only files
  and each needs text entry designed for a watch.

**Not verified on a real watch at all.** The reply size limit is the open
question there: a message has a limit the system does not publish, and an
agent's conversation is the large reply. Replies are deflated before they
cross (`WatchWire.pack`), which is headroom rather than proof.

## Building and running it

One more target, `BleatWatch`, embedded in the iOS app (`Embed Watch
Content`). Its sources are `Watch/`; it shares `App/`'s icon and asset
catalog through the synchronized group, with `BleatApp.swift` excepted. The
icon needed nothing: `icon.json` already declared `"circles": ["watchOS"]`.

- Bundle id `team.partof.bleat.watchkitapp`, companion `team.partof.bleat`,
  watchOS 26.0.
- `BleatUI` builds for watchOS with SwiftTerm left out of the link
  (`condition: .when(platforms: [.iOS, .macOS])`) and the UIKit-only files
  guarded by `canImport(UIKit) && !os(watchOS)` — watchOS has a UIKit, and it
  is not that one.

```sh
# both apps, for a paired pair of simulators
xcodebuild -project Bleat.xcodeproj -scheme Bleat -configuration Debug \
  -destination 'platform=iOS Simulator,id=<phone>' -derivedDataPath <scratch> build
xcrun simctl install <phone> <scratch>/Build/Products/Debug-iphonesimulator/Bleat.app
xcrun simctl install <watch> <scratch>/Build/Products/Debug-watchsimulator/BleatWatch.app

# the watch app for a real watch, both architectures, without signing
xcodebuild -project Bleat.xcodeproj -scheme BleatWatch -configuration Release \
  -destination 'generic/platform=watchOS' -derivedDataPath <scratch> CODE_SIGNING_ALLOWED=NO build
```

### Driving a simulator nobody can tap

`simctl` launches and photographs; it cannot press anything, and a `bleat://`
link handed to `simctl openurl` stops at the system's "Open in Bleat?" alert.
`DebugLaunch` (debug builds only) walks the app from its launch environment:

```sh
SIMCTL_CHILD_BLEAT_PAIR_CODE='bleat://pair?d=…' xcrun simctl launch <phone> team.partof.bleat
SIMCTL_CHILD_BLEAT_OPEN='bleat-test/w1/host' xcrun simctl launch <watch> team.partof.bleat.watchkitapp
```

`BLEAT_OPEN` opens the first host, then a session, a workspace id, that
workspace's title, and a pane target, as far as it is given; empty stops at the
host's sessions.

For a host to pair with, the scratch sshd in `CLAUDE.md` works, with three
things that cost time here:

- **`bleat pair --port <port>`**, or the QR carries the *system* sshd's host
  key and every connection is refused as a mismatch.
- **A short `HOME`.** herdr's socket path must fit `sun_path` (104 bytes); a
  scratch directory deep under `/private/tmp/…` does not. A symlink from
  `/tmp/<short>` does.
- **Clear `HERDR_*` when starting the scratch session from inside herdr**, and
  give `script` a size (`stty rows 40 cols 120`), or it refuses as nested or as
  a zero-sized terminal. Every socket command from such a shell otherwise goes
  to the session the shell is in.
