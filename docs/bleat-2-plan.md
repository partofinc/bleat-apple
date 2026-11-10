# Bleat 2.0 — moving the engine to herdr-core (`hc`)

Status: **draft for review**, 10 Nov 2026. Nothing here is built yet. Once it
is agreed, the phase table goes into `CLAUDE.md` and this file becomes the
running record for the move, the way `phase-history.md` is for 1.x.

## Why

Bleat 1.x drives the herdr TUI through its CLI: one SSH exec channel per
command, a separate NDJSON channel per pane, and list polling. herdr-core
(`hc`) is the terminal runtime under the new Herdr desktop app. It speaks
JSON-RPC 2.0 over a single stream, publishes an OpenRPC schema "for app
builders", and pushes changes as events. Bleat 2 talks to `hc` only.

**Decided:** a full transition, no dual backend. The herdr TUI client code is
deleted in Phase B, not kept behind a switch.

## What `hc` gives us (verified on this Mac, hc 0.1.19)

Re-verify before relying on any of it; the host wins over this file.

- **One connection.** `hc connect [--session S]` speaks the protocol on
  stdin/stdout: one Citadel exec channel per host replaces every per-command
  channel and the pane-stream channel. Locally the core listens on
  `~/.local/state/herdr-core/<session>/<session>.sock`.
- **JSON-RPC 2.0, one message per line.** `hello` returns `generation: 1`,
  the feature list (`framed`, `attach`, `events`, `status`, `shell`,
  `resize_notifications`, `automatic_input`) and the methods.
- **`hc schema --json`**: OpenRPC 1.3.2, 32 methods, Apache-2.0. This becomes
  `Fixtures/schema.json`. Errors carry a stable `data.kind`.
- **Events, not polling.** `events.subscribe` sends a snapshot, then every fact
  change in order (created, lost, restarted, keep, finished, removed, status,
  turn, title, labels, size, doc), a `heartbeat` every 15 s, and `missed` plus
  a fresh snapshot for a subscriber that fell behind. It filters by
  `terminal`, `labels` or `children_of`.
- **Status is first-class**: `working | blocked | done | idle` on every
  terminal. That is the attention sort Bleat already uses.
- **Attach** works on a framed connection only (`hello` with `framed: true`),
  returns a channel, sends a first paint, then live PTY bytes. Its parameters:
  `cols`/`rows`, `observe` (watch only: never type or resize), `history`
  (scrollback lines painted first, main screen only), `display` (the viewer's
  colors and cell size, for answering display queries), `resumed` (back after
  a dropped line), `resize_notifications`.
- **Control without attaching**: `terminal.send` (paste and Enter),
  `terminal.keys` (`enter`, `esc`, `up`, `ctrl+c`…), `terminal.interrupt`,
  `terminal.read` (screen plus `lines` of history, as text).
- **Creating**: `terminal.run` takes argv, a shell `line`, or a template name
  plus a task, which it sends once the agent is ready. `templates.list` lists
  them. `--bg --json` returns `address` (like `t4p`), not `id`.
- **Machines**: one core federates others (`machine.list`; `on` parameter;
  addresses like `adam/t7`).
- **Docs**: `doc.get`/`doc.set`, versioned JSON up to 1 MiB, compare-and-set.

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

## Architecture

- **`HcKit`**, the protocol layer: either a new package target or BleatKit's
  domain layer rewritten in place (open question 14). It holds:
  - the line codec, and the framed codec for attach;
  - Codable models derived from `hc schema` (unknown keys ignored, never
    fatal — the same rule as now);
  - `HcTransport`, a byte duplex. Implementations: `SSHConnectTransport`
    (Citadel exec `hc connect`), `UnixSocketTransport` (console tool and
    tests), and `RelayTransport` for the watch;
  - `HcClient`: id-matched requests, an `events` stream, and
    `attach(t) -> TerminalStream` (bytes in; keys and resize out). It can be
    reused after a transport failure: reconnect, `hello`, re-subscribe,
    re-attach. The first paint keeps re-attach the recovery path.
- **`HerdrAppConventions`**: one adapter that rebuilds spaces and tabs from
  Herdr.app's labels and doc. Nothing else reads `herdr.*` labels.
