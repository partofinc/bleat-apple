# Bleat — native iOS remote for Herdr

Bleat is a thin native client for [Herdr](https://herdr.dev) sessions. It shows
workspaces and agents sorted by attention state, renders live panes, and lets the
user answer approvals, send prompts, and type into a pane from a phone. Herdr and
the agents always run on the host; Bleat never owns a process. App Store name:
"Bleat for Herdr".

The product promise is **zero host setup beyond Herdr itself**. Transport v1 is
plain SSH: the app runs `herdr` CLI commands over exec channels and speaks
Herdr's own JSON. No daemon, no relay, no plugin on the host.

## Current phase: 2 — one gate item left, and it needs Tailscale installed

**Pairing verified on device, 5 Sept 2026.** `bleat pair` on the Mac, scanned
with an iPhone: the host key pinned out of band matched
(`SHA256:5kgLcSfLx2/OaEHRcfc7PhrQ2uLNlTc8aL19AfjYn78`, the same one this file
records), `herdr` resolved to `/opt/homebrew/bin/herdr` through a login shell on
first connect, three endpoints were classified and raced, and the swap completed
— device key installed, proved by a second handshake, enrollment key deleted.
The host printed `Paired.`

**Screens verified on device, 6 Sept 2026.** Hosts → session → workspaces →
agents → pane, all live against the `work` session. The pane renders at the
pane's own grid and pans, so nothing is cropped — the sizing problem that held
this gate open is settled; see **`--cols` crops** below. Unpairing revokes the
device key from the host, and `bleat keys` can see and remove one from the Mac
side.

**What is left of the Phase 2 gate is "runs on a real phone over Tailscale",
and it has never been tried.** Tailscale is not installed on the dev Mac, so
`bleat pair`'s Tailscale endpoint detection (`tailscale status --json` →
`Self.DNSName`, `Self.TailscaleIPs`) is written and unverified. Everything so
far has been on the LAN. Do not call the gate met on the strength of the
screens alone.

The Phase 1 gate is met over real SSH: connect, list sessions/workspaces/agents,
attach to a pane, see live frames, send input, resize, detach cleanly. Verified
against a loopback sshd on 127.0.0.1:2222. **Remote Login is now on** (verified
4 Sept 2026: port 22 answers `SSH-2.0-OpenSSH_10.3`, and mDNSResponder advertises
`_ssh._tcp` as `rawillkair.local:22`), so the throwaway-sshd dance is no longer
required to exercise the SSH path — it remains the fallback on a Mac where
Remote Login is off, since enabling it is a system change needing root.

Read the phase gates before proposing work outside them.

| Phase | Deliverable | Gate to next phase |
|---|---|---|
| **1 — Pipe** ✅ | Platform-agnostic Swift package `BleatKit` + macOS console tool `bleat` | From a Mac terminal: connect over SSH, list sessions/workspaces/agents, attach to a pane, see live frames, send input, resize, detach cleanly. No UI code. |
| **2 — Read-only app** | Xcode project, SwiftUI iOS app | Hosts → session → workspaces → agents (blocked on top) → live pane view (SwiftTerm). No input yet. Runs on a real phone over Tailscale. |
| **3 — Control** | Input + release | Keyboard with accessory row (Esc, Ctrl, Tab, arrows, y/n), prompt composer via `agent prompt`, takeover indicator, reconnect on foreground. TestFlight, then App Store. |

Out of scope until after Phase 3: pairing/relay transport (iroh or WebRTC),
push notifications, watchOS, Live Activities, multi-account badges.

### Must ship before any release

- **The host side is done: `bleat keys list` / `bleat keys revoke <marker>`.**
  Verified 5 Sept 2026 against a scratch `HOME`, including the fingerprints
  matching `ssh-keygen -lf` exactly — that equality is the whole point, since
  comparing the two by eye is how a user identifies which phone a key belongs
  to. See **`bleat keys`** below.
- **The phone's side is done too.** Unpairing revokes over the connection it
  still has and drops the record only once the key is gone; when it cannot, it
  shows the command that finishes the job before offering to forget the record
  that names it. See **Unpairing** below. Verified end to end against a
  throwaway sshd on 5 Sept 2026, including that the revoked key stops
  authenticating.

## Creating panes and sessions from the phone (Phase 3 note, herdr 0.8.2, 5 Sept 2026)

Read off the live CLI, so this does not have to be rediscovered when Phase 3
starts. **None of it is built**; it is what is available if we decide to.

**Panes, workspaces and tabs can be created, and a plain shell is the default.**

```
herdr workspace create --cwd PATH --label TEXT [--env K=V] [--focus]
herdr pane split [PANE] --direction right|down --cwd PATH [--env K=V]
herdr tab create
```

None of them takes a `--command`, so what launches is the user's shell. Herdr
calls a pane an *agent* only when its detection manifests recognise one, and
`herdr agent start` ("start a supported interactive agent in an existing pane")
is a separate, explicit step. So "new pane, plain terminal, no agent" is not a
mode — it is the default, and an agent is opt-in afterwards. Mechanically this
costs nothing new: they are ordinary `herdr` commands over the exec channel the
transport already opens.

**There is no `session create`.** `herdr session` offers only `list`, `attach`,
`stop`, `delete`. A named session comes from `herdr --session <name>`, which is
the TUI launcher and wants a pty — Citadel has `withPTY`/`withTTY` on the
platforms Bleat targets, but a session started that way would have to survive
the channel closing, and that is unverified. A probe from this Mac was
inconclusive for an unrelated reason worth knowing: `herdr --session x` refuses
with **"nested herdr is disabled by default"** when run from inside a herdr
pane. Over SSH from a phone that guard would not apply — the login shell has no
herdr environment — but the pty question stays open.

**The gap that matters: the phone cannot start a session from cold.** Every
creation command above goes over the socket API, and a client command will not
autostart a server — it returns `server_not_running`. So Bleat can add to a
session that is already running and cannot revive one that is not. If the Mac
reboots with nothing up, the phone is locked out until someone touches the
keyboard. Closing that needs either a detached launch that outlives the channel
or a login item on the host, and it is a different problem from creating panes.

**It is not a new privilege, but it is a new affordance.** The device key
already grants a full shell, so nothing here widens what a paired phone *could*
do. It does change what Bleat *is* — from a remote for what is running to
something that creates state on someone's Mac — so it belongs behind a
deliberate gesture that shows the workspace label and cwd before it acts, not
behind a `+` in a toolbar.

## Repository layout

House layout, matching the other projects in `~/Developer`: code lives in a
local Swift package, the `.xcodeproj` holds only targets, and the app target is
a thin shell.

```
Bleat.xcodeproj             # one app target; sources join via a synchronized group
App/                        # @main App struct and little else
BleatKit/                   # the local Swift package
  Package.swift
  Sources/
    BleatKit/               # domain + transport. No SwiftUI. Builds for iOS.
      Transport/            # HerdrTransport protocol + SSHTransport (Citadel)
      Protocol/             # NDJSON codec, frame/command types
      Model/                # Codable models for herdr JSON (from schema.json)
      Client/               # HerdrClient: typed API over a transport
      Keys/                 # device ed25519 key + Keychain storage
    BleatUI/                # SwiftUI shared between app targets; MainActor by default
      Context/              # AppContext, routers, stores
      Pairing/              # the pairing sheet, scanner and its model
      Sessions/             # the sessions on a host
      Workspaces/           # workspaces in a session
      Agents/               # agents in a workspace, blocked first
      Views/                # screens
      Previews/             # #if DEBUG sample data for #Preview only
    BleatProcess/           # macOS-only: LocalProcessTransport, spawns `herdr`
    bleat/                  # executable target, macOS console tool
  Tests/BleatKitTests/      # unit tests: codec, models, fake transport
  Fixtures/
    schema.json             # output of `herdr api schema --json` (source of truth)
    *.json                  # captured CLI outputs for decoding tests
ci_scripts/ci_post_clone.sh # macro fingerprint defaults + `swift test` gate
```

**`BleatProcess` exists because `Foundation.Process` does not on iOS.** The rule
against `#if` branches in `BleatKit` is what forces the split rather than a
platform guard: anything that cannot compile for both platforms gets its own
target, and the iOS app simply does not link it. Verify with
`cd BleatKit && xcodebuild -scheme BleatKit -destination 'generic/platform=iOS' build`
(the package is no longer at the repo root, so this fails from there). Use
`-scheme bleat-Package` to compile every target at once, which is the check
that actually catches a target the app would break on.

