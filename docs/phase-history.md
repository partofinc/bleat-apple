# Phase history: how the Phase 2 gate was met (7 Sept 2026)

> Moved verbatim from `CLAUDE.md` on 1 Oct 2026. Where the text says "this file", "above" or "below", it means the old single file; a **bold** section name can be found with `grep -r docs/`.

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

**Runs on a real phone over Tailscale — verified 7 Sept 2026, and this closes
the Phase 2 gate.** Paired and connected from an iPhone **on cellular with
Wi-Fi off**, which is the test that matters: on Wi-Fi the LAN endpoints are
live and usually win the race, so a success there proves nothing about the
tunnel. With Wi-Fi off there is nothing left to win but the overlay address.

**It did not work the way this file claimed, and the difference matters.** The
old text said `bleat pair` detects Tailscale by running `tailscale status
--json` for `Self.DNSName` and `Self.TailscaleIPs`, and called that "written and
unverified" — the last item on the gate. **It had never been written.** What
made Tailscale work was `ifconfig`: the tunnel's `utun` interface holds the
addresses and they pass every filter, and `Endpoint.reach` classifies them.

The CLI **is** consulted now, for the one thing no interface carries — the
MagicDNS name. See the endpoint list under **A peer is a host key, not an
address**. `bleat inspect` on this Mac with the tunnel up:

```
rawillkair.local                           lan       — same network only
192.168.11.54                              lan       — same network only
100.114.119.30                             overlay   — works over the tunnel
[fd7a:115c:a1e0::42a:771f]                 overlay   — works over the tunnel
rawillk.tail2a3bab.ts.net                  overlay   — works over the tunnel
```

**The classification is the load-bearing part.** Tailscale's CGNAT range is not
RFC1918 and its v6 range is a ULA, so the ordinary private-address tests call
both private — and `endpointsToTry` drops private addresses the moment the
phone leaves Wi-Fi. That would discard the one endpoint that works. `reach`
matches the two Tailscale ranges *before* the private checks for exactly this
reason.

**A stored Tailscale address survives reconnects on both ends.** The
`100.64.0.0/10` and `fd7a:115c:a1e0::/48` addresses are assigned by the control
plane and bound to the node's identity rather than its session, so they persist
across logout, reboot, and moving between networks. What does invalidate one is
removing the machine from the tailnet and re-adding it, or re-registering it as
a new node: that is a new node record with a new address, and since endpoints
are captured at pair time and never re-discovered, it costs a re-pair.

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

## Must ship before any release

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