- **Domain mapping:**

  | Bleat 1.x (herdr TUI) | Bleat 2 (hc) |
  |---|---|
  | session (`HERDR_SESSION`) | hc session (`--session`), or just the host's core |
  | workspace | space (label `herdr.space`, via the adapter) |
  | tab | tab (label `herdr.tab`, via the adapter) |
  | agent / pane (`w2:p1`) | terminal (`t4m`, `adam/t4m`) |
  | agent state | `status` |
  | `agent list` polling | `events.subscribe` |
  | `agent prompt` | `terminal.send` |
  | key bar input | DATA on the attach channel, or `terminal.keys` |
  | `terminal session control --takeover` | `terminal.attach` (active, or `observe`) |
  | `terminal.scroll` | `history` on attach and/or `terminal.read` (open question 5) |
  | agent / workspace create | `terminal.run`, `templates.list` |

- **Deleted in Phase B:** `HerdrClient`, the herdr models and CLI fixtures,
  NDJSON `terminal.frame` decoding, session-by-environment selection, and
  `docs/herdr-facts.md` (archived, not edited).

## Phases

| Phase | Deliverable | Gate to next phase |
|---|---|---|
| **A — Pipe** | `HcKit` and the console tool on it. `docs/hc-facts.md`, with the frame format. Fixtures captured from `hc schema` and live replies. | From a Mac terminal, over SSH `hc connect` to a Pi: hello, subscribe and print live events, list spaces and terminals, attach and see live frames, send keys, resize, detach cleanly, survive a dropped connection. No UI code. |
| **B — App on hc** | The existing screens on `HcKit`: events instead of polling, pane view on attach, key bar, composer, creating. The herdr backend is deleted. The watch relay is ported. | Every 1.x screen works on a real phone over Tailscale, against both the Mac core and a Pi. Sessions on the watch work. |
| **C — New capabilities** | Federated machines in the host list, templates when creating, anything else hc enables that we choose to take. | Agreed scope only; each item listed before work starts. |
| **D — Release 2.0** | Demo host rebuilt on `hc`, docs and README updated, App Store listing and review notes revised, TestFlight. | Approved on the App Store as 2.0, same listing. |

Out of scope until after D: the same list as for 1.x (pairing/relay
transport, push notifications, Live Activities).

## Open questions

Each one is resolved against the live host (or by Ravil, where marked),
written into `docs/hc-facts.md` or the relevant area doc, then struck from
here. **Must be closed before:** the phase named.

### Product (Ravil decides)

1. **Existing 1.x users on the herdr TUI.** A 2.0 that speaks only `hc` stops
   working for anyone still running the TUI the moment it auto-updates.
   Options: accept the break and say so in the release notes; keep 1.x on the
   store as a separate app; or require hc and refuse an old host with a clear
   message at connect. *Before D; better before B.*
2. **Name and positioning.** "Bleat for Herdr" still fits if Herdr is the
   umbrella for the app and hc. Does the listing, or the "zero host setup
   beyond Herdr itself" promise, need new words when the host is a bare `hc`
   on a Pi? *Before D.*
3. **Which phase is current.** 1.x Phase 3 (Control) still lists unbuilt items
   (Ctrl and y/n keys, the takeover indicator). Are they dropped, or carried
   into Phase B? *Before A starts.*

### Protocol (verify on the host)

4. **The attach frame layout is not in the schema.** Header, kind numbering
   (DATA, RESIZE, FOCUS, FACTS, CREDIT, CLOSE, `automatic_input` = 6), and
   credit flow control: what is the window, and what happens to a viewer that
   stops granting credit (the phone suspended mid-stream)? Get it from
   herdr-core's source or by observing `hc attach`, and write it down before
   any code. *Before A.*
5. **Scrolling.** herdr carried one viewport and scrolled with
   `terminal.scroll`, handed to the program as a wheel event. hc offers
   `history` on attach and `terminal.read --lines`. Is there a live scroll
   in the stream, or is scrolling Bleat's own job over that history? What
   happens on the alternate screen (Claude Code, `htop`), where `history`
   does not apply? *Before B.*