**Linux is a planned host platform for the console tool.** The `#if os(macOS)`
guards on `bleat` and `BleatProcess` exist to keep them off *iOS*, not because
they need macOS; `#if !os(iOS)` is what opens Linux. Exactly two leaves are
Apple-only and both carry an empty `#else` guard so the shape is already in
place: `bleat/Attach.swift` (`import Darwin` for SIGWINCH/termios, needs
`Glibc`) and `Keys/KeychainKeyStore.swift` (`import Security`, referenced only
by `BleatUI` and never by the tool). `HostRegistry` and `KnownHostsStore`
already persist to `~/.bleat/`, so the file-based storage a Linux host needs is
written. QR generation is the open item: `CIQRCodeGenerator` is free on Apple
platforms and has no Linux equivalent.

**`BleatKit` stays free of SwiftUI**; shared views live in `BleatUI`. (Phase 1's
note said "outside this package" — that predates the package having more than
one target. The intent was never to contaminate the transport layer, which a
separate target satisfies.)

## Architecture rules

- **Transport is an interface.** Everything above it must not know it is SSH.
  ```swift
  protocol HerdrTransport: Sendable {
      func run(_ args: [String]) async throws -> Data                   // one-shot herdr command
      func openStream(_ args: [String]) async throws -> HerdrStream     // long-lived NDJSON channel
  }
  ```
  `HerdrStream` exposes `AsyncThrowingStream<Data, Error>` for stdout lines and
  `send(Data)` for stdin. Phase 4 adds a second transport without touching callers.
- **Herdr JSON is the contract.** Models are generated/derived from
  `BleatKit/Fixtures/schema.json`. Do not hand-invent fields; if a field is missing,
  re-capture the fixture and update the model. Unknown keys are ignored, never
  fatal.
- **The pane stream is bytes, not text.** `terminal.frame` records carry base64
  ANSI. Decode to `Data` and hand it to the renderer untouched. Never strip or
  interpret escape sequences in BleatKit.
- **One writable controller.** Herdr allows one input owner per pane. Attach
  with `--takeover` only when the user asks; surface who currently holds control.
- **Reconnect is normal.** iOS will drop the socket. `HerdrClient` must be
  reusable after a transport failure; `terminal session control` replays the
  current rendered screen on attach, so re-attach is the recovery path.
- **Multiple channels, one connection.** List polling and the pane stream run on
  separate exec channels over a single SSH connection.

## Herdr facts (verified live against herdr 0.8.2, 4 Sept 2026)

Captured from a running server on the dev Mac (session `work`). Fixtures in
`Fixtures/` are the raw output of each command below.

- Herdr server persists in the background; clients attach/detach freely.
- **Two command families with different conventions.** Do not assume one flag
  style covers both:
  - *Socket-API* commands (`workspace list`, `agent list`, `pane list`,
    `api snapshot`, `api schema`) print JSON **by default** and **reject
    `--json`** (`usage: herdr workspace list`). They wrap the payload in an
    envelope: `{"id": "cli:agent:list", "result": {…}}`.
  - *Client-side* commands (`session list`) print a **human table** by default,
    need an explicit `--json`, and return **no envelope** (`{"sessions": […]}`).
- **There is no `--session` flag on API subcommands.** `herdr --session X` is
  the TUI launcher; passing it before a subcommand yields
  `unknown command: workspace list`. Session selection is by **environment**:
  `HERDR_SESSION=<name>` and `HERDR_SOCKET_PATH=<path>`. Over SSH, Bleat must
  set those in the command environment. `session list --json` gives the
  `socket_path` for each session.
- Agent states seen live: `idle`, `working`, `unknown` (`blocked`, `done`
  documented but not yet captured). Unknown values must decode, never throw.
  Sort order in UI: blocked → working → idle → done → unknown.
- **`agent list` needs no join.** Each row carries `pane_id`, `workspace_id`,
  `tab_id`, `cwd`, `foreground_cwd`, `terminal_title`(`_stripped`), `revision`,
  `state_change_seq`, and `agent_session` — the latter holding the agent's own
  session UUID (this is what identifies the Claude account per pane).
  `pane list` is the same shape minus `state_change_seq`, plus `scroll`
  (`offset_from_bottom`, `max_offset_from_bottom`, `viewport_rows`).
- **Workspace ids are opaque.** Both short (`w2`, `wA`) and long
  (`w653998617a6031`) forms occur, and they are not contiguous. Never generate
  or assume a numbering; targets are `<workspace>:<pane>`, e.g. `w2:p1`.
- Pane stream: `herdr terminal session control <target> --cols N --rows M [--takeover]`
  - stdout: NDJSON. Verified `terminal.frame` record:
    `{"type":"terminal.frame","bytes":<base64 ANSI>,"encoding":"ansi",
      "full":true,"width":80,"height":24,"seq":1}`
  - **No separate cursor field.** Cursor position lives inside the ANSI
    payload, so frames must reach the renderer byte-for-byte.
  - The first frame has `full: true` and replays the current screen. On an
    **idle** pane nothing follows — a reader that waits for a second record
    blocks indefinitely. Treat the first frame as sufficient to render.
  - Payload really is raw ANSI, including synchronized-output markers
    (`ESC[?2026h`). Never strip or interpret it.
  - Read-only alternative: `herdr terminal session observe <target>`, same
    `--cols`/`--rows`. Cannot disturb the current input owner.
  - stdin accepts **exactly four** record types (verified on a scratch pane in
    an isolated session; the host names them itself when it rejects one):
    - `{"type":"terminal.input","text":"…"}` or `{"…","bytes":<base64>}`
    - `{"type":"terminal.resize","cols":N,"rows":M}` — both required
    - `{"type":"terminal.scroll","direction":"up"|"down","lines":N}` — both
      required; there is **no** `offset_from_bottom` field here
    - `{"type":"terminal.release"}`
  - **Bad input is ignored, not fatal.** An unknown variant or a missing field
    produces `herdr: terminal session control input ignored: …` on stderr and
    the stream stays alive. Drain stderr: it is the only explanation you get.
  - Attaching emits more than one frame; do not assume exactly one.
- **Errors go to stderr, not stdout, with a non-zero exit.** A failing command
  writes `{"id":…,"error":{"code","message"}}` to **stderr** and exits 1;
  stdout is empty. Parse `HerdrError` from stderr — never from stdout.
- **`api schema --json` does not cover the terminal stream.** It has exactly
  five schemas — `request`, `success_response`, `event`, `subscription_event`,
  `error_response` — describing the socket API only. The NDJSON stream protocol
  must be captured empirically into `Fixtures/`.
- `pane read` caps at ~1000 lines (undocumented). Don't build history views on it.
- Environment: use `HERDR_BIN_PATH`-style absolute paths when a login shell
  might not have `herdr` on PATH. Treat non-zero exit as an error with stderr
  attached.
- Useful for later: `herdr --remote <ssh-target>` exists natively, and
  `herdr --skill` prints the agent-facing usage doc.

When something contradicts this section, the live host wins. Re-verify and
update this file in the same commit.

## SSH transport (Phase 1 decisions)

- Library: **Citadel** (SwiftNIO SSH). Approved dependency. Do not add others
  without asking. Pulls in swift-nio, swift-crypto, swift-asn1, BigInt.
- **Citadel forces macOS 15 / iOS 18.** Every stdin-capable API (`withExec`,
  `withPTY`, `withTTY`) is `@available(macOS 15.0, *)`; only the read-only
  `executeCommandStream` works below that. The package platforms were raised
  to match.
- Auth: ed25519 key, parsed with `Curve25519.Signing.PrivateKey(sshEd25519:)`.
  Stored in Keychain (Phase 2) or a file under `~/.bleat/` for the console tool.
- Host key: trust-on-first-use, pinned per `host:port` in `~/.bleat/known_hosts`
  as the OpenSSH `algorithm base64` string. A changed key is a hard error and
  never overwrites the pin; an intentional rekey means deleting the line.
- **Session selection is a command prefix, not channel env.** Citadel can send
  env requests, but they need `PermitUserEnvironment` in sshd, which is off by
  default. sshd runs an exec command through the login shell, so
  `env -u HERDR_SOCKET_PATH HERDR_SESSION=x herdr …` works everywhere. Every
  argument is single-quoted.
- **`herdr` is usually not on the PATH of a non-login shell** — verified: an
  exec channel gets `env: herdr: No such file or directory`. Saved hosts carry
  an absolute `herdrPath`.
- **A clean detach looks like an error at the Citadel layer.** After
  `terminal.release` the remote exits and the channel is gone, so the scoped
  `withExec` teardown throws `Already closed`. `SSHStream` tracks whether
  stdout drained normally first and finishes cleanly when it did — without
  that, every detach reports a spurious failure.
- Citadel is not `Sendable`-audited, so `SSHClient` cannot live in an actor.
  `SSHTransport` is a lock-guarded `final class` and `UnsafeTransfer` is the
  single, documented escape hatch in the package.
- The console tool takes `user@host[:port]` plus `--key PATH`; nothing is read
  from `~/.ssh/config` in Phase 1. Bare IPv6 (`user@fe80::1`) is accepted;
  brackets are required to add a port (`user@[fe80::1]:2222`).

