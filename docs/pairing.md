# Pairing and peer identity (stable rules — do not relitigate per PR)

> Moved verbatim from `CLAUDE.md` on 1 Oct 2026. Where the text says "this file", "above" or "below", it means the old single file; a **bold** section name can be found with `grep -r docs/`.

Pairing is how a phone acquires a host. The Mac-side `bleat pair` does the hard
part — it already knows everything the phone needs — and the phone scans one QR.

## The key exchange: the durable private key never leaves the phone

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

## Pairing another device from a paired one (3 Oct 2026)

`bleat pair` without the terminal. A device that is already paired is already
trusted by the host, and it knows everything the tool would put in the code —
the host key, the user, the addresses the host reported — so it installs the
enrollment key itself, over its own connection, and shows the code. The other
device redeems it with the ordinary pairing sheet, or `bleat redeem` with the
copied link; `Enrollment` cannot tell the two kinds of code apart.

`Invitation` in `BleatKit` is the host side, run over a `ShellRunner`;
`InviteModel` and `InviteView` in `BleatUI` are the screen. It is the QR
button on a host's screen, and **Pair another device** in its settings.

- **The same three layers keep the key from outliving the pairing**, moved
  across. Closing the screen withdraws it (from a task of its own, since the
  one watching it has been cancelled). The deadline withdraws it. And the line
  carries `restrict,expiry-time=`, so **sshd** refuses it after the window
  plus the grace whatever happened to the phone — killed, flat, offline. The
  window and grace are `Invitation.window` and `.expiryGrace`, which
  `bleat pair` now reads too.
- **It does not sweep other enrollment keys**, where `bleat pair` does. On
  the host a stale key is the tool's own leftover; from a phone another
  `bleat-enroll-` line may be a pairing in progress at the keyboard or on a
  second phone, and sweeping it would end that pairing.
- **"Gone with no new device key" is reported as removed, not as paired.**
  `bleat pair` run at the host sweeps every enrollment key, this one
  included. The enrollment line is checked before the device keys, and the
  redeeming device installs its key before deleting the line, so a line seen
  gone with no new key beside it a moment later was not taken by a redemption.
- **Every read of the file takes the lock, and is one read.** Each
  write-back to `authorized_keys` empties the file before filling it, so an
  unlocked read can see nothing — `bleat pair` shrugs that off because its
  next poll is a tenth of a second away. Here it would be final: the watch
  would end with the key still live, reported as used or removed. So
  `Invitation` reads `listCommand` (locked) and takes the enrollment line and
  the device keys from that one snapshot. (Found in review.)
- **The key is minted before it is installed** (`prepare`, then `install`),
  so a screen closed while the key is going in still knows which line to
  withdraw — and does, whether or not the install was confirmed. That
  cancellation is not handed to `ConnectionStore.handle`, which would close
  the connection the screens behind the sheet are using. (Found in review.)
- **The append is read back** before the code is shown. A code with no key
  behind it would fail on the other device for five minutes, blaming nothing.
- **A dropped connection does not end the code.** The key is still on the
  host; each poll asks `ConnectionStore` for a shell, which re-dials, and
  only the deadline ends the wait. One poll a second, against the tool's ten:
  this is an exec channel over whatever network the phone is on.
- **The code is drawn at correction level M**, not L as in the terminal: a
  phone screen held to another phone's camera catches glare.
- **The link can be copied, for `bleat redeem` on a computer**, and the screen
  says it holds the key. It is the same trade `bleat pair` makes when it falls
  back to printing the link.
- **The code carries the peer's endpoints as this device has them**, the
  host's own report plus anything added by hand. An address only this phone
  can resolve costs the other device one slot in its race.

Tested against a real shell and a real `authorized_keys`
(`InvitationShellTests`): open, a full redemption by `Enrollment.redeem`,
withdraw, a sweep at the host, and two codes at once. The model's polling,
cancelling, deadline and dropped connection are `InviteModelTests`. **Not yet
run end to end between two real devices.**

