# Bleat — native iOS remote for Herdr

Bleat is a thin native client for [Herdr](https://herdr.dev). Bleat 2 talks to
**herdr-core (`hc`)**, the terminal runtime under the Herdr desktop app: it
shows a host's terminals sorted by attention state, renders a terminal live,
and lets the user answer approvals, send prompts and type into it from a phone.
herdr-core and the agents always run on the host; Bleat never owns a process.
App Store name: "Bleat for Herdr".

The product promise is **zero host setup beyond herdr-core itself**. The
transport is plain SSH: one `hc connect` exec channel per screen, speaking
herdr-core's framed JSON-RPC, plus plain shell for pairing and the host's load.
No daemon, no relay, no plugin on the host. **Bleat 1.x drove the herdr TUI's
CLI; that backend was removed on 12 Nov 2026**, and a host without hc lands on
"Install herdr-core".

## Current phase: Bleat 2, B — App on hc (in progress)

Bleat 2.0 moves the engine from the herdr TUI CLI to herdr-core (`hc`): one
framed `hc connect` stream per screen, events instead of polling. A full
transition with no dual backend. The plan, what is settled and the open
questions (each tagged with the phase it must close before) are in
[`docs/bleat-2-plan.md`](docs/bleat-2-plan.md); facts about `hc`, with their
sources, in [`docs/hc-facts.md`](docs/hc-facts.md).

**Built app-first, not console-first**, at Ravil's direction (12 Nov 2026):
the herdr-core gate for 1.x peers (#77); `HcClient` and a host's live terminal
list (#78); attaching to a terminal (#79); pairing on hc (#80); the herdr
backend removed. Phase A's console gate is met only in part — `bleat
terminals --watch` follows events; attaching from the console is not built.
**Left for B:** installing herdr-core from Bleat, creating terminals, and the
watch on hc. Two product questions are Ravil's before release: the listing's
name and promise, and whether 1.x's unbuilt Control items carry over.

| Phase | Deliverable | Gate to next phase |
|---|---|---|
| **A — Pipe** | `HcKit` (framed codec from the start, not only for attach) and the console tool on it. `docs/hc-facts.md` verified live. Fixtures captured from `hc schema` and live replies. | From a Mac terminal, over SSH `hc connect` to a Pi, on one framed connection: hello, subscribe and print live events while sending requests, list spaces and terminals, attach and see live frames, send keys, resize, detach cleanly, survive a dropped connection. No UI code. |
| **B — App on hc** | The existing screens on `HcKit`: events instead of polling, pane view on attach, key bar, composer, creating. The herdr backend is deleted. The watch relay is ported. | Every 1.x screen works on a real phone over Tailscale, against both the Mac core and a Pi. A terminal created from the phone keeps running after the phone disconnects. Viewing on the phone does not clear the Mac's `done`. Sessions on the watch work. |
| **C — New capabilities** | Federated machines in the host list, templates when creating, anything else hc enables that we choose to take. | Agreed scope only; each item listed before work starts. |
| **D — Release 2.0** | Demo host rebuilt on `hc`, docs and README updated, App Store listing and review notes revised, TestFlight. | Approved on the App Store as 2.0, same listing. |

Out of scope until after Phase D: pairing/relay transport (iroh or WebRTC),
push notifications, Live Activities, multi-account badges.

### Bleat 1.x (herdr TUI) — shipped; its backend removed in Bleat 2

Phase 1 met over real SSH. **The Phase 2 gate was met 7 Sept 2026**: paired
and connected from an iPhone on cellular with Wi-Fi off, over Tailscale.
Phase 3 shipped as 1.0 on the App Store. How each gate was verified, and what
that taught, is in [`docs/phase-history.md`](docs/phase-history.md).

| Phase | Deliverable | Gate to next phase |
|---|---|---|
| **1 — Pipe** ✅ | Platform-agnostic Swift package `BleatKit` + macOS console tool `bleat` | From a Mac terminal: connect over SSH, list sessions/workspaces/agents, attach to a pane, see live frames, send input, resize, detach cleanly. No UI code. |
| **2 — Read-only app** ✅ | Xcode project, SwiftUI iOS app | Hosts → session → workspaces → agents (blocked on top) → live pane view (SwiftTerm). No input yet. Runs on a real phone over Tailscale. |
| **3 — Control** ✅ 1.0 | Input + release | Keyboard with accessory row (Esc, Ctrl, Tab, arrows, y/n), prompt composer via `agent prompt`, takeover indicator, reconnect on foreground. TestFlight, then App Store. As built: arrows, Esc, Return and a shortcut menu, no Ctrl or y/n keys; always takeover, no indicator yet ([pane view](docs/pane-view.md)). |

**The watch app was started early, 1 Oct 2026, because it was asked for.** It
is the phone's screens over a relay through the phone — watchOS allows an app
no direct connection, so there is no SSH on the watch. See
[`docs/watch.md`](docs/watch.md).

**Must ship before any release** — both done: revoking a phone's key from the
host (`bleat keys`) and from the phone (unpairing). See
[`docs/console-tool.md`](docs/console-tool.md) and
[`docs/pairing.md`](docs/pairing.md).

## Where the detail lives

This file is the index. The measurements and the reasoning behind every
decision are in `docs/`, one file per area. **Read the file for the area you
are about to touch before changing it** — most of what is there is a bug that
shipped once, written down so it does not ship twice.

| file | covers |
|---|---|
| [`docs/bleat-2-plan.md`](docs/bleat-2-plan.md) | the 2.0 move to `hc`: what is settled, architecture, domain mapping, phases, open questions |
| [`docs/hc-facts.md`](docs/hc-facts.md) | herdr-core: framed mode and its frame layout, viewers and size, status, reconnect, creating terminals — each fact with its source |
| [`docs/ssh-transport.md`](docs/ssh-transport.md) | Citadel, host keys, clean detach (and 1.x's session selection by command prefix) |
| [`docs/pairing.md`](docs/pairing.md) | the enrollment-key swap, pairing another device from a paired one, peer identity, the QR, endpoint discovery and refresh, Tailscale, addresses by hand, local network permission, unpairing, endpoint selection |
| [`docs/app-screens.md`](docs/app-screens.md) | `ConnectionStore`, the herdr-core gate, the iPad split view, the host screen, what a host says about itself (stored info, the live load bar), previews, the pairing UI |
| [`docs/watch.md`](docs/watch.md) | the watch app: why it relays through the phone, `RelayTransport`, the phone's `WatchRelayHost`, the mirrored host list, what is and is not on the watch, driving a simulator with `DebugLaunch` |
| [`docs/pane-view.md`](docs/pane-view.md) | the terminal screen over hc (take over on open, the scroller), the key bar, typing, the keychain dead end, the repaint investigation — and 1.x's pane sizing, as history |
| [`docs/console-tool.md`](docs/console-tool.md) | `bleat` commands: `pair`, `redeem`, `keys`, `terminals`, and the `authorized_keys` anchoring rules |
| [`docs/repository-layout.md`](docs/repository-layout.md) | the full layout, why `BleatProcess` exists, the static Linux build, the SDK's ARMv8.1 allocator and what the port needed |
| [`docs/concurrency.md`](docs/concurrency.md) | Swift settings on both sides of the seam, the release-build gate, approachable concurrency and what is `@concurrent` |
| [`docs/app-icon.md`](docs/app-icon.md) | the icon, `Design/icon.swift`, and authoring a `.icon` by hand |
| [`docs/releasing.md`](docs/releasing.md) | the app's `v` tags and Xcode Cloud, the tool's `cli-` tags, `release-cli.sh`, `install.sh`, the Homebrew tap, signing |
| [`docs/demo-host.md`](docs/demo-host.md) | the demo host on Fly that App Review pairs with: the pairing page, why no agent runs there, why it is safe to hand out |
| [`docs/testing.md`](docs/testing.md) | a scratch hc terminal, a scratch sshd, testing pairing without touching your own keys |
| [`docs/phase-history.md`](docs/phase-history.md) | how each phase gate was verified |
| [`docs/archive/`](docs/archive/) | 1.x's herdr TUI backend: `herdr-facts.md`, `creating-from-the-phone.md` — the record, not the code |

## Repository layout

```
Bleat.xcodeproj             # project.xcproj (JSON format): two app targets; sources join via synchronized groups
App/                        # @main App struct and little else; icon and assets shared with the watch
Watch/                      # the watch app's @main, and nothing else
Design/icon.swift           # generates the icon's layers — run it, never edit the PNGs
Design/symbols.swift        # generates the custom SF Symbols — run it, never edit the SVGs
BleatKit/                   # the local Swift package
  Sources/
    BleatKit/               # domain + transport. No SwiftUI. Builds for iOS and watchOS.
    BleatUI/                # SwiftUI shared between app targets; MainActor by default
    BleatProcess/           # macOS and Linux only: local `hc connect`, pairing's host side, QR encoder
    bleat/                  # executable target, the console tool
  Tests/BleatKitTests/      # unit tests: frames, events, models, scripted cores
  Tests/BleatUITests/       # lays views out for real; needs a simulator
  Fixtures/                 # schema.json (hc's OpenRPC) + captured hc replies (source of truth)
Support/Info.plist          # the two keys that cannot be build settings
ci_scripts/ci_post_clone.sh # macro fingerprint defaults + `swift test` gate
Scripts/build-linux.sh      # the console tool for Linux: aarch64 (ARMv8.0 and up), or x86_64 (untried on hardware)
Scripts/release-cli.sh      # publishes the tool: GitHub release + Homebrew formula (docs/releasing.md)
Scripts/install.sh          # what users pipe into sh to install the tool
Demo/                       # the Fly demo host App Review pairs with (docs/demo-host.md)
docs/                       # the detail behind this file
```

## Rules that bite

Each of these shipped as a bug or cost a day. The why is in the linked doc.

- **Never experiment on the live terminals or agents.** Attaching takes a
  terminal's size and input lands in a real agent. Use a scratch terminal,
  started with **`--no-parent --no-notify`** — from inside an hc terminal,
  where this session runs, hc otherwise makes it a child and types its exit
  notes into the session. Never write `herdr.*` labels outside a scratch
  terminal: `herdr.seen` is the Mac's "done, not yet looked at" marker.
  ([testing](docs/testing.md))
- **A plain hc connection cannot subscribe and still take requests.** After
  `events.subscribe` it "carries only notifications". `HcClient` goes framed
  straight after `hello`. ([hc facts](docs/hc-facts.md))
- **A login shell misses `~/.local/bin` on a Mac.** zsh reads `.zprofile`,
  not `.zshrc`, for `-lc`, so `command -v hc` comes back empty where `hc`
  works in every terminal. The lookup also tries `~/.local/bin/hc`.
  ([plan](docs/bleat-2-plan.md))
- **Credit follows consumption, not arrival.** Granting it as bytes land in
  a buffer means a stalled consumer never fills the core's window and the
  buffer grows without limit. ([hc facts](docs/hc-facts.md))
- **An address is the full target** (`t58`; `adam/t8` for a federated
  machine's mirror, which the list leaves out). Build test data from
  `Fixtures/`, not from memory.
- **Attaching takes the terminal over at the phone's size**, and leaving gives
  it back to the Mac. Anything in a safe area that varies with state changes
  the grid and reflows the terminal on someone's Mac — the load bar is on the
  terminal list for that reason, never on a terminal. ([pane view](docs/pane-view.md))
- **The watch cannot open a socket, and the simulator lets it.** Anything
  the watch needs from a host goes through the phone as a `RelayRequest`; a
  direct connection works on every simulator and on no watch.
  ([watch](docs/watch.md))
- **`swift build` does not compile `BleatUI/Pane/`** — it is UIKit-only. Use
  `xcodebuild -scheme BleatKit-Package -destination 'generic/platform=iOS'`
  from `BleatKit/`, or the simulator test run.
- **Command-line `xcodebuild` passes `-derivedDataPath`** to a scratch
  directory, or it corrupts the DerivedData the open Xcode uses.
  ([layout](docs/repository-layout.md))
- **Build the Linux tool with `Scripts/build-linux.sh`, not a bare
  `swift build`.** The stock static SDK's allocator is ARMv8.1 code, and its
  binaries die with SIGILL before `main` on a Pi 4 or CM4.
  ([layout](docs/repository-layout.md))
- **Run the release build of `BleatUI` before an archive** (`swift build -c
  release --target BleatUI`, as `ci_post_clone.sh` does): an optimiser crash
  once failed only the archive. ([concurrency](docs/concurrency.md))

## Concurrency settings

`SWIFT_APPROACHABLE_CONCURRENCY` is on, on both sides: a `nonisolated async`
function runs on its caller's actor, so work that must leave the main actor
says `@concurrent`. The settings on each side, and why, are in
[`docs/concurrency.md`](docs/concurrency.md).

## Architecture rules

- **Transport is an interface.** Everything above it must not know it is SSH.
  ```swift
  protocol HcStreamOpening: Sendable {          // a byte stream to herdr-core
      func openHcConnection(hcPath: String) async throws -> any DuplexStream
  }
  protocol PeerLink: ShellRunner {              // a shell on the host, and letting go
      func disconnect() async
  }
  ```
  `DuplexStream` is stdout in (`AsyncThrowingStream<Data, Error>`), stdin out
  (`send(Data)`). `SSHTransport` implements both; `LocalHc` opens `hc connect`
  locally for the console tool; `RelayTransport` is the watch's `PeerLink`.
- **herdr-core's schema is the contract.** `BleatKit/Fixtures/schema.json` is
  `hc schema --json` (OpenRPC). Do not hand-invent fields; capture replies into
  `Fixtures/` and derive the models from them. Unknown keys are ignored, never
  fatal; a record that does not read is skipped, not fatal to the list.
- **Events are applied as herdr-core applies them.** `HcTerminalSet` keeps each
  terminal as its JSON record and sets keys per event exactly as `remote.rs`
  does, then reads `HcTerminal` out.
- **The terminal stream is bytes, not text.** An attach channel's DATA goes to
  SwiftTerm untouched. Never strip or interpret escape sequences in BleatKit.
- **The latest active viewer owns the size.** hc lets several viewers type;
  whoever typed, resized or focused last sets the grid. Bleat attaches active
  and takes over on open; closing the channel hands it back.
- **Reconnect is normal.** iOS will drop the socket. An `HcClient` is not
  reused after its stream ends: dial again, `hello`, re-subscribe, re-attach —
  the snapshot and the first paint rebuild everything.
- **Multiple channels, one connection.** The terminal list and an open terminal
  each run their own `hc connect` exec channel over one SSH connection.

## Conventions

- Swift 6.4 toolchain (Xcode 27.2; Xcode Cloud on 27.1), Swift 6 language mode, strict concurrency,
  `Sendable` everywhere in BleatKit.
- One type per file. Folders by feature, not by kind.
- `async/await` only; no Combine, no callbacks.
- Errors are typed: `HcError` (herdr-core said no), `ShellError` (a command
  ran and failed), `TransportError` (network), `DecodingError` (contract
  drift). Never swallow stderr.
- Tests use scripted cores and shells fed from `Fixtures/`. No test touches
  the network.
- Third-party dependencies: **Citadel** and **SwiftTerm**, both approved. Ask
  before adding a third. SwiftTerm is a real VT100/xterm emulator and there is
  no honest alternative: a terminal's bytes carry cursor positioning and
  synchronized-output markers inside them, so anything that approximated
  ANSI would render an agent's pane as nonsense. It is linked by `BleatUI`
  only — `BleatKit` stays free of rendering, and the console tool writes the
  same bytes to a terminal that already knows how to read them. It ships a
  build tool plugin; see `ci_scripts/ci_post_clone.sh`.
- Keep this file and `docs/` current. This file is the index — phase, rules,
  where things are. Verified facts and the reasoning behind decisions go in the
  `docs/` file for their area, updated in the same commit as the code. When
  the live host contradicts a doc, the host wins.

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
- **The package is named `BleatKit`, not `bleat`**, because macOS is
  case-insensitive and the old name put the package's build directory and the
  `Bleat` project's in one place. Two schemes still differ only in case
  (`bleat`, the tool; `Bleat`, the app). ([layout](docs/repository-layout.md))
- **Stage paths deliberately, never `git add -A`.** The open Xcode rewrites
  files it manages. `Support/Info.plist` holds no comments for that reason; its
  reasoning is in the docs. If it shows up in `git status`, compare
  `PlistBuddy -c Print` on both versions before staging.
  ([layout](docs/repository-layout.md))
- Small PR-sized steps; each ends with `swift build && swift test` green.
- Before writing a model, look at the fixture. Before writing a command, run it
  on the host and capture the output into `Fixtures/`.
- Ask before: adding dependencies, adding platform branches, changing the
  transport protocol, or starting Phase 2 work.
- Multi-account note: the developer runs two Claude Code accounts via direnv
  (`CLAUDE_CONFIG_DIR` per directory). A pane's `cwd` implies the account;
  Bleat may show that as a badge later. Not a Phase 1 concern.

## Open questions

They live in [`docs/bleat-2-plan.md`](docs/bleat-2-plan.md), each tagged with
the phase it must close before. Resolve against the live host, record the
answer in the doc for its area, then strike it there.

## Testing against a live host

herdr-core runs on this Mac, so `bleat terminals [--watch]` needs no SSH: it
runs `hc connect` locally. Never experiment on the live terminals: start a
scratch one with `hc run --bg --no-parent --no-notify --name bleat-scratch --
/bin/sh -i`, and remove it with `hc kill` and `hc rm`. **Testing pairing
against a scratch sshd needs `SetEnv HOME=<scratch>`**, or it writes to your
real `authorized_keys`. The scratch sshd recipe and the `PATH` and
`NSHomeDirectory` traps are in [`docs/testing.md`](docs/testing.md).