## Pairing and peer identity (stable rules — do not relitigate per PR)

Pairing is how a phone acquires a host. The Mac-side `bleat pair` does the hard
part — it already knows everything the phone needs — and the phone scans one QR.

### The key exchange: the durable private key never leaves the phone

**Never put a long-lived private key in the QR.** A QR on screen is captured by
anyone in the room, by any screen share, and by any recording; in a terminal it
lands in scrollback, which iTerm2 persists to disk by default and tmux keeps in
history, so the key outlives the pairing. An SSH private key is arbitrary
command execution on the host — it is the highest-value secret in the flow.

The QR carries a **single-use enrollment key** instead:

1. `bleat pair` mints a temporary ed25519 key and appends it to
   `~/.ssh/authorized_keys` with a marker comment identifying it as a Bleat
   enrollment key.
2. The QR encodes: endpoints, port, username, the **raw 32-byte seed** of the
   temporary key, and the **host key in OpenSSH `<algorithm> <base64>` form**.
3. The phone scans, connects with the temporary key, and pins the host key by
   comparing it to the one from the QR.
4. The phone's first action over that channel is to generate its **own** key in
   the Keychain, append that public key to `authorized_keys`, and delete the
   temporary line.
5. The tool confirms the swap and exits; on timeout or abort it removes the
   temporary line itself. The temporary key is never reused.

**Dropping the key when nobody redeems it needs three layers**, because no
in-process cleanup is complete (verified 4 Sept 2026, all four paths exercised
against a scratch `HOME`):

| how pairing ends | what removes the key |
|---|---|
| normal exit, or an error | `defer` |
| Ctrl-C, `SIGTERM`, `SIGHUP` | `DispatchSourceSignal`, exit 130 |
| `SIGKILL`, panic, power cut | **nothing can run** — see below |

The third row is why the line carries sshd options:
`restrict,expiry-time="<UTC>Z" <key> bleat-enroll-<id>`.

- `expiry-time` makes **sshd** refuse the key once the moment passes, which
  holds however the tool died. Verified against a real sshd: accepted before,
  `Permission denied` after. UTC with a `Z` suffix, since a local-time deadline
  would shift under DST.
- `restrict` drops forwarding, X11 and PTY. Exec channels still work, which is
  all pairing needs — also verified against a real sshd.
- The deadline gets a 60s grace beyond the tool's own window, so a phone that
  connects a second before the end is not expired mid-swap.
- Every `bleat pair` **sweeps** stale `bleat-enroll-*` lines first, since a
  previous run killed outright could not. The sweep requires the `-enroll-`
  infix and so cannot touch a paired device's key.

**Both sides take a `mkdir` lock** around every mutating command, because
removal is a read-modify-write while the phone concurrently appends — the lost
update drops the phone's key, so it reports success and can never connect.
Three details are load-bearing and each was found by testing, not by reading:

- **Staleness is the lock's age, never how long a caller has waited.** Breaking
  after N failed attempts looks equivalent and destroys mutual exclusion under
  contention, because every waiter eventually reaches N and tears the lock from
  a live holder. Measured with 200 concurrent appends against 200 removals: the
  attempt-count version kept 16 of 200 keys and lost the user's own; by age, all
  200 survive.
- **A failed `mkdir` means contention only if the lock exists.** Otherwise the
  directory is unwritable and retrying can never succeed — that spun forever on
  an `~/.ssh` at mode 500. It now fails immediately, naming the cause.
- **Locked commands must not call `exit`**, or the lock outlives them.

**Cleanup has no "already done" latch.** A signal arriving between installing
the handlers and installing the key finds nothing to remove, and a latch would
mark itself done — then the key is installed a moment later and never removed.
Observed: a cancel 0.6s in exited 130 while leaving the key behind. Removal is
idempotent, so it always runs.

**`exit()` does not run `defer`.** The cancel path therefore runs cleanup
explicitly, and `Cleanup.run()` holds its lock across the shell call so a second
caller waits rather than returning early into `exit`.

**Redemption means a *new* device key appeared**, not that any exists. A host
with a phone already paired has a device key from the start, so the weaker test
would turn any disappearance of the enrollment line into a false success.

Two properties this buys that trust-on-first-use does not: the durable key is
generated on the device and is never transmitted anywhere, and the host key is
pinned **out-of-band** rather than trusted on first sight. Exposure of the
enrollment key is bounded to the seconds between scan and swap, and it
self-destructs regardless of outcome.

Encode the raw 32-byte seed, not an OpenSSH PEM: ~150 bytes of payload instead
of ~600, which is a materially easier scan.

### A peer is a host key, not an address

**The peer's identity is its SSH host key.** The same machine presents the same
host key on every address it answers on — verified: reaching this Mac over
loopback, `.local` and its LAN address all yield
`SHA256:5kgLcSfLx2/OaEHRcfc7PhrQ2uLNlTc8aL19AfjYn78`.

So a paired peer is **one host key plus an ordered list of endpoints**, never a
single address. A machine reachable both on the LAN and over Tailscale is *one
peer with two endpoints*, not two peers.

- Re-pairing is idempotent: if the scanned host key matches an existing peer,
  merge the new endpoint into it. Never create a duplicate peer.
- A host key that changes for a known peer stays a **hard error**, as in Phase 1.
  It is the identity; a mismatch is not a new endpoint.
- `bleat pair` enumerates what it can and accepts `--endpoint` for the rest:
  - mDNS name (`scutil --get LocalHostName` + `.local`) — LAN only
  - routable interface addresses from `ifconfig` — LAN v4, global v6
  - Tailscale MagicDNS name and IPs, when the CLI is present
    (`tailscale status --json` → `Self.DNSName`, `Self.TailscaleIPs`).
    **Unverified — Tailscale is not installed on the dev Mac.** Confirm the JSON
    shape against a real install before relying on it.
  - Twingate and similar overlays do not tell the host its own resolvable name.
    Those endpoints are user-supplied via `--endpoint`; do not try to detect them.

### The QR carries the host key, not its fingerprint

`KnownHostsStore` pins the OpenSSH `<algorithm> <base64>` string —
`PinningHostKeyValidator` builds exactly that via `String(openSSHPublicKey:)`
— so that is the form the QR must carry. A `SHA256:` fingerprint can only be
*displayed*, never compared against a pin, and shipping one would have made
every paired connection fail its pin check. It costs about 30 bytes in the QR.
Show the fingerprint derived from it; never store one as the identity.

### Which host key the QR names (verified 4 Sept 2026)

NIOSSH offers exactly `ssh-ed25519`, `ecdsa-sha2-nistp384`,
`ecdsa-sha2-nistp256`, `ecdsa-sha2-nistp521`, in that order, and **the
client's order wins** — `SSHKeyExchangeStateMachine` walks its own list and
takes the first the server also offers. So on any host with an ed25519 host
key, which is every modern OpenSSH, that is the key the phone sees, and its
fingerprint is what belongs in the QR.

Two consequences:

- **NIOSSH does not speak `ssh-rsa` at all.** An RSA-only host cannot be
  paired, and `bleat pair` should say so at the keyboard rather than hand out
  a QR that fails on the phone.
- A host commonly has four host keys (this Mac has dsa, ecdsa, ed25519, rsa).
  Reading the wrong one yields a key that matches nothing, which surfaces as a
  host key mismatch on every attempt.

**Read the key from the running sshd, not from `/etc/ssh`.** `ssh-keyscan -p
<port>` is ground truth; the files on disk are only the *system* sshd's keys.
A host serving SSH on another port — including the throwaway `/usr/sbin/sshd`
this file's own test procedure runs on 2222 — presents a different key
entirely. Verified: with a throwaway sshd on 2222, `bleat inspect --port 2222`
reports `SHA256:DxXu3g15…` while port 22 reports `SHA256:5kgLcSfL…`. Reading
the file would have pinned the wrong one and made the phone reject every
connection. The files remain a fallback for when nothing answers on the port.

### Which local addresses are offered

Only two of this Mac's ~30 addresses are usable endpoints. The filter drops
loopback and AWDL (`lo0`, `awdl0`, `llw0`), interfaces that are not `UP` **and**
`RUNNING` (a down port still prints its last address), host-only virtual
interfaces (`bridge*`, `vmnet*`, `vnic*`, `vboxnet*` — Parallels, VMware and UTM
addresses pass every other filter, and if the phone's LAN overlaps that range it
reaches an unrelated device and fails *host key verification* rather than merely
failing to connect), link-local (`fe80::/10`, `169.254.`), `deprecated`
addresses, and — the one that would otherwise bite — **`temporary` addresses**. Those are RFC 4941 privacy addresses and rotate by design, so
pinning one gives a peer that works today and fails tomorrow with nothing to
show why. Only the stable `secured` address is kept.