## A peer is a host key, not an address

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
  - Tailscale addresses arrive **via `ifconfig`** — the tunnel's `utun`
    interface holds them and they pass every filter, then `Endpoint.reach`
    classifies them `.overlay`. Verified on device over cellular, 7 Sept 2026.
    This is how it worked before any Tailscale-specific code existed.
  - The **MagicDNS name** does need the CLI (`tailscale status --json` →
    `Self.DNSName`), because no interface carries it. `TailscaleStatus` parses
    it and `HostInspector` runs the command, from an absolute path — `run` does
    not search `PATH` deliberately, since resolving a tool through the user's
    `PATH` during pairing is a way to execute something else entirely.
    - **`DNSName` comes back fully qualified, with a trailing dot.** Verified
      live: `kestrel.tailf00d42.ts.net.`
    - Taken only when `BackendState` is `Running` — a stopped or logged-out
      Tailscale still reports the last state it knew, and an endpoint recorded
      from a tailnet the machine may have left is indistinguishable later from
      a host that is merely switched off.
    - …and only when `CurrentTailnet.MagicDNSEnabled` is true, or the name does
      not resolve and every race spends a timeout on it.
    - It earns its place because a node's address is stable only while its node
      record lives: removing the machine from the tailnet and re-adding it
      mints a new one. The name follows the machine across that.
  - **Twingate and similar zero-trust overlays give the host no address of its
    own, and this is a different shape from Tailscale rather than a gap in the
    detection.** A mesh puts an address on every node's own interface, which is
    why `ifconfig` finds Tailscale. A zero-trust client instead runs a Connector
    inside the private network and routes the *client* to resources by their
    ordinary private address or private DNS name. There is nothing new on the
    host to discover, and there never will be.
    - So the endpoint that works over Twingate is the host's **plain LAN
      address**, which is already enumerated and already in every peer record.
      What was wrong was on the phone: `endpointsToTry` dropped private
      addresses the moment the phone left Wi-Fi, so the one candidate that
      would have connected was never dialled. See **Endpoint selection on the
      phone**.
    - A private *DNS name* still has to be user-supplied via `--endpoint`,
      since nothing on the host knows it.

## The QR carries the host key, not its fingerprint

`KnownHostsStore` pins the OpenSSH `<algorithm> <base64>` string —
`PinningHostKeyValidator` builds exactly that via `String(openSSHPublicKey:)`
— so that is the form the QR must carry. A `SHA256:` fingerprint can only be
*displayed*, never compared against a pin, and shipping one would have made
every paired connection fail its pin check. It costs about 30 bytes in the QR.
Show the fingerprint derived from it; never store one as the identity.

## Which host key the QR names (verified 4 Sept 2026)

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

## Which local addresses are offered

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

## Displaying the QR

`CIQRCodeGenerator` on macOS and `QREncoder` on Linux (see **The console tool
builds for Linux** in [`repository-layout.md`](repository-layout.md)).
`QRMatrix` and its renderer are in `BleatKit` and shared.

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

**Tailscale spends some of that back, and it is worth knowing how much.**
Measured 7 Sept 2026 at level L with a 4-module quiet zone, and pinned by
`QRPayloadSizeTests`:

**Measure at `quietZone: 3`, which is what `bleat pair` renders.** The
parameter is *extra* modules on top of the one `CIQRCodeGenerator` emits, so 3
draws the 4 the spec wants. Measuring at 4 inflates every figure by a row — a
wrong-but-plausible number, which a first version of the table below had.

| endpoints | modules | rows |
|---|---|---|
| 4 — LAN plus both Tailscale addresses | 61 | 31 |
| 5 — and the MagicDNS name | 65 | 33 |
| 7 — everything this Mac offers | 73 | 37 |

So the name costs two rows and a Tailscale-connected Mac costs six over a
LAN-only one. With three rows of chrome the worst case needs **40** — one row
inside the reduced-margin threshold this file measured earlier. A shorter window
falls back to the link. `QRPayloadSizeTests` defends that row.

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

## The phone's side of the swap (verified end to end, 5 Sept 2026)

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

After step 5, and before the sessions close, the phone asks the host what it
is — `HostStatusProbe` without its second-long processor sample — and stores
that on the new record, so the host list can show it straight away. A host
that does not answer is paired all the same. **The record is saved before the
probe runs, and the probe races a five-second deadline** — closing the
sessions ends one that overran. Without both, a host whose `$HOME` sits on a
stalled mount would leave this device's key installed and no record of it on
the phone. (Found in review.)

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

