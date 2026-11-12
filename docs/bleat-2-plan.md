# Bleat 2.0 — moving the engine to herdr-core (`hc`)

Status: **draft for review**, 10 Nov 2026. Nothing here is built yet. Once it
is agreed, the phase table goes into `CLAUDE.md` and this file becomes the
running record for the move, the way `phase-history.md` is for 1.x. Facts
about `hc`, with their sources, are in [`hc-facts.md`](hc-facts.md).

## Why

Bleat 1.x drives the herdr TUI through its CLI: one SSH exec channel per
command, a separate NDJSON channel per pane, and list polling. herdr-core
(`hc`) is the terminal runtime under the new Herdr desktop app. It speaks
JSON-RPC 2.0 over a single stream, publishes an OpenRPC schema "for app
builders", and pushes changes as events. Its source is public
([herdrdev/herdr-core](https://github.com/herdrdev/herdr-core), Apache-2.0),
and so is Herdr.app's
([herdrdev/herdr-app](https://github.com/herdrdev/herdr-app)). Bleat 2 talks
to `hc` only.

**Decided:** a full transition, no dual backend. The herdr TUI client code is
deleted in Phase B, not kept behind a switch.

## What `hc` gives us (hc 0.1.19 on this Mac; 0.1.18 on the Pis)

Re-verify before relying on any of it; the host wins over this file.

- **One connection, framed.** `hc connect [--session S]` speaks the protocol
  on stdin/stdout: one Citadel exec channel per host replaces every
  per-command channel and the pane-stream channel. It has to be **framed**: in
  plain line mode, a connection that subscribes to events "now carries only
  notifications". In framed mode, JSON-RPC runs on channel 0, events on their
  own channel, and each attach on its own. Locally the core listens on
  `~/.local/state/herdr-core/default/default.sock`. Only `default` has been
  observed; that other sessions follow the same pattern is an assumption.
- **JSON-RPC 2.0.** `hello` returns `generation: 1`, the feature list
  (`framed`, `attach`, `events`, `status`, `shell`, `resize_notifications`,
  `automatic_input`) and the methods.
- **`hc schema --json`**: OpenRPC 1.3.2, 32 methods. This becomes
  `Fixtures/schema.json`. Errors carry a stable `data.kind`.
- **Events, not polling.** `events.subscribe` sends a snapshot, then every fact
  change in order (created, lost, restarted, keep, finished, removed, status,
  turn, title, labels, size, doc), a `heartbeat` every 15 s, and `missed` plus
  a fresh snapshot for a subscriber that fell behind (with a `seq` to drop
  stale events). It filters by `terminal`, `labels` or `children_of`.
- **Status is first-class**, for programs that report it (OSC 7501): `idle`,
  `working`, `done`, `blocked`, `error`. `blocked` has a reason (permission,
  question, auth); `working` and `blocked` have an optional progress. Plain
  shells have no status.
- **Attach** sends a first paint, then live PTY bytes, with credit flow
  control. It takes `cols`/`rows`, `observe` (watch only), `history`
  (scrollback painted first, main screen only), `display`, `resumed` and
  `resize_notifications`. A viewer that falls 4 MiB behind gets a repaint, not
  a disconnect.
- **Control without attaching**: `terminal.send` (paste and Enter),
  `terminal.keys` (`enter`, `esc`, `up`, `ctrl+c`…), `terminal.interrupt`,
  `terminal.read` (screen plus `lines` of history, as text).
- **Creating**: `terminal.run` takes argv, a shell `line`, or a template name
  plus a task, which it sends once the agent is ready. It also takes `env`,
  `size`, `no_parent`, `no_notify` and `outlive_parent`. `templates.list`
  lists templates. `--bg --json` returns `address` (like `t4p`), not `id`.
- **Machines**: one core federates others (`machine.list`; `on` parameter;
  addresses like `adam/t7`).
- **Docs**: `doc.get`/`doc.set`, versioned JSON up to 1 MiB, compare-and-set.
  There is no `doc.list`.

## Already settled

- **`hc` runs standalone on Linux.** It runs as its own server on adam and the
  other Pis, the same way the herdr TUI server does. The demo host and the Pis
  need no Herdr.app. *(Closed by Ravil, 10 Nov 2026.)*
- **Finding `hc` over non-interactive SSH is an existing, solved problem.** It
  lives in `~/.local/bin`, which a non-login shell does not have on `PATH`.
  This is the same trap as herdr (`docs/ssh-transport.md`), and the same fix
  applies: resolve the path through a login shell, store it on the peer
  (`herdrPath` becomes `hcPath`), and keep it out of the QR
  (`docs/pairing.md`).
- **Kept as is:** Citadel and the SSH layer, all of pairing (QR, enrollment
  key, Tailscale discovery, unpairing, `bleat keys`), the console tool's
  releases (Homebrew, static Linux), BleatUI's screens, SwiftTerm, and the
  watch relaying through the phone.
- **No new third-party dependencies.** The JSON-RPC and frame codecs are ours.
- **The protocol layer stays UI-free.** No UIKit, SwiftUI or SwiftTerm in it,
  so a native macOS `hc` client could share it later.
- **Licensing.** herdr-core is Apache-2.0: vendoring its schema as a fixture
  and deriving models from it needs a notice, nothing more.

## Architecture

- **`HcKit`**, the protocol layer: either a new package target or BleatKit's
  domain layer rewritten in place (open question 14). It holds:
  - the frame codec (`hc-facts.md`) and the JSON-RPC codec on channel 0.
    **HcKit goes framed straight after `hello`** and uses that for
    everything: requests, events and attach;
  - Codable models derived from `hc schema` (unknown keys ignored, never
    fatal — the same rule as now);
  - `HcTransport`, a byte duplex. Implementations: `SSHConnectTransport`
    (Citadel exec `hc connect`), `UnixSocketTransport` (console tool and
    tests), and `RelayTransport` for the watch;
  - `HcClient`: id-matched requests, an `events` stream, and
    `attach(t) -> TerminalStream` (bytes in; keys and resize out), each on its
    own channel with credit. It can be reused after a transport failure:
    reconnect, `hello`, re-subscribe, re-attach with `resumed`. The first paint
    keeps re-attach the recovery path.
- **`HerdrAppConventions`**: one adapter that rebuilds spaces and tabs from
  Herdr.app's labels and doc. Nothing else reads `herdr.*` labels, and nothing
  writes them unintentionally.
- **Domain mapping:**

  | Bleat 1.x (herdr TUI) | Bleat 2 (hc) |
  |---|---|
  | session (`HERDR_SESSION`) | hc session (`--session`), or just the host's core |
  | workspace | space (label `herdr.space`, via the adapter) |
  | tab | tab (label `herdr.tab`, via the adapter) |
  | agent / pane (`w2:p1`) | terminal (`t4m`, `adam/t4m`) |
  | agent state | `status` (adds `error`, blocked reason, progress) |
  | `done` cleared by `agent focus` | client-side "seen", probably `herdr.seen` vs `turn` (question 7) |
  | `agent list` polling | `events.subscribe` |
  | `agent prompt` | `terminal.send` |
  | key bar input | DATA on the attach channel, or `terminal.keys` |
  | `terminal session control --takeover` | `terminal.attach`: the most recent active viewer wins; `observe` for read-only |
  | `terminal.scroll` | `history` on attach and/or `terminal.read` (question 5) |
  | agent / workspace create | `terminal.run` with **`no_parent: true`, `no_notify: true`**, SwiftTerm's identity in `env` and the phone's grid in `size`; `templates.list` |

- **Deleted in Phase B:** `HerdrClient`, the herdr models and CLI fixtures,
  NDJSON `terminal.frame` decoding, session-by-environment selection, and
  `docs/herdr-facts.md` (archived, not edited).

## Phases

| Phase | Deliverable | Gate to next phase |
|---|---|---|
| **A — Pipe** | `HcKit` (the framed codec from the start, not only for attach) and the console tool on it. `docs/hc-facts.md` verified live. Fixtures captured from `hc schema` and live replies. | From a Mac terminal, over SSH `hc connect` to a Pi, on **one framed connection**: hello, subscribe and print live events while sending requests, list spaces and terminals, attach and see live frames, send keys, resize, detach cleanly, survive a dropped connection. No UI code. |
| **B — App on hc** | The existing screens on `HcKit`: events instead of polling, pane view on attach, key bar, composer, creating. The herdr backend is deleted. The watch relay is ported. | Every 1.x screen works on a real phone over Tailscale, against both the Mac core and a Pi. A terminal created from the phone keeps running after the phone disconnects. Viewing on the phone does not clear the Mac's `done`. Sessions on the watch work. |
| **C — New capabilities** | Federated machines in the host list, templates when creating, anything else hc enables that we choose to take. | Agreed scope only; each item listed before work starts. |
| **D — Release 2.0** | Demo host rebuilt on `hc`, docs and README updated, App Store listing and review notes revised, TestFlight. | Approved on the App Store as 2.0, same listing. |

Out of scope until after D: the same list as for 1.x (pairing/relay
transport, push notifications, Live Activities).

## The migration gate (built 12 Nov 2026)

The first Bleat 2 change. It keeps 1.x's peers and moves each one through a
check before any hc screen uses it.

- **The check** (`HerdrCoreCheck`): `PeerConnection.open` — the 1.x endpoint
  race, host key pin and device key, without resolving `herdr`, since a host
  that has moved to hc may no longer have it. Then two commands:
  `${SHELL:-/bin/sh} -lc 'command -v hc' || true` (the `HerdrLookup` pattern),
  and `'<path>' --version`, which must print `hc <version>`. The connection
  is closed before the check returns.
- **The login shell misses `~/.local/bin` on a Mac.** Found on the first
  phone run, 12 Nov 2026: this Mac read "Install herdr-core" with hc 0.1.20
  installed, because `~/.local/bin` is added to `PATH` in `.zshrc`, which
  `zsh -lc` does not read (`herdr` was still found, in `/opt/homebrew/bin`
  from `.zprofile`). The Pis were fine: Debian's `.profile` adds it. So when
  `PATH` has no `hc`, the check also tries `$HOME/.local/bin/hc`, where
  Herdr.app installs it, and `--version` still decides.
- **The answer is stored on the peer** as `PairedPeer.herdrCore`:
  `.installed(path, version)` or `.missing`. Nil on every 1.x record until
  checked; old records decode. It reaches the watch with the mirrored list.
  An unreachable host said nothing, so that is held in memory for one run.
- **When it runs** (`HerdrCoreReadiness`): on the host list's first
  appearance, on pull-to-refresh, on every return to the foreground, and from
  the gate screen's Check Again. Only peers not yet installed are asked, all at
  once. A ready peer is never asked again.
- **What the user sees:** a ready host's row is unchanged. Otherwise the
  detail line reads "Install herdr-core", "Not reachable", "Check failed" (a
  problem on the phone: its key, or saving the answer) or, only while a check
  is really running, "Checking for herdr-core…". A host paired while the app
  is open is checked straight away.
- **Cancelled is not an answer.** A check cancelled part way (the list's task
  ending as a phone's split view collapses) records nothing. It was once read
  as "missing" and stored, telling the user to install hc they had.
- **The version line may say more.** `hc <digit…>` is enough; words after it
  are ignored, so a later hc's longer `--version` does not read as missing. Opening a host shows `HerdrCoreGateView`: the reason and Check
  Again, or, for a ready host, a placeholder until the hc terminal screens
  land. The 1.x session screens stay in the code, unreachable, until those
  screens replace them.
- **Verified:** the lookup command on adam (Debian, hc 0.1.18) found
  `/home/pi/.local/bin/hc` and answered empty for a missing tool with exit 0.
  `hc --version` reads `hc 0.1.20` on the Mac (`Fixtures/hc-version.txt`) and
  `hc 0.1.18` on adam. Not yet run end to end from a phone.
- **Not handled yet:** a ready host whose `hc` later moves or is removed. The
  hc client's first failed connect is the place to re-check.

## Open questions

Each one is resolved against the live host or the source (or by Ravil, where
marked), written into `hc-facts.md` or the relevant area doc, then struck
here. **Must be closed before:** the phase named.

### Product (Ravil decides)

1. ~~**Existing 1.x users on the herdr TUI.**~~ Decided by Ravil, 12 Nov
   2026: **keep every peer and gate it.** Nothing is re-paired. At launch each
   peer is checked for `hc` over the SSH path it already uses, and marked
   ready, "Install herdr-core" or "Not reachable". A host without hc is not
   refused at pairing yet (that is the pairing PR); it is held at the gate.
   See "The migration gate" below. Sessions and workspaces are dropped:
   Bleat 2 shows what hc has.
2. **Name and positioning.** "Bleat for Herdr" still fits if Herdr is the
   umbrella for the app and hc. Does the listing, or the "zero host setup
   beyond Herdr itself" promise, need new words when the host is a bare `hc`
   on a Pi? *Before D.*

   **The field, 12 Nov 2026.** Herdr has its own phone app, Herdr Mobile
   (`dev.herdr.mobile`, found on Google Play; not open source — herdrdev's
   repos are herdr, herdr-nix, herdr-core, herdr-app and layout examples). It
   takes a terminal over on open much as Bleat 2 does, which supports that
   choice. It connects to a host by a typed hostname, IP or tailnet address,
   username and port; with Ravil's hosts entered by tailnet name it works only
   over Tailscale. Third-party iOS clients exist too: herdrup (Apache-2.0,
   SSH), Heeler for herdr (open source, SSH jump hosts), Herdy (paid, SSH and
   Mosh).
   Where Bleat is ahead, already built: **simplicity** — pair once from a QR,
   no address typing — and **durability** — each peer holds every address the
   host reports (LAN, `.local`, tailnet name and IPs, anything added by hand),
   races them, keeps the first that answers, skips what cannot work from where
   the phone is, and refreshes them after each connection; the same peer works
   at home without Tailscale and away with it.
   Worth knowing when testing: two phone viewers on one terminal (Herdr Mobile
   and Bleat) trade its size back and forth, since hc follows the latest
   active viewer.

3. **Which phase is current.** 1.x Phase 3 (Control) still lists unbuilt items
   (Ctrl and y/n keys, the takeover indicator). Are they dropped, or carried
   into Phase B? *Before A starts.*

### Protocol

4. ~~**The attach frame layout.**~~ Answered from `wire.rs`; see
   `hc-facts.md`. Verify live in Phase A.
5. **Scrolling.** *Built 12 Nov 2026 as wheel clicks or local history; see
   `pane-view.md`. Left open: whether it feels right on Claude Code.* herdr carried one viewport and scrolled with
   `terminal.scroll`, handed to the program as a wheel event. hc offers
   `history` on attach and `terminal.read --lines`, and `viewers.rs` mentions
   "a read scrolls the app". Is there a live scroll, or is scrolling Bleat's
   own job over that history? What happens on the alternate screen (Claude
   Code, `htop`), where `history` does not apply? *Before B.*
6. ~~**Input ownership and size.**~~ Answered from `viewers.rs`: several active
   viewers; the most recent to type, resize or focus sets size and colors;
   `observe` is read-only. **Left open:** does attaching with `cols`/`rows`
   count as a resize, so that merely opening a pane on the phone reflows the
   Mac? And should the phone attach with `observe` until the user types?
   *Before B.*
7. **What clears `done`.** hc never clears it (`status.rs`); "done and not yet
   looked at" is the client's idea. **Live, 12 Nov 2026:** `herdr.seen` holds
   the turn last looked at, and the list reads `seen < turn` as unseen. Probably Herdr.app keeps the last turn
   someone looked at in `herdr.seen` and compares it with `turn`. Confirm in
   herdr-app's source, then decide whether Bleat reads it, writes it
   deliberately when the user opens a terminal, or keeps its own. *Before B.*
8. ~~**Which terminals have a status.**~~ Answered: only programs that report
   OSC 7501; plain shells have `null`. **Left open:** how the UI shows
   terminals with no status, and where `error` sorts (with `blocked`, as the
   core treats them). *Before B.*
9. **Readiness when creating.** herdr had `agent_not_ready`. `terminal.run`
   with a template waits until the agent is ready before sending the task.
   What does it return or raise when the agent never becomes ready, and how
   long does it wait? *Before B.*
10. **Display queries.** `display` on attach and run answers programs that ask
    the terminal's colors and cell size; `env` and `size` on run carry the
    terminal identity and grid. What exactly does the phone send, and does
    `display` change when the phone switches between light and dark mode?
    *Before B.*
11. **Reconnect.** Partly answered: drop events at or below a `missed`
    snapshot's `seq`; `resumed: true` sets the size only once the viewer is
    active again. **Left open:** after iOS drops the socket, do we diff the
    fresh snapshot against what we hold, and does a re-attach with
    `resumed` avoid reflowing the Mac? *Before A (gate).*
12. **Version floor and drift.** Drift already exists: the Pis run 0.1.18, the
    Mac 0.1.19. What is the minimum hc version Bleat accepts, how is it checked
    (at `hello`, and at pairing in `HostInspector`), and what does the app say
    on an older or newer core? *Before B.*
13. **Isolated scratch cores for testing.** `hc server` takes no session
    option; sessions are chosen only by `--session`/`HC_SESSION` on the
    client. Does a scratch session get its own core and socket, sharing nothing
    with the default one? Check `paths.rs` and `server.rs`. This would replace
    the "never the `work` session" rule. *Before A.*

### Architecture (decide while building)

14. **New package or rewrite in place.** `HcKit` as a new target beside
    `BleatKit`, or BleatKit's domain layer replaced in place? Renaming is
    churn; a new target keeps the macOS-client option clean. *Before A.*
15. **The spaces and tabs convention.** `herdr.space`, `herdr.tab`, `where`
    and `herdr.seen` are Herdr.app's labels, and tab and space names live in
    a core doc. There is no `doc.list`, so the adapter must know the doc's
    name: take it from `doc` events on `events.subscribe` or from herdr-app's
    source. Is the convention stable and public? Ask upstream. What does
    Bleat show for a core with no Herdr.app at all — a Pi, the demo host —
    where no terminal carries these labels? *Before B.*
16. **Sessions.** Does Bleat 2 show hc sessions at all, or only the default
    core, until someone asks? 1.x built screens for starting, stopping and
    deleting herdr sessions (`docs/creating-from-the-phone.md`). *Before B.*
17. **Federated machines versus paired hosts.** If the Mac's core federates
    adam and the phone has also paired adam directly, the same terminals
    appear twice. Is core identity (from `hello`) enough to merge them, and
    which route does the app prefer? *Before C.*
18. **The watch relay's shape.** `RelayTransport` relays `run` and
    `openStream` today. With one framed connection, does the phone relay whole
    requests and event slices (the watch never attaches), or frames? The
    first is simpler and probably enough for what the watch shows.
    *Before B.*
19. **Host info and the load bar.** The host screen's stored info and live
    load bar come from commands over SSH today. Do they move to
    `machine.exec`/`server.status` on the same connection, or stay as their
    own exec? *Before B.*
20. ~~**Licensing.**~~ Answered: Apache-2.0; see "Already settled".

## Testing safety

Never experiment on Ravil's live terminals or agents. Use an isolated scratch
session (question 13) or, failing that, scratch terminals
(`hc run --bg --name bleat-scratch-…`) cleaned up with `hc kill` and `hc rm`.
Never write `herdr.*` labels on a terminal that is not a scratch one. The
scratch-sshd recipe in `docs/testing.md` still applies to pairing.