`bleat inspect` prints the whole list with each endpoint's reach, which is the
first thing to run when pairing misbehaves.

### Displaying the QR

`CIQRCodeGenerator` on macOS; Linux is still deliberately undecided, and only
the generator would change — `QRMatrix` and its renderer are in `BleatKit` and
are already portable.

- **Draw on the alternate screen** (`\e[?1049h`), never the normal one. A QR on
  the normal screen stays in scrollback, which iTerm2 persists to disk and tmux
  keeps in history, so the enrollment key would outlive the pairing somewhere
  nobody thinks to clear. Restoring is part of `Cleanup`, not a `defer`, because
  `exit` skips defers and the cancel path exits — a cancelled pairing that left
  the alternate screen up would hide the user's shell until they typed `reset`.
- **Half-blocks, two module rows per line.** Terminal cells are about twice as
  tall as wide, so one module per cell doubles the height and many scanners
  refuse it.
- **Set black-on-white explicitly.** The block glyphs carry the *foreground*
  colour as ink, so an unstyled render is inverted on a dark theme.
- **`CIQRCodeGenerator` gives a 1-module quiet zone** and the spec wants 4, so
  three more are added.
- **Read the bitmap rows straight through — do not reverse them.** A
  `CGBitmapContext`'s *coordinate* origin is bottom-left, but its backing buffer
  is stored top row first, so `pixels[0..<size]` is already the top scanline.
  Reasoning from the coordinate origin and reversing mirrors the symbol
  vertically: finder patterns land top-left, bottom-left and bottom-right
  instead of top-left, top-right and bottom-left. **This shipped once.**
- **Decodability is not an orientation test.** `CIDetector` reads a mirrored
  symbol without complaint, which is why a decode round-trip missed the bug
  above; zbar, ZXing and many Android scanners do not. Assert finder positions —
  `QRMatrix.hasCanonicalFinderPatterns(quietZone:)`, covered in
  `BleatProcessTests` — and treat a decode as a separate, weaker check.
- **Not a TTY means no QR**: a pipe or a redirect gets the link only.

**Size, measured with a real payload (5 Sept 2026).** An earlier note quoted
versions measured with a string of `A`s — that is *alphanumeric* mode at 5.5
bits per character, while a `bleat://` URL is lowercase and punctuated and so
encodes in *byte* mode at 8 bits, about 12 modules larger for the same length.
**The payload is a compact binary form, not JSON** (`PairingWire`). JSON keys,
quotes and braces were about forty characters of pure structure, and base64 then
inflated the whole thing by a third — in a medium where every byte is modules
and modules are terminal rows the user may not have. Both ends ship together, so
there is nothing to negotiate and no reason to pay for self-description. Layout
and the reasoning are in `PairingWire`.

Alongside it, three redundancies went:

- The host key travels as its **bare 32 bytes** for ed25519, which is what the
  phone negotiates. The text form named the algorithm and the wire blob repeats
  it again in 19 bytes of framing; `SSHPublicKeyLine.ed25519(rawKey:)` rebuilds
  the exact OpenSSH string the pin compares against. Other algorithms travel as
  a blob, told apart on the way in by length.
- Endpoints **omit port 22**, which `Endpoint(string:)` defaults to.
- Correction level is **L**. The higher levels buy recovery from print wear,
  dirt and creases; this code is drawn pixel-exact, scanned from a foot away and
  gone in minutes.

**`herdrPath` is deliberately not in the QR; the client resolves it.** A baked
path costs 24 bytes and goes stale the moment herdr moves, so discovering it is
both smaller and more robust. `Enrollment` asks `HerdrLookup.command`
(`${SHELL:-/bin/sh} -lc 'command -v herdr'`) on the enrollment connection and
stores the answer on the `PairedPeer` — **before** anything is written, so a
host without herdr is refused with nothing to undo. `PairedPeer.herdrPath` stays
optional because a record can predate that. Reading the answer is
`HerdrLookup.path(inOutput:)` and both ends use it: a login shell sources the
profile, profiles print banners, and taking the whole of stdout stores
`"Welcome back!\n/opt/homebrew/bin/herdr"` as the path.

Measured across these changes on the three-endpoint case: the URL went
**411 → 383 → 350 → 221** characters and the rendered code **85 → 77 → 73 → 61**
columns, 43 → 31 rows.

**Height is the binding constraint, so nothing is spent on it carelessly.**
Chrome is three rows — title, host key, footer — with no blank spacers: the QR's
own quiet zone already separates it from the text, and on a 141×47 window the
two blanks that used to be there were the whole difference between a code and a
fallback. The last line carries no trailing newline, which would scroll the
alternate screen and push the title off when the content exactly fills it.

**The quiet zone adapts rather than giving up.** Four modules is tried first,
then two, and only then does it fall back to the link. Two still scans, and
losing the QR entirely over one row is the worse outcome. Measured on a
141-column window: 47 rows renders at the full margin, 41 at the reduced one, 39
falls back. The shortfall is reported against the **smallest** option tried, so
it names the real gap rather than the gap to the margin we would have preferred.

**Light modules are grey (`0x8C`), not white.** A white panel this size glares
in a dark terminal, and the contrast a decoder needs — roughly 3:1 — leaves
room: black on `0x8C` measures **6.3:1**, against 21:1 for white. That is still
twice the floor, but close enough to it that going darker should be measured
rather than guessed. Only the light modules move; dimming the dark ones would
spend the same margin while making the ink itself less distinct.

Verified end to end: the glyphs written to a pty were parsed back into modules
and decoded with `CIDetector`, returning the exact `bleat://pair?d=…` URL. That
proves the *payload* survives the render; it says nothing about orientation, for
which see the finder-pattern note above.

### The phone's side of the swap (verified end to end, 5 Sept 2026)

`PairingClient` is the whole of it, and `bleat redeem <url>` runs the same code
path from a terminal so it can be exercised against a real `bleat pair` without
a phone. The order is fixed and each step exists because of a way the previous
one lies:

1. **Resolve `herdr` first**, while nothing has been written. A host that cannot
   serve the app is refused with nothing to undo.
2. **Replace this device's line in one command.** Re-pairing a known phone must
   not add a second copy of the same key under a second marker — and must not
   have a moment where the key is *absent* either. A removal followed by an
   append has that moment, and for an already-paired phone it holds its only
   durable credential; if the append then failed quietly the phone would have
   destroyed the access it arrived with. `replaceKeyCommand` does the whole
   edit in a temporary file and lands it with one write.
3. **Verify the line is there.** An append that succeeded loudly and did nothing
   — `StrictModes`, a full disk, an unwritable `~/.ssh` — reads back as absent.
4. **Open a second connection authenticated with the device key.** This is the
   step that matters, and the one a file check cannot substitute for: a line in
   `authorized_keys` is not the claim "sshd will accept this key". Found live —
   an sshd whose `AuthorizedKeysFile` pointed somewhere other than the session's
   own `~` passed every file check and reported a pairing that could never have
   worked. One handshake buys certainty.
5. **Only then delete the enrollment key**, over the *device* session, and
   verify it is gone. `bleat pair` calls the pairing done when the enrollment
   line is gone **and** a new `bleat-device-` marker has appeared, so a removal
   that exited 0 without removing anything would hang the tool while the phone
   claimed success.

Every failure before step 5 leaves the enrollment key live, so the user scans
again rather than walking to the Mac.

**Absence must be a normal answer, not a failed command.**
`HerdrLookup.command` ends in `|| true`, because `command -v` exits 1 when it
finds nothing and the login shell exits with it. Without that, a host without
herdr produces a failed *command* over the exec channel and the user is told
`the host rejected a command (exit 1)` — the `herdrNotFound` guard downstream is
unreachable. Verified both ways against a real shell.

**The phone's verification reads take the `mkdir` lock; the host's poll does
not.** Every write-back here is `cat "$t" > "$f"`, which truncates before it
writes, so an unlocked read landing in that instant sees an empty file — and the
phone's read decides whether a pairing failed. The host polls ten times a second
and would contend continuously, and a wrong answer there only costs a tick.

**The phone deletes the enrollment line by key, not by marker.** The marker is
minted on the host and the QR does not carry it — a field existing only so the
other side can name a line would be paid for in modules on every pairing. The
key is already in the phone's hands. `AuthorizedKeys.keyPattern` matches the
base64 blob as a **whitespace-delimited field** (base64 is not self-delimiting)
and escapes ERE metacharacters — `+` is in base64's alphabet, and unescaped it
would turn the pattern into a wildcard that `grep -v` then deletes by.