**When every endpoint left is an overlay address, the message names the VPN** —
`TransportError.overlayUnreachable`. On cellular against a Tailscale-only host,
`endpointsToTry` has already dropped the `.local` name and the LAN addresses as
unroutable, so if nothing answered the likeliest cause is the tunnel being down
on the *phone*, and "none of N address(es) could be reached" sends the user to
check a network that is working perfectly. `PeerConnector` cannot see the VPN's
state (`Network` is Apple-only and that file compiles for Linux), so it names
the possibility rather than asserting it. A mixed list keeps the ordinary
message: a LAN address among the candidates means the phone is on Wi-Fi and the
host is simply off, asleep, or elsewhere.

- **It fires only when the caller passes `droppedUnroutable`, and that flag is
  load-bearing.** Only `PeerConnection.connect` can vouch for it, because only
  it filtered. Pairing calls the connector a second time with a deliberately
  narrowed list — one endpoint, the one that just carried the enrollment
  handshake — to ask whether this host accepts the new device key, and every
  candidate there is trivially an overlay address. Without the flag the user
  would be told to check a VPN that had demonstrably just worked, at the one
  moment in the flow where the enrollment key may already be spent and
  rescanning is not an option.
- **It is its own error case rather than a `connectionFailed` with different
  words**, because callers classify on the case. `PairingModel` reads a plain
  `connectionFailed` as possibly iOS's local network permission and waits a
  minute for an answer — which cannot be the cause when no local address was
  dialled at all.

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

## Endpoints are refreshed on connect, not captured once (Phase 2)

Endpoints used to be read at pair time and never looked at again, so a Mac that
moved network, a Tailscale node removed and re-added, or a tunnel set up after
pairing each cost a full re-pair — walking back to the Mac to run `bleat pair`.
The host is the authority on its own addresses and the phone is already talking
to it, so it asks.

**This is safe because of what authenticated it.** Anything learned over a
connection already verified against the pinned host key is exactly as
trustworthy as the pin, which is what lets a refresh happen silently with
nothing to confirm.

`EndpointDiscovery` in `BleatKit` holds both the three probes and the assembly
of their answers, and **both ends use it**: `HostInspector` runs the commands
locally with `Process` while `bleat pair` mints a QR, and `PeerStore` runs them
over an exec channel on a connection it already has. Two copies of "which
addresses does this machine offer" would drift silently — the phone would keep
folding a peer into a shape `bleat pair` would never have produced.

- Every probe ends in `|| true`, for the reason `HerdrLookup.command` does:
  absence is a normal answer. Without it a host without `scutil` produces a
  *failed command* and the user is told "the host rejected a command (exit 1)"
  about a machine that is working perfectly.
- The probes run **serially**, not with `async let`. Three concurrent exec
  channels would save a few hundred milliseconds of work nobody waits for, in
  exchange for exercising concurrent use of `SSHTransport` — which wraps a
  Citadel client that is not `Sendable`-audited and is lock-guarded for exactly
  that reason. Serial is also what makes the cancellation checks between them
  mean anything.
- It runs **after** the connection is installed and is never awaited by the
  screen, so a list draws at the same speed it always did — and only on a fresh
  dial, since a reused connection returns before reaching it.

**Cancelling the refresh is not enough on its own, and this is the sharp
edge.** `SSHTransport` re-dials lazily when its client is nil and
`SSHClient.connect` does not observe cancellation, so a probe command that runs
after `ConnectionStore.release()` has disconnected opens a **brand new SSH
session** that nothing references and nothing will close — an orphaned session
on the user's Mac, which is the one thing `ConnectionStore` promises not to
leave. So `EndpointDiscovery.probe` checks `Task.isCancelled` between every
command, a cancelled probe reports **nothing at all** rather than a partial
answer, and `release()` *awaits* the task exactly as it already does a dial in
flight.

## The `tailscale` probe, and what running it taught