6. **Input ownership and size.** In 1.x, layout is the stream's size and a
   resize reaches someone's Mac. With hc: how many active (non-`observe`)
   viewers can a terminal have, who wins the size when the Mac's Herdr.app and
   the phone are both attached, and what do `resize_notifications` and
   `resumed` change? This decides whether "always takeover" survives, and
   whether opening a pane on the phone still reflows the Mac. *Before B.*
7. **What clears `done`.** In herdr, `done` means "finished, and nobody has
   looked", and `agent focus` clears it. Does attaching, `terminal.read`, or
   the `herdr.seen` label clear it in hc? Bleat must not mark things seen just
   by listing them. *Before B.*
8. **Which terminals have a status.** herdr recognised agents from their
   screens. Does hc report `working`/`blocked` for an agent started outside a
   template, or for a plain shell? What decides what Bleat calls an "agent"
   and what it calls a terminal? *Before B.*
9. **Readiness when creating.** herdr had `agent_not_ready`. `terminal.run`
   with a template waits until the agent is ready before sending the task.
   What does it return or raise when the agent never becomes ready, and how
   long does it wait? *Before B.*
10. **Display queries.** `display` on attach and run answers programs that ask
    the terminal's colors and cell size. What should the phone send, and does
    it change when the phone switches between light and dark mode? *Before B.*
11. **Reconnect.** After iOS drops the socket: are re-`hello`, re-subscribe and
    re-attach with `resumed: true` enough? Does a `missed` snapshot cover
    everything we lost, or do we diff it against what we hold? *Before A
    (gate).*
12. **Version floor and drift.** hc is 0.1.x and protocol `generation: 1`.
    What is the minimum hc version Bleat accepts, how is it checked (at
    `hello`, and at pairing in `HostInspector`), and what does the app say on
    an older or newer core? *Before B.*
13. **Isolated scratch cores for testing.** `hc connect --session` and
    `HC_SESSION` exist. Confirm a scratch session gets its own core and
    socket, sharing nothing with the default one, so tests never touch live
    terminals. This replaces the "never the `work` session" rule. *Before A.*

### Architecture (decide while building)

14. **New package or rewrite in place.** `HcKit` as a new target beside
    `BleatKit`, or BleatKit's domain layer replaced in place? Renaming is
    churn; a new target keeps the macOS-client option clean. *Before A.*
15. **The spaces and tabs convention.** `herdr.space`, `herdr.tab`, `where`
    and `herdr.seen` are Herdr.app's labels, and tab and space names live in
    a core doc whose name is unconfirmed (`~/.config/herdr-app/herdr.d.ts`
    declares `TabInfo` and `SpaceInfo`). Is that convention stable and public?
    Ask upstream. What does Bleat show for a core with no Herdr.app at all —
    a Pi, the demo host — where no terminal carries these labels? *Before B.*
16. **Sessions.** Does Bleat 2 show hc sessions at all, or only the default
    core, until someone asks? 1.x built screens for starting, stopping and
    deleting herdr sessions (`docs/creating-from-the-phone.md`). *Before B.*
17. **Federated machines versus paired hosts.** If the Mac's core federates
    adam and the phone has also paired adam directly, the same terminals
    appear twice. Is core identity (from `hello`) enough to merge them, and
    which route does the app prefer? *Before C.*
18. **The watch relay's shape.** `RelayTransport` relays `run` and
    `openStream` today. With a single JSON-RPC stream and framed channels,
    does the phone relay whole requests and event slices (the watch never
    attaches), or the byte stream? The first is simpler and probably enough
    for what the watch shows. *Before B.*
19. **Host info and the load bar.** The host screen's stored info and live
    load bar come from commands over SSH today. Do they move to
    `machine.exec`/`server.status` on the same connection, or stay as their
    own exec? *Before B.*
20. **Licensing.** The schema is Apache-2.0. Confirm that vendoring it as a
    fixture, and deriving models from it, needs only a notice. *Before A.*

## Testing safety

Never experiment on Ravil's live terminals or agents. Use an isolated scratch
session (question 13) or, failing that, scratch terminals
(`hc run --bg --name bleat-scratch-…`) cleaned up with `hc kill` and `hc rm`.
The scratch-sshd recipe in `docs/testing.md` still applies to pairing.