**Two host key mechanisms, and the app uses the stronger one.**
`HostKeyPolicy.knownHosts` is trust-on-first-use in a file, keyed by
`host:port` — the console tool's, because it is handed a hostname and has
nothing else. `HostKeyPolicy.expect` compares against a key learned out of band,
from the QR and afterwards from the `PairedPeer`. It writes nothing, which
matters: a peer is identified by its host key while its *addresses* come and go,
and a recycled DHCP lease would otherwise leave a stale pin at
`192.168.1.50:22` that no legitimate pairing could get past. Verified live: with
the genuine sshd stopped and an impostor on another port answering with a
different key, redemption is refused.

**Endpoints are raced, not tried in order.** The first entry is usually a
`.local` name, and off the LAN that does not fail so much as sit there while the
working overlay address behind it never gets a turn.

**The race must return on the first win, and a task group cannot do that.**
Leaving a group's scope awaits every child, and `group.cancelAll()` cannot
shorten a losing attempt: `SSHClient.connect` does not observe task
cancellation, so a dead address still costs its full TCP timeout — which is the
very cost the race exists to avoid. `PeerConnector` therefore runs the group in
a **detached** task and hands the winner back through a continuation; the drain
keeps running, **closes** any connection that finishes late (`SSHClient` has no
deinit that does it, and an abandoned session stays open on the host), and ends
by itself. Measured: with a black-holed address in the list — one that swallows
SYNs for four seconds rather than refusing — pairing completes in **0.2s**.

**What is raced is the handshake, not a command.** `SSHTransport.connect()`
proves TCP, the host key, key exchange and authentication, which is everything
"this endpoint works" can mean. An earlier version ran `printf ok` and compared
stdout exactly — but `.zshenv` is sourced for every non-interactive zsh, so
anything a user's startup file prints would have made every healthy endpoint
fail, and the message blames the network.

A host key mismatch is promoted over every other failure when nothing wins — it
is the only outcome that is not about the network, and reporting it as "no
address answered" sends the user to check their Wi-Fi. Verified live: with the
genuine sshd stopped and an impostor answering on another port, redemption is
refused.

**A merge takes the endpoint that just worked.** `PairedPeer.merging` keeps the
older record's endpoints but takes the newer `lastGoodEndpoint`, for the same
reason it takes the newer `herdrPath`: the fresh record is the one that just
reached the machine. Keeping the stored value sends the next connection to the
network the phone has left. Seen live — a re-pairing reported the *previous*
winner as the address it had just reached.

**Saving the peer is the one fallible step after the point of no return.** By
then the enrollment key is gone from the host, so rescanning the same code
cannot work — `PeerRegistry.all()` tolerates a *missing* file but not an
undecodable one, and that failure would otherwise be reported as a generic
pairing error. `PairingError.peerNotRecorded` says the host half succeeded and
sends the user to run `bleat pair` again rather than back to a dead QR.

**`PeerRegistry` is keyed by host key**, so pairing the same Mac again from a
second network merges into the record that exists. `HostRegistry` is keyed by a
user-chosen name and cannot do that; it predates pairing and stays as the
console tool's own list.

### Connecting to a paired peer (Phase 2)

`PeerConnection.connect` is where the pairing record pays off: everything the
connection needs was learned once, out of band — which machine this is (the host
key), where it answers, who to log in as, and where `herdr` lives. Nothing
prompts, guesses, or trusts anything on first sight.

- **One live connection at a time**, held by `ConnectionStore`. A phone drills
  into a single host, and every screen in that drill-down wants the same SSH
  session rather than a handshake each. Returning to the peer list releases it —
  re-entering costs a handshake, an idle SSH session left open on someone's Mac
  costs their trust.
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
- **Reachability is one question**: is this Wi-Fi or Ethernet? On cellular a
  `.local` name and an RFC1918 address cannot resolve or route, so
  `endpointsToTry` drops them rather than ordering them last. `Reachability`
  lives in `BleatUI` rather than `BleatKit` — `Network` is Apple-only, and where
  the phone is standing is a question the UI layer is entitled to ask.
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

### The list screens (Phase 2)

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

### The pairing UI (Phase 2)

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
  the app target. There is no `INFOPLIST_KEY_` for `CFBundleURLTypes`, so
  registering `bleat://` as a URL scheme — which would let the system camera
  open the app straight from the QR — needs a real `Info.plist`, and that
  fights `GENERATE_INFOPLIST_FILE`. Deferred deliberately; in-app scanning does
  not depend on it.

### Unpairing (Phase 2)

Unpairing is two things, and the app used to do only the easy one. Dropping the
local record is bookkeeping; removing this device's key from the host is the
part that decides whether a phone can still open a shell on someone's Mac.

- **The record is dropped only once the key is gone.** Forgetting first would
  discard the `PairedPeer` — its endpoints, its host key, its device marker —
  which is everything needed both to reach the host and to name the line to
  delete. There would be nothing to retry with and nothing to name.
- **Revocation matches on the key, not the marker.** The phone always holds its
  key; a marker can be absent from a record made before it was stored, or stale
  if the file was edited. `PairedPeer.deviceMarker` exists for *telling the
  user* which line to remove — `Enrollment` always minted it and
  `PairingClient` used to throw it away.
- **The file is read on both sides of the removal, and *absent before* is a
  failure too.** `removeKeyCommand` ends in `|| true`, so it exits 0 whether or
  not it deleted anything — hence the read after. The read *before* is the
  subtler one, and it is the same failure `Enrollment` was built around: the
  handshake that opened this connection proves sshd accepts the key, so if it
  is not in `~/.ssh/authorized_keys` then sshd is reading a different
  `AuthorizedKeysFile` and nothing done to this file can revoke anything.
  Without that check the app removed nothing, reported success, deleted the
  `PairedPeer`, and left the phone a full shell on that Mac with no record
  naming the line. **A first version shipped without it and a test asserted the
  permissive behaviour** — the same shape as the `Agent.target` test that
  passed while the property was wrong.
- **The connection is released afterwards.** It authenticated with a key that
  is no longer in `authorized_keys` — sshd does not re-check a live session, so
  it keeps working, which is exactly why it must not stay cached.
- **Swiping a row asks; it does not unpair.** Unpairing is not list management,
  and a swipe has nowhere to say what it does.
- **"Forget without removing the key" is offered, third, and named for what it
  leaves behind.** The alternative is worse: a Mac that has been rebuilt or
  sold would otherwise be un-removable, and a list that will not let go of a
  dead entry teaches people to ignore it. It is reachable only from a screen
  that has already shown the command that finishes the job.
- **`RevocationAdvice` lives in `BleatKit`**, for the reason `Agent.displayTitle`
  does: it names a command surface (`bleat keys revoke <marker>`) defined there.
  A phone printing a syntax the tool no longer accepts would be worse than
  printing nothing — the user runs it, sees it fail, and has no reason to think
  the key is still there. It validates the marker with the same
  `Marker(text:)` the tool applies, and falls back to `bleat keys list` plus a
  fingerprint when there is none.
- **`bleat unpair <name>` runs the same path from a terminal**, for the reason
  `bleat redeem` does: taking access away has one failure worth catching —
  reporting success over a key that still works — and only a real host shows
  it.

#### "Reached and refused" is not "could not reach"

`SSHTransport.dial` mapped every failure to `connectionFailed`, so a **revoked
device key looked like a network problem** — on every screen, not just this
one. The user is told to check their Wi-Fi while the truth is that the phone is
no longer paired.

Citadel throws `SSHClientError.allAuthenticationOptionsFailed` for exactly this,
and an address that is not listening throws `NIOConnectionError` (verified live,
5 Sept 2026, by probing a stopped sshd and a revoked key). `dial` now raises
`TransportError.authenticationFailed` — worded to name the possibilities rather
than assert revocation, since sshd also refuses every method under
`MaxAuthTries`/`MaxStartups` throttling, a changed `AllowUsers`, a locked
account or a `StrictModes` permissions drift, several of which are transient
and all of which reach every screen through this one string. `PeerConnector`
promotes it when nothing wins — after `hostKeyMismatch`, since identity outranks credential, and
before "none of N addresses could be reached", since a host that refused us was
reached.

The unpair screen says something different for it, because the advice inverts:
the likeliest reading is that the key has **already** been removed there, so
"the key is still on that Mac" would be false and `bleat keys revoke` would
fail with "no Bleat key with that marker" — reading like a second problem. The
other reading is that the key is in the file and sshd is ignoring it, which is
what a `StrictModes` permissions drift does. Only looking tells them apart, so
the screen names both and offers `bleat keys list`.

### Endpoint selection on the phone

Try last-known-good first with a short timeout, then race the remaining
endpoints and keep whichever completes the SSH handshake first. Persist the
winner per peer.

**On cellular, skip `.local` and RFC1918 addresses entirely.** They cannot
resolve or route off-LAN, and attempting them only spends the timeout.
`NWPathMonitor` reports the interface type; that is the whole rule.

Whichever endpoint wins, the host key is still checked against the peer's pin.
The endpoint is a hint; the key is the identity.