Same loop as `HostInspector.tailscaleStatusJSON` — absolute paths, in order,
first that *answers* — with a five-second watchdog, since `tailscale` has no
timeout flag and a wedged `tailscaled` would hold the exec channel for the life
of the connection. Four of its details were bugs, and each was found by running
the string rather than reading it:

- **`status` is read-only in `zsh`**, which is what sshd runs on a modern macOS.
  Naming the exit status that aborted the whole loop under the one shell it will
  actually meet, while working under `sh` and `bash`. Verified across all three
  now.
- **Each attempt writes to its own scratch file.** Straight to stdout, the
  attempts concatenate: a binary that emits a partial object before failing, or
  one killed mid-write by the watchdog, glues that fragment to the front of the
  next binary's reply. Reproduced — `{"partial":{…}{"BackendState":…}` — which
  parses as nothing, so the loop written to save the MagicDNS name lost it in
  the exact case it exists for.
- **Exiting 0 is not answering.** A Homebrew CLI that cannot reach the App Store
  app's daemon exits cleanly reporting `NeedsLogin` or `Stopped`, so stopping at
  the first clean exit never tries the bundled binary that would have answered.
  The condition is `BackendState == "Running"`, greped here and checked by
  `TailscaleStatus.isRunning` locally; the two have to agree.
- **The watchdog's output goes to `/dev/null`** so it is not a writer on the
  channel — attached, it holds the command open for the full five seconds on
  every run — and `exec 2>/dev/null` suppresses the shell's `Terminated: 15`
  notice when the watchdog is killed.

**What a refresh may change, and the four rules that bound it.** `PairedPeer`
gains `hostReport`, the host's most recent self-report **kept per probe**.

- **`nil` is not an empty report.** `nil` means never refreshed, so nothing on
  the record can be attributed to the host and the first refresh may add but
  must not prune. Without that distinction every `--endpoint` extra baked into
  a QR would vanish the first time the phone connected after this shipped.
- **A report no probe answered changes nothing.** That is the host being
  unaskable — or the refresh being cancelled — and not the host saying it has no
  addresses. Reading it as one would empty the peer and strand the phone with a
  record it can never connect through again.
- **Pruning is per probe, not per report, and this is the one that matters
  most.** Flattened into a single list, one flaky probe is indistinguishable
  from a host that has dropped a whole category. Tailscale being switched off is
  not even an error — the CLI exits 0 with `BackendState: "Stopped"` — so
  `scutil` and `ifconfig` answering normally would yield a perfectly non-empty
  report with no overlay endpoints in it, and one pass would delete the MagicDNS
  name and both tunnel addresses. The next time the phone was on cellular the
  host would be unreachable **permanently, from a transient condition** — which
  is the exact cost this feature exists to remove. So each of the three fields
  in `EndpointDiscovery.Report` is independently optional: `nil` means "this
  probe gave no confident answer" and prunes nothing, while an empty array is a
  real answer.
- **Only what the host previously claimed may be pruned.** Everything else is
  sticky — `--endpoint` extras, anything added by hand — because detection
  cannot see them and their absence from a report is not evidence of anything.
  This is what protects a Twingate private DNS name.
- **`lastGoodEndpoint` survives, for one refresh.** It completed a handshake
  minutes ago, which outranks any report about it. Putting it back is recorded
  in `Report.reinstated` so the exemption *expires*: unrecorded, it reads as an
  address the host never claimed and becomes permanently un-prunable, so a
  recycled DHCP lease that won one race would live in the peer forever — the
  very hazard the pruning exists for.

**Discovery yields addresses, never ports**, so a refresh must not invent one.
`scutil`, `ifconfig` and `tailscale` all report where a machine is found and
none of them knows what port its sshd binds — that was settled once, by
`bleat pair --port`. `PairedPeer.discoveryPort` is the port the peer already
associates with the host: the most common one across its endpoints.

The obvious alternative strands the peer. Taking the port of the endpoint that
just won the race looks right — it demonstrably reached sshd — but the winner
can be a hand-added port forward, which is the motivating reason to add one. A
peer with three `:22` addresses plus a typed `home.example.com:2222` connects
over the forward from cellular; the refresh then rebuilds every discovered
address at 2222 and supersedes the three that worked. Back on Wi-Fi nothing
connects, and since no connection succeeds no later refresh can repair it — a
re-pair, caused by using the feature exactly as documented.