## `bleat` console tool (Phase 1 acceptance)

```
bleat hosts add dev ravil@10.0.0.5 --key ~/.bleat/id_ed25519 \
      --herdr /opt/homebrew/bin/herdr --session work
bleat hosts list / hosts remove dev
bleat sessions   [host]                   # named sessions
bleat workspaces [host] [--session NAME]  # by attention state
bleat agents     [host] [--session NAME]  # agents, blocked first
bleat attach     [host] w1:p1 [--takeover] [--cols N] [--rows M]
bleat schema     [host] > BleatKit/Fixtures/schema.json
bleat keys list                           # what this machine still lets in
bleat keys revoke <marker>                # take a paired phone's access back
```

Omitting `[host]` uses `LocalProcessTransport`, which spawns `herdr` directly.
That is what makes the tool usable *on* the Herdr machine without a loopback SSH
hop, and it is how the stack is exercised in development. Naming a saved host
switches to `SSHTransport` behind the same `HerdrTransport` protocol — no caller
above the transport changed when SSH landed.

`attach` writing the ANSI bytes straight to a macOS terminal is the Phase 1
renderer. If it looks right there, SwiftTerm will render it in Phase 2. Ctrl-]
sends `terminal.release` and exits 0; SIGWINCH is forwarded as `terminal.resize`.

### `bleat pair` (Phase 2)

```
bleat pair [--endpoint HOST[:PORT]]...   # add endpoints detection cannot find
```

Checks that `herdr` is installed and resolvable, enumerates endpoints, mints the
single-use enrollment key, renders the QR in the terminal, and waits for the
phone to swap in its own key. See **Pairing and peer identity** for the rules
that govern it — they are settled, not per-PR decisions.

The QR must be rendered so it does not persist: draw it in the alternate screen
buffer and restore on exit, so it never enters scrollback. This matters even
with the enrollment key being single-use.

### `bleat redeem` and `bleat peers` (Phase 2)

```
bleat redeem <bleat://pair?d=...>   # the phone's side, run from a terminal
bleat unpair <name>                  # revoke this device's key, then forget
bleat peers                          # what pairing produced
```

The same `PairingClient` the app will call. It exists so the swap can be run
against a real `bleat pair` before there is an app, and it is the fastest way to
reproduce a pairing problem. Its device key lives in `~/.bleat/device_key` rather
than the Keychain — `KeychainKeyStore` is `ThisDeviceOnly` and prompts, which is
right on a phone and an obstacle in a terminal.

### `bleat keys` (Phase 2)

```
bleat keys list
bleat keys revoke <marker>...
```

The other half of pairing. A phone that unpairs drops its own record; it cannot
reach the host, and a phone that was lost or wiped cannot do anything at all.
So the host's `authorized_keys` is the only place that knows what may still log
in, and until this existed there was nothing that showed it or removed it.

- **Local only, and not by omission.** Every other command takes an optional
  `[host]` and reaches it over SSH. This one edits the file that decides who
  may reach the machine, and doing that down a channel the file itself
  authorises is a footgun: revoke the wrong line and the command that would fix
  it is the one that no longer connects.
- **A marker typed by a user is validated, never sanitised.**
  `Marker(kind:id:)` sanitises because it *mints* a marker; `Marker(text:)`
  refuses anything that is not already `bleat-(enroll|device)-[A-Za-z0-9._-]+`.
  Sanitising here would turn `bleat-device-ab/12` into `bleat-device-ab12` — a
  different, possibly existing key — and this string names the line `grep -v`
  deletes. Refusing a typo beats repairing it into someone else's key.
- **A revocation is checked before and after.** `removeCommand` exits 0 when it
  matches nothing, so the exit status cannot say whether anything happened.
  Revoking an absent marker is refused outright, and the file is read again
  afterwards — a confident "Revoked" over an unchanged file is the exact
  class of lie the rest of this design is built against.
- **An expired enrollment key is reported as harmless**, because it is: sshd
  already refuses it and the next `bleat pair` sweeps it. A listing that showed
  it the same way as a live device key would send the user chasing a key that
  cannot be used, and teach them to ignore the list.
- **A line whose marker parses but whose key does not is still listed.** A key
  that authenticates and does not appear in the list is the precise failure the
  command exists to prevent; only the fingerprint is lost, and the row says so.
- **The listing is one block per key, not one row.** Marker, fingerprint and
  note total about 130 columns on one line. The fingerprint gets its own line
  because comparing it against what the phone shows is the one check no
  software in this flow can do for the user — and it is byte-identical to
  `ssh-keygen -lf`, verified.
- Reads take the `mkdir` lock, for the reason `containsKeyCommand` does: every
  write-back truncates before it writes, and an unlocked read landing in that
  instant reports an empty file — which here reads as "no keys on this
  machine". **The post-revocation proof reads through the locked listing too**,
  not through `containsCommand`, which is deliberately unlocked for the host's
  ten-times-a-second poll and would answer "gone" from that same empty read.
- **Both checks happen before anything is removed.** Validating only the
  *format* up front is not enough: `revoke <good> <typo>` then removed the
  first key before finding the second was not there. Markers are also
  de-duplicated, or the same one is revoked once and reported twice. That pass
  rules out a *missing* marker; a removal that fails partway can still leave an
  earlier one revoked, so the message says which rather than claiming nothing
  happened.
- **A concrete `bleat keys revoke <marker>` is only suggested when exactly one
  device is paired.** With two, naming either is naming an arbitrary one, and
  the user pastes it and revokes the phone they meant to keep. Which key is
  which phone is a question only the fingerprints answer.

### `$` is the wrong anchor for an `authorized_keys` line (found in review)

A `$`-anchored pattern does **not** match a line ending in a space — and sshd
still accepts the key on that line. Every marker pattern shared the anchor, so
such a key was invisible to `listCommand`, `containsCommand` **and**
`removeCommand` at once: it could be neither seen nor revoked, which is the
exact failure `bleat keys` exists to prevent. The same shape reaches a
`bleat-enroll-` line, where it survives `bleat pair`'s own sweep and cleanup.

`AuthorizedKeys.lineEnd` (`[[:space:]]*$`) is now the single definition, used
by every one of them so the listing and the deletion cannot disagree. A `\r`
from a Windows-edited file is covered by the same class. `Entry.parse` splits
on whitespace, which tolerates it already — the two ends have to agree or the
tool lists a key it cannot then remove.

Related, from the same review:

- **sshd accepts `YYYYMMDD` and `YYYYMMDDHHMM` as well as the full stamp**,
  with or without `Z` (without one it is *local* time, which is why nothing
  here writes that form). Reading only the written form reported a deadline
  sshd is enforcing as no deadline at all. `Entry` keeps the raw `expiryStamp`
  beside the parsed `expiresAt`, so "no deadline" and "a deadline this build
  cannot read" stay different answers.
- **Options can contain a quoted space** (`command="echo hi",restrict`), which
  splits into two fields and pushes the key past a fixed two-field window.
  `Entry` scans for the field pair that parses instead.
- `locked()` creates `~/.ssh` with `mkdir -m 700`, since the lock wraps reads
  now and a listing left a new directory behind at the umask default.

**Piped output is block-buffered, and both commands print before a long wait.**
`bleat pair`'s fallback link and `bleat redeem`'s progress line are flushed
explicitly. Without that, `bleat pair > file` shows the link only once the tool
exits — by which point the key it carries has been removed, which makes the
entire non-TTY path useless exactly where it is needed.

## The pane view (Phase 2, verified 5 Sept 2026)

- **Read-only, by `terminal session observe`.** It cannot disturb whoever holds
  input on the pane, which is the whole of the Phase 2 gate and the right
  default besides: Herdr allows one input owner, and taking it from a running
  agent because someone glanced at their phone would be indefensible. `control`
  and `--takeover` are Phase 3, behind a deliberate gesture.
- **The host is asked to render at the phone's size, and this is a known
  problem — see below.** `observe --cols --rows` is honoured in the sense that
  the frame reports the size asked for. The size is only knowable after a layout
  pass, which is why the terminal lives in a view *controller*; rotation reopens
  the stream, and the first frame of a new one is `full: true`, so the screen
  simply redraws.

### `--cols` crops. It does not reflow — so the app renders the whole pane

An earlier version of this file claimed a wide pane "arrives already reflowed".
**That is false.** Measured against `w5:p1`, whose grid is 142 columns
(`herdr pane layout --pane w5:p1` → `rect: {width: 142, height: 47}`):

| asked | frame reports | widest content |
|---|---|---|
| 53 | 53 × 12 | 53, cut mid-word |
| 100 | 100 × 12 | 100, cut mid-word |
| 500 | 500 × 12 | **140** |