**Pruning matters as much as adding, and it is the half that is easy to skip.**
A list that only grows accumulates recycled DHCP leases and dead node
addresses, each dialled on every connection afterwards. Worse than the wasted
race slot: a recycled address reaches an unrelated machine and fails *host key
verification*, and `PeerConnector` promotes a mismatch over every other failure
— so a sleeping Mac plus one stale address reports a security warning instead of
"could not reach it". `InterfaceAddresses.ignoredPrefixes` exists to avoid the
identical hazard from virtual interfaces.

`PeerRegistry.recordDiscoveredEndpoints` is a **targeted mutation**, for the
reason `recordHerdrPath` is one and more urgently: `save` merges, a merge takes
the newer record's `lastGoodEndpoint`, and this runs moments after
`recordSuccess`.

**It is a hedge, not a guarantee.** A refresh only happens over a connection
that still works, so a host whose every stored endpoint died at once is still a
re-pair. What it removes is the far more common case where *one* of them
changed.

## Addresses added by hand (Phase 2)

The backstop under the other two. Pairing enumerates what the host can see about
itself and a refresh asks it again on every connection, but **neither can
produce an address the host does not know it has** — which is exactly a
zero-trust overlay's private DNS name, held entirely on the client's side. It
equally covers a port forward or a jump address, which have no discovery story
at all.

`PeerSettingsView`'s "Reachable at" section adds and swipes-to-remove;
`PeerRegistry.addEndpoint` / `removeEndpoint` are targeted mutations like the
rest.

- **An added address is never written into `hostReport`**, which is
  what makes it permanent: a refresh may only prune what the host once claimed,
  so an address the host has never mentioned survives every refresh there will
  ever be. That is the entire point of adding it.
- **Removing the last-good address clears `lastGoodEndpoint`, and that is
  load-bearing.** `refreshingEndpoints` restores the last-good address
  unconditionally — it completed a handshake, which outranks any report — so a
  removal that left the field pointing at a deleted address would be silently
  undone by the next connection's refresh, minutes later, with nothing on screen
  to explain it.
- **The last address cannot be removed**, and the swipe action is hidden rather
  than shown and refused. A peer with none is unreachable *and* unrepairable
  from the phone: nothing is left to connect over, so nothing can add one back.
  Unpairing is the deliberate way to be rid of a peer.
- **An address the host still reports comes back on the next refresh**, and the
  section footer says the list maintains itself so this is not a surprise. A
  tombstone would make removal stick, at the cost of a way to blind the app
  permanently to a working address — racing one extra endpoint concurrently is
  much the cheaper mistake. An address the host has *never* reported stays
  removed, which is the case that matters: a stale entry from a QR.
- The port defaults to **the peer's own**, not 22. An address typed without one
  silently inheriting 22 on a host running sshd elsewhere produces an entry that
  looks right in the list and refuses every connection — the same trap
  `bleat inspect --endpoint` avoids by re-parsing against `--port`.
- **`Endpoint(string:)` is a parser, not a validator**, and this is the first
  place it is fed free text. Anything without a colon becomes a hostname
  verbatim, so `robin@mac.internal` — a very natural paste — `ssh mac.local` and
  `mac.local/foo` would all enable the button and be stored. Permanently:
  detection can never report them, so no refresh prunes them, and each is
  dialled in every race from then on and counted in the message explaining the
  failure. `Endpoint.isPlausibleHost` is the second half of the check, and it is
  deliberately a plausibility test rather than a hostname grammar — rejecting a
  valid internal name is the worse failure, since the user has no other way to
  add it.
- **`Endpoint` lower-cases its host.** DNS is case-insensitive and
  `Equatable`/`Hashable` are not, and every comparison in the refresh path runs
  on that equality: de-duplication, `Report.superseded`, `endpoints.contains`,
  the `lastGoodEndpoint` match. `Studio-Mac.local` beside `studio-mac.local`
  would be two endpoints for one machine, and the second could never be pruned —
  the host reports one form, so the other looks like an address it never claimed
  — leaving every race dialling the host twice forever. Reachable both by typing
  and from `scutil --get LocalHostName`.