So `--cols` is a **viewport onto the existing grid** — it crops when narrower
and pads when wider. Asking for a phone's 53 columns hid 63% of every line with
nothing on screen to say so, and `observe` takes no horizontal offset, so
panning has to happen on the client.

**This is not a herdr limitation.** A pane is one pty with one screen buffer of
a single width, and the program inside wrapped its output to it. Any client that
wants different wrapping would have to resize the pty — and no client of this API
can. See below.

### A pane's size belongs to the session. No stream client can change it (verified 6 Sept 2026)

An earlier version of this file said a client "has to resize the pty, which
resizes it for whoever is at the Mac too — `control` can do that via
`terminal.resize`, and Phase 3 will have to decide whether it may." **The second
half was false and is withdrawn.** It was reasoning, not measurement. Measured in
an isolated headless session, against a pane whose rect was 94x39:

| what was attached | pane rect after |
|---|---|
| nothing (headless) | 94x39 |
| `observe --cols 60 --rows 20` | 94x39 |
| `control --cols 60 --rows 20 --takeover` | 94x39 |
| `{"type":"terminal.resize","cols":60,"rows":20}` on stdin | 94x39 |

Nothing moved it, and the resize record was *accepted* — no `input ignored` on
stderr. What it did do is visible in the frames that one client received:
`120x40 full=true` on attach, then `60x20 full=true` after the record. So
`--cols`, `--rows` and `terminal.resize` are all **one client's viewport** and
nothing else.

**The geometry comes from the session's terminal size**, which is the attached
TUI's window when one is attached and `server.headless_cols` /
`server.headless_rows` when none is. Proved by restarting the same server under
`headless_cols = 200, headless_rows = 60`: the pane became 174x59 — 200 minus the
26-column sidebar, 60 minus the tab-bar row. Every pane in a session shares it;
on the dev Mac all seven workspaces report `area=142x47+26,1`.

Three consequences:

- **Bleat cannot disturb the Mac through this API, at all.** The Phase 3 question
  this file used to record — whether Bleat "may" resize someone's pane — does not
  exist. Nothing about the pane view needs to be defensive about it.
- **Resizing the Mac's window does change the pane**, because that is the session
  geometry moving. Bleat sees the new rect on its next `pane layout`; its own
  `--cols` never enters into it.
- **A phone-shaped host is a config change, not a client feature.** A herdr
  running headless sits at `headless_cols`/`headless_rows` (120x40 by default), so
  a phone-first setup can set those and every pane really is that size. That is a
  better answer than anything a client can do and needs no code here.

**The crop was re-verified in the same controlled session**, since it is the fact
the whole design rests on. A single line of `A`x60 + `B`x60 + `C`x54 printed into
a 174-column pane, read by two observers at once:

| client asks | A | B | C |
|---|---|---|---|
| `--cols 174` | 60 | 60 | 54 |
| `--cols 60` | 60 | **0** | **0** |

The B's and C's are **gone, not wrapped onto a second line**. `--cols` crops. It
has never reflowed and cannot.

Two escape hatches found while probing, both worth knowing:
`experimental.allow_nested = true` in the config is what lifts the "nested herdr
is disabled by default" guard that has blocked scratch sessions from inside a
herdr pane, and `HERDR_CONFIG_PATH` lets a probe run on its own config without
touching the user's. Together with `HERDR_SESSION` and an unset
`HERDR_SOCKET_PATH`, that is how to get a disposable session to measure in —
`herdr server` with no subcommand runs one headless.

**What the app does now (option 1 of the four that were weighed).** It asks
`pane layout --pane <target>` for the pane's real grid, opens the stream at
*that* size, renders a terminal of exactly that many cells, and lets the user
pan. Nothing is ever hidden; landscape shows ~118 of 142 columns at once.

- **`PaneLayout` looks the pane up by id.** The layout belongs to a **tab**, not
  a workspace — verified live: `wA` has two panes and `pane layout` for either
  returns a single-pane layout, because they are in different tabs (`wA:t1`,
  `wA:t4`). A split tab puts several in `panes`, and rendering at a sibling's
  width would wrap every line. The tab's `area` is not the pane's rect either:
  `x` was 26, because herdr was drawing a sidebar.
- **A host that will not report a layout still gets a pane.** `HerdrError` and
  `DecodingError` fall back to the phone's size — the host reached and saying
  no, or answering in a shape that has moved. `PaneLayout` makes everything but
  `panes` optional for the same reason: the app reads only a pane's `rect`, and
  a decode failure on a field nothing uses would jump straight over the fallback
  and kill the pane instead of cropping it. A `TransportError` does propagate,
  because swallowing it would spend a second opening a stream that cannot open
  either and then blame the wrong thing. The fallback crops, so the badge says
  so.
- **Frames are held until the terminal is actually that size.** SwiftUI
  publishes the grid an async hop before the view resizes to it, and the first
  frame lands in that window — a frame written for 142 columns fed to a
  53-column terminal wraps every line, and `observe` sends a full redraw only
  when it opens, so nothing would repair it. The controller reports the size it
  applied and the model flushes then. Buffered frames are dropped on a reopen:
  they were drawn for the old size.
- **Nothing about the chosen size is written before the cancellation guard.** A
  reader suspended in `pane layout` across a rotation resumes holding the
  pre-rotation viewport, and writing it then would clobber the size the live
  reader had just installed — leaving the screen rendering one grid while the
  stream sends another, and a rotation back deduplicated into doing nothing.
- **The terminal's background is read off its `layer`.** SwiftTerm's
  `setupOptions` moves the real colour into `layer.backgroundColor` and then
  sets `nativeBackgroundColor` to `UIColor.clear`, so the obvious property
  paints a transparent band — white under a black terminal in light mode, and a
  47-row pane leaves ~50pt bare under a portrait iPhone plus the whole overscroll
  region.
- **The terminal is never sized to the screen and then to the grid in one
  layout pass.** `TerminalView` reflows its buffer on every size change and the
  `observe` stream sends a full redraw only when it opens, so a stray
  intermediate size scrambles the screen with nothing left to repaint it. No
  bootstrap pass is needed to measure a cell either: SwiftTerm's
  `cellDimension` comes from the font at init rather than from the frame, and
  although it is internal, `getOptimalFrameSize()` is public and returns exactly
  `cellDimension × (cols, rows)` — so dividing by the terminal's own size
  recovers it without guessing at a font metric.
- **The frame is the only way to ask for a number of columns.** `TerminalView`
  derives its size from its bounds (`Int(width / cellWidth)`) and has no public
  setter. Landing exactly on `cols * cellWidth` puts that division on a boundary
  where an error of one ulp costs a whole column, and a terminal one column
  narrower than the stream it is fed wraps every line. Rounding up and adding
  half a point clears the boundary by far more than any float error and far less
  than a cell.
- **Rotation no longer reopens the stream.** The size asked for is the pane's,
  not the phone's, so turning the device changes only how much of it is visible.
  A stream opened at the *fallback* size does still reopen, because that one is
  cropped to the phone.
- **The pane's own scrollback is not reachable, and that is the price.**
  `TerminalView` is a `UIScrollView` that uses its own `contentOffset` to choose
  which buffer lines to draw, so it cannot both scroll through history and be
  panned bodily by an outer scroll view — two scroll views competing for one
  drag makes the pane unmovable. Its scrolling is off; the outer one pans the
  whole 142×47 grid. Scrolling *history* should not be a local gesture anyway:
  the host tracks it per pane (`pane list` carries `scroll.offset_from_bottom`
  and `max_offset_from_bottom`) and `terminal.scroll` exists as a stdin record,
  so the honest version asks the host. **Unverified: whether `observe` accepts
  stdin at all** — the four record types were confirmed against `control`.
- **A badge in the corner names the grid**, and says "cropped" when the fallback
  is in use. The pane is deliberately larger than the screen now, and a scroll
  indicator that appears only once you already know to drag is not an
  affordance on its own; the indicators are also flashed once when there is
  something off-screen to find.
- `BleatUI` has no test target, so the cell arithmetic above is verified on
  device rather than in a test. `PaneLayout` and its lookup are covered from the
  captured fixture.

Not taken: fitting the full width to the screen (~2.8pt type, not viable), or
keeping the crop and merely labelling it. A genuine resize via `control` is not
on the table either — it does not exist, per the section above. The phone-shaped
answer is a session whose *own* geometry is phone-shaped, set by
`server.headless_cols`/`headless_rows` on the host.

Resolved by the same probe: two clients of different sizes attaching to one
session do **not** fight, and nothing shrinks to the smallest as tmux would.
Each gets its own cropped or padded viewport onto one unchanged grid.

- **Frames that arrive before the renderer exists are held, not dropped.** The
  first frame is the full-screen replay, and on an idle pane nothing follows it
  — losing it leaves a blank screen until something changes on the host, which
  may be never.