- **Removing takes a deliberate tap** (`allowsFullSwipe: false`) and failures
  are shown *here*. An address added by hand is one detection can never report,
  so deleting it is permanent and undone only by retyping it; and a failed write
  would otherwise leave the row where it was with the message a screen back on
  the peer list, so the swipe would look like it had simply done nothing.
- **`PeerSettingsView` takes a host key, not a peer.** `PeerDetailView` can
  take the record as a plain value because `RouteView` looks it up on every
  body evaluation and swaps the whole screen out when it goes — but a sheet is
  presented once, from a router, and a captured `PairedPeer` would be stale the
  moment the user added or removed an address: the list they were looking at
  would not change. It looks the peer up itself and shows the same
  unpaired-message when the record is gone, which the root-level unpair flow
  can do while the sheet is still on screen.


## iOS's local network permission (Phase 2, found on device 7 Sept 2026)

**The first pairing on a fresh install always failed, and the message blamed
the network.** iOS gates any connection to a `.local` name or a LAN address
behind a permission alert, raised the first time something tries — and it does
not hold that connection open while it waits for an answer. So every endpoint
in `PeerConnector`'s race failed while the alert was still on screen, and
pairing reported `none of N address(es) could be reached`. Granting permission
fixed nothing visible; the user had to know to tap "Try again".

- **The real fix is to ask before there is anything to lose.**
  `LocalNetworkAccess.prime()` runs from the pairing sheet's `onAppear`, so the
  alert arrives while the user is still lining up the camera. Not at launch:
  a cold first-launch prompt with no context is what teaches people to tap
  Don't Allow.
- **There is no API that reports this permission.** It is inferred from an
  `NWBrowser`, which the same permission gates: `.ready` means it is running,
  which it cannot do without access. A `.waiting` or `.failed` carrying DNS
  `-65555`/`-65570` (`NoAuth`/`PolicyDenied`) is the system positively
  refusing, which covers both "the alert is unanswered" and "the user said
  no". **Everything else stays `.unknown` on purpose** — blaming a permission
  for an unrelated failure sends the user to Settings to fix what is not
  broken.
- **Verified on device 7 Sept 2026: pairing on a fresh install is smooth.** The
  alert now arrives with the sheet and is answered before there is a code, so
  the failure that started this never happens. Two things that confirmation
  does *not* cover, because a successful prime means neither runs: the
  wait-and-retry path, and the `-65555`/`-65570` refusal codes, which are
  reasoned from Apple's constants rather than observed. Forcing a denial to
  test them needs a privacy reset, and the only clean route to one is an
  uninstall — which wipes the app's Application Support and strands the device
  key on the host with no `PairedPeer` naming the line to revoke. Not worth it
  for a fallback whose failure mode is "behaves exactly as it did before".
- **`NSBonjourServices` is not optional here.** Without the declaration the
  browser is refused before the permission is ever consulted, so the app would
  conclude "blocked" and never retry. It names `_ssh._tcp`, which is honestly
  what Bleat connects to, and the string must match
  `LocalNetworkAccess.serviceType`.
- **`NSBonjourServices` lives in `Support/Info.plist`** — it is an array, which
  the generated set cannot express — alongside `CFBundleURLTypes`, which is not
  in that set either. `NSLocalNetworkUsageDescription` is an
  `INFOPLIST_KEY_` build setting on the app target. The pair is split, which
  this file previously argued against; the plist's own comment carries the
  explanation so the two halves are still findable from each other. Look in the
  project, not the plist, for the purpose string.
- **Only "nothing answered" is retried.** A host key mismatch or a refused key
  means a machine *was* reached, so waiting on a permission would hide what the
  user has to see. Retrying is safe because the enrollment key is spent only by
  a **completed** swap — an attempt that never reached the host consumed
  nothing — and `bleat pair` holds the code for five minutes, which is why the
  wait is capped at 60s.

## Unpairing (Phase 2)

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

### "Reached and refused" is not "could not reach"

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

## Endpoint selection on the phone

Try last-known-good first with a short timeout, then race the remaining
endpoints and keep whichever completes the SSH handshake first. Persist the
winner per peer.