- **The terminal refuses first-responder status; it does not disable
  interaction.** `isUserInteractionEnabled = false` looks like the way to keep
  the keyboard away and also kills scrolling, which is most of the point of a
  read-only pane. `TerminalView` raises the keyboard from its own tap and
  long-press recognisers, so overriding `canBecomeFirstResponder` is what stops
  it while leaving the scroll view alone.
- **Read the terminal's size after forcing its layout, and take `sizeChanged`
  as authoritative.** `TerminalView` recomputes cols and rows in its own
  `layoutSubviews`, which runs *after* the hosting controller's
  `viewDidLayoutSubviews`, so reading it there without `layoutIfNeeded()`
  reports `TerminalOptions`' default 80×25 — a size the view cannot show, asked
  of the host for the life of the screen. `sizeChanged` is fired from
  `processSizeChange` when the *view's* geometry changes what fits, whatever the
  protocol's own documentation says about remote requests for 132 columns; it is
  the correctly-timed answer and ignoring it is how a wrong size goes
  uncorrected.
- **Closing the previous stream happens alongside the new dial, not before it.**
  `SSHStream.close()` waits up to a second for output to drain and an `observe`
  stream never ends on its own, so that second is always spent — serially, it
  would delay every rotation by a full second behind a stale screen.
- **Every `TerminalViewDelegate` method is a no-op, deliberately.** The protocol
  has no default implementations so each must be written out, and three are
  refusals rather than omissions: `send` has nowhere to go until Phase 3,
  `clipboardCopy` would let a remote pane write to the phone's pasteboard, and
  `requestOpenLink` would let anything a pane prints send the phone to a URL of
  its choosing.

## Concurrency settings (verified 4 Sept 2026)

The package and the Xcode targets must state the same thing, or a file changes
behaviour when it moves across the seam.

| where | settings |
|---|---|
| Xcode targets | `SWIFT_VERSION = 6.0`, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, `SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY = YES` |
| package | `swiftLanguageModes: [.v6]`, `.enableUpcomingFeature("MemberImportVisibility")` on every target, `.defaultIsolation(MainActor.self)` on `BleatUI` only |

- **`SWIFT_APPROACHABLE_CONCURRENCY` is off on both sides, deliberately.** Its
  package half, `NonisolatedNonsendingByDefault`, reproducibly segfaults the
  test bundle on Swift 6.3.3: `swift test` dies with signal 11, while
  `swift test --no-parallel` passes all 70 and every suite passes alone — so it
  only bites under swift-testing's parallel execution. Enabling it for the app
  alone would be worse than leaving it off for both, because then the seam
  really would differ. Revisit on a newer toolchain.
- **`.defaultIsolation(MainActor.self)` is on `BleatUI` only.** `BleatKit` is a
  transport and domain library whose work belongs off the main actor, and the
  console tool links it with no main actor in sight. Isolation there is
  expressed per type.
- `SWIFT_VERSION` is the setting that silently lags: the isolation settings can
  be on while strict checking is not actually running. Check it before believing
  the project is on Swift 6.

## Conventions

- Swift 6.2, strict concurrency, `Sendable` everywhere in BleatKit.
- One type per file. Folders by feature, not by kind.
- `async/await` only; no Combine, no callbacks.
- Errors are typed: `HerdrError` (host said no), `TransportError` (network),
  `DecodingError` (contract drift). Never swallow stderr.
- Tests use `FakeTransport` fed from `Fixtures/`. No test touches the network.
- Third-party dependencies: **Citadel** and **SwiftTerm**, both approved. Ask
  before adding a third. SwiftTerm is a real VT100/xterm emulator and there is
  no honest alternative: `terminal.frame` payloads carry cursor positioning and
  synchronized-output markers *inside* the bytes, so anything that approximated
  ANSI would render an agent's pane as nonsense. It is linked by `BleatUI`
  only — `BleatKit` stays free of rendering, and the console tool writes the
  same bytes to a terminal that already knows how to read them. It ships a
  build tool plugin; see `ci_scripts/ci_post_clone.sh`.
- Keep this file current: phase, verified facts, decisions. It is the onboarding
  doc for every session.

## Working style

- **From Phase 2 on, work happens on branches and lands via pull requests.**
  One branch per reviewable chunk, not one per phase. Never commit Phase 2+ work
  directly to `main`.
  - Branch from up-to-date `main`, e.g. `phase2/workspace-list-view`.
  - Each PR is one coherent, reviewable change that builds and tests green on
    its own; split anything that needs "and also" to describe it.
  - Merge with `gh pr merge --merge` (a true merge commit) so the branch's
    history survives on `main`. Never `--squash` or `--rebase` unless asked for
    that specific PR.
  - Phase 1 landed directly on `main`; that was the exception, not the pattern.
  - The repo keeps `deleteBranchOnMerge: false` **on purpose**. Auto-delete
    would pull the base branch out from under a stacked PR the moment its
    parent merged. Delete merged branches deliberately instead, once nothing
    is stacked on them.
- Small PR-sized steps; each ends with `swift build && swift test` green.
- Before writing a model, look at the fixture. Before writing a command, run it
  on the host and capture the output into `Fixtures/`.
- Ask before: adding dependencies, adding platform branches, changing the
  transport protocol, or starting Phase 2 work.
- Multi-account note: the developer runs two Claude Code accounts via direnv
  (`CLAUDE_CONFIG_DIR` per directory). A pane's `cwd` implies the account;
  Bleat may show that as a badge later. Not a Phase 1 concern.

## Open questions (resolve against the live host, then delete)

- Does `agent prompt --wait` return a JSON result on completion, and what is
  the timeout behavior?
- Capturing a `blocked` and a `done` agent row into `Fixtures/`. Only `idle`,
  `working` and `unknown` have been seen live so far.
- Whether the host ever sends a non-`terminal.frame` record on stdout. Only
  frames have been observed; `TerminalRecord.unknown` covers the rest.
- **Whether `terminal session observe` accepts stdin at all.** The four record
  types were verified against `control`. If `terminal.scroll` works on an
  observer, host-side scrollback is available to the read-only pane view, which
  is the honest replacement for the local scrolling the sizing work gave up.
- **A split tab's `pane layout`.** Never captured: `herdr session attach`
  refuses from inside a herdr pane ("nested herdr is disabled by default"), and
  creating a split in the live `work` session is out of bounds. The lookup is
  tested against a layout derived from the real fixture, which is weaker.

Resolved (4 Sept 2026): `terminal.frame` shape and the absence of a cursor
field; `agent list` needing no join; the four stdin record types; and
`terminal.release` — the host closes the stream and the command **exits 0**, so
release is the clean detach and the channel need not be killed.

## Testing against a live host

`herdr` runs on the dev Mac, so Phase 1 does not need SSH to be exercised.
`LocalProcessTransport` spawns the CLI directly behind the same
`HerdrTransport` seam that `SSHTransport` will sit behind.

- Never experiment against the `work` session: it holds real agents, and
  `--takeover` seizes input from whoever owns it.
- Start an isolated session instead — it needs a pty, so:
  `script -q /dev/null herdr session attach bleat-test &`. A client command
  alone will not autostart a server; it returns `server_not_running`.
- Tear it down with `herdr session stop <name>` when finished.

To exercise the SSH path without changing system settings, generate a host key
and a client key, write an `sshd_config` with `StrictModes no` and
`UsePAM no`, and run `/usr/sbin/sshd -f <config> -D -e` as your own user on a
high port bound to `127.0.0.1`. Remember `herdr` will not be on the PATH of the
resulting non-login shell, so pass `--herdr /opt/homebrew/bin/herdr`.

**Testing pairing needs one more line in that config, and it is not optional.**
Pairing writes to `~/.ssh/authorized_keys`, and `~` in an exec channel is the
*real* home: sshd logs you into your actual account whatever `HOME` the tool was
started with. Pointing `AuthorizedKeysFile` at a scratch file does **not** move
the shell's `~`, so the two disagree — and a run under that config installs a key
in your own `authorized_keys` while reporting success against a file sshd never
reads. Add `SetEnv HOME=<scratch>` alongside the scratch `AuthorizedKeysFile`
(verified: the session's `HOME` and `~` both become the scratch), and run
`bleat pair` with the same `HOME`. Then everything stays inside the scratch
directory.

`PATH` cannot describe a host without herdr, either: `/etc/profile` runs
`path_helper`, which rebuilds `PATH` from `/etc/paths.d` — and Homebrew installs
a file there — so a login shell puts `/opt/homebrew/bin` back whatever it was
handed. Supply a stub `$SHELL` instead, as `EnrollmentShellTests` does.

Note that `NSHomeDirectory()` **ignores `$HOME`** on macOS — it reads the passwd
entry — so `PeerRegistry.standard()` and `HostRegistry.standard()` still write to
the real `~/.bleat/` under a scratch `HOME`. Pass an explicit directory when that
matters.