**Off the local link, skip what cannot work — but a private address is only
unreachable *unaided*.** `Endpoint.Reach` used to have one `lan` case covering
both mDNS names and private addresses, and both were dropped the moment the
phone left Wi-Fi. They are now separate cases because a tunnel treats them
differently:

| reach | needs |
|---|---|
| `linkScoped` (`.local`, loopback, link-local) | the attached link, and **nothing carries these off it** |
| `privateAddress` (RFC1918, ULA) | the attached link **or** a tunnel routing that subnet |
| `overlay` (Tailscale CGNAT/ULA/`.ts.net`) | the tunnel |
| `routable` | nothing |

Dropping `privateAddress` on cellular is what made Twingate look unsupported:
that overlay reaches a host by its ordinary `192.168.x` address, so the single
endpoint that would have connected was discarded before it was dialled.

**Loopback and link-local are `linkScoped`, not `privateAddress`, and that
split is load-bearing.** A VPN routes `192.168.1.20`; none routes `127.0.0.1`,
`::1` or `fe80::1`, which name this device or this wire. Filed with the private
addresses, each would become a candidate the moment any tunnel came up and cost
a full TCP timeout in the race for a destination that cannot exist —
`127.0.0.1:2222` is not hypothetical, it is what this file's own throwaway-sshd
procedure uses, and endpoints can be added by hand. They stay usable *on* the
link, so `bleat redeem` against a loopback sshd still works.

**Nothing here asks which subnets a split-tunnel client has claimed**, because
nothing can — and it would still not answer for a private DNS name. Being wrong
towards trying costs one slot in a concurrent race; being wrong towards refusing
costs the connection. So a tunnel being up is enough.

**"Does this need a tunnel" is link-dependent, and only the caller can answer
it.** `Endpoint.needsTunnel(from:)` is a function rather than a property for
that reason: a mesh address always needs one, while a private address needs one
only off the link — on Wi-Fi it is simply the network the phone is standing on,
and a failure there means the host is asleep. `PeerConnection` computes
`endpoints.allSatisfy { $0.needsTunnel(from: link) }` and hands the verdict to
`PeerConnector.failure` as `everyCandidateNeedsATunnel`.

- It stays a **parameter**, not a computation inside `PeerConnector`, for the
  reason the old `droppedUnroutable` flag existed: pairing hands the connector a
  deliberately narrowed list — one endpoint, the one that just carried the
  enrollment handshake — where every candidate is trivially a tunnel address. A
  self-derived condition would tell the user to check a VPN that had
  demonstrably just worked, at the moment the enrollment key may already be
  spent.
- **An earlier version passed `!link.onLocalLink` and lost a case.** A peer
  whose only endpoint is a Tailscale address, reached from Wi-Fi with the tunnel
  off, is exactly when the VPN advice is right — and exactly when that flag
  suppressed it, sending the user to check a Wi-Fi network that was working.

**The ruled-out message distinguishes the two kinds too.** Off the link with no
candidates left, "connect a VPN that routes it" is right for a peer with a
private address and wrong for one known only by its `.local` name — no tunnel
carries multicast, so that would send the user to set up something that could
never work. `bleat inspect`'s LAN-only note branches the same way.

**Unverified on device, and the blast radius is wider than a missed VPN.**
`NWInterface.InterfaceType.other` is documented as "virtual or otherwise
unknown", not "VPN", and iOS can have `utun` interfaces up for iCloud Private
Relay or an idle on-demand profile. If the monitor reports satisfied without a
tunnel that routes anything useful, `tunnelActive` is stuck true and the
cellular filter stops discarding private addresses at all: a LAN-only peer on
cellular goes from an instant "only reachable on its local network" to a full
TCP timeout per RFC1918 candidate, since cellular black-holes those rather than
refusing them. Shipped that way deliberately — the alternative is the bug being
fixed, and the failure is *slow* rather than *wrong*, since `overlayUnreachable`
still names the right remedy (reaching a LAN-only host from cellular does take a
VPN, whether or not one is up). **Wants measuring on a real phone, on cellular,
with and without the tunnel.**

Whichever endpoint wins, the host key is still checked against the peer's pin.
The endpoint is a hint; the key is the identity.
