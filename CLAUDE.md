# Bleat — native iOS remote for Herdr

Bleat is a thin native client for [Herdr](https://herdr.dev) sessions. It shows
workspaces and agents sorted by attention state, renders live panes, and lets the
user answer approvals, send prompts, and type into a pane from a phone. Herdr and
the agents always run on the host; Bleat never owns a process. App Store name:
"Bleat for Herdr".

The product promise is **zero host setup beyond Herdr itself**. Transport v1 is
plain SSH: the app runs `herdr` CLI commands over exec channels and speaks
Herdr's own JSON. No daemon, no relay, no plugin on the host.

## Current phase: 3 — Control

Phase 1 met over real SSH. **The Phase 2 gate was met 7 Sept 2026**: paired
and connected from an iPhone on cellular with Wi-Fi off, over Tailscale. How
each gate was verified, and what that taught, is in
[`docs/phase-history.md`](docs/phase-history.md).

Read the phase gates before proposing work outside them.

| Phase | Deliverable | Gate to next phase |
|---|---|---|
| **1 — Pipe** ✅ | Platform-agnostic Swift package `BleatKit` + macOS console tool `bleat` | From a Mac terminal: connect over SSH, list sessions/workspaces/agents, attach to a pane, see live frames, send input, resize, detach cleanly. No UI code. |
| **2 — Read-only app** ✅ | Xcode project, SwiftUI iOS app | Hosts → session → workspaces → agents (blocked on top) → live pane view (SwiftTerm). No input yet. Runs on a real phone over Tailscale. |
| **3 — Control** | Input + release | Keyboard with accessory row (Esc, Ctrl, Tab, arrows, y/n), prompt composer via `agent prompt`, takeover indicator, reconnect on foreground. TestFlight, then App Store. |

Out of scope until after Phase 3: pairing/relay transport (iroh or WebRTC),
push notifications, Live Activities, multi-account badges.

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
| [`docs/herdr-facts.md`](docs/herdr-facts.md) | herdr's two command families, envelopes, errors on stderr, agent states, the pane stream protocol |
| [`docs/ssh-transport.md`](docs/ssh-transport.md) | Citadel, host keys, session selection by command prefix, clean detach |
| [`docs/pairing.md`](docs/pairing.md) | the enrollment-key swap, pairing another device from a paired one, peer identity, the QR, endpoint discovery and refresh, Tailscale, addresses by hand, local network permission, unpairing, endpoint selection |
| [`docs/app-screens.md`](docs/app-screens.md) | `ConnectionStore`, the list screens, the iPad split view, the host screen, what a host says about itself (stored info, the live load bar), previews, the pairing UI |
| [`docs/watch.md`](docs/watch.md) | the watch app: why it relays through the phone, `RelayTransport`, the phone's `WatchRelayHost`, the mirrored host list, what is and is not on the watch, driving a simulator with `DebugLaunch` |
| [`docs/creating-from-the-phone.md`](docs/creating-from-the-phone.md) | starting, stopping and deleting sessions; workspaces; agents (including `agent_not_ready`); tabs; terminal rows — with the 0.9.3 re-measurement |
| [`docs/pane-view.md`](docs/pane-view.md) | pane sizing (`--cols` crops), the phone session, scrolling, the terminal always holding the pane, the key bar, typing, the keychain dead end, the repaint investigation |
| [`docs/console-tool.md`](docs/console-tool.md) | `bleat` commands: `pair`, `redeem`, `keys`, and the `authorized_keys` anchoring rules |
| [`docs/repository-layout.md`](docs/repository-layout.md) | the full layout, why `BleatProcess` exists, the static Linux build, the SDK's ARMv8.1 allocator and what the port needed |
| [`docs/concurrency.md`](docs/concurrency.md) | Swift settings on both sides of the seam, the `RemoteList` `deinit`, approachable concurrency and what is `@concurrent` |
| [`docs/app-icon.md`](docs/app-icon.md) | the icon, `Design/icon.swift`, and authoring a `.icon` by hand |
| [`docs/testing.md`](docs/testing.md) | a scratch herdr session, a scratch sshd, testing pairing without touching your own keys |
| [`docs/phase-history.md`](docs/phase-history.md) | how each phase gate was verified |

## Repository layout

```
Bleat.xcodeproj             # two app targets; sources join via synchronized groups
App/                        # @main App struct and little else; icon and assets shared with the watch
Watch/                      # the watch app's @main, and nothing else
Design/icon.swift           # generates the icon's layers — run it, never edit the PNGs
Design/symbols.swift        # generates the custom SF Symbols — run it, never edit the SVGs
BleatKit/                   # the local Swift package
  Sources/
    BleatKit/               # domain + transport. No SwiftUI. Builds for iOS and watchOS.
    BleatUI/                # SwiftUI shared between app targets; MainActor by default
    BleatProcess/           # macOS and Linux only: LocalProcessTransport, QR encoder
    bleat/                  # executable target, the console tool
  Tests/BleatKitTests/      # unit tests: codec, models, fake transport
  Tests/BleatUITests/       # lays views out for real; needs a simulator
  Fixtures/                 # schema.json + captured CLI output (source of truth)
Support/Info.plist          # the one key that cannot be a build setting
ci_scripts/ci_post_clone.sh # macro fingerprint defaults + `swift test` gate
Scripts/build-linux.sh      # the console tool for Linux: aarch64 (ARMv8.0 and up) or x86_64
docs/                       # the detail behind this file
```

## Rules that bite

Each of these shipped as a bug or cost a day. The why is in the linked doc.

- **Never experiment against the `work` session**, and never call
  `agent focus` — it clears the `done` marker for whoever is at the Mac.
  Use a scratch session ([Testing against a live host](#testing-against-a-live-host)).
- **herdr has two command families.** Socket-API commands print enveloped JSON
  and reject `--json`; client-side commands (`session …`) need `--json` and
  have no envelope. Errors go to **stderr**. The session is chosen by
  environment (`HERDR_SESSION`, unset `HERDR_SOCKET_PATH`), never a flag.
  ([herdr facts](docs/herdr-facts.md))
- **herdr says yes when nothing happened.** `session delete` of a missing
  session answers `deleted: true`; `workspace create` with a missing `--cwd`
  succeeds in `$HOME`. Read the host back; never trust the reply.
  ([creating](docs/creating-from-the-phone.md))
- **`pane_id` is already the full target** (`w2:p1`). Build test data from
  `Fixtures/`, not from memory.
- **The terminal stream carries one viewport and no history.** Scrolling is
  `terminal.scroll`, which herdr applies to its own history or hands to the
  program as a wheel event. ([pane view](docs/pane-view.md))
- **Layout is the stream's size.** The terminal derives its grid from its
  bounds and the pane's pty is `stty`'d to match, so anything in a safe area
  that varies with state reopens the stream on someone's Mac.
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
- **`RemoteList`'s empty `deinit` must stay**: without it the optimiser
  segfaults and only the archive fails. ([concurrency](docs/concurrency.md))

## Concurrency settings

`SWIFT_APPROACHABLE_CONCURRENCY` is on, on both sides: a `nonisolated async`
function runs on its caller's actor, so work that must leave the main actor
says `@concurrent`. The settings on each side, and why, are in
[`docs/concurrency.md`](docs/concurrency.md).

## Architecture rules

- **Transport is an interface.** Everything above it must not know it is SSH.
  ```swift
  protocol HerdrTransport: Sendable {
      func run(_ args: [String]) async throws -> Data                   // one-shot herdr command
      func openStream(_ args: [String]) async throws -> HerdrStream     // long-lived NDJSON channel
  }
  ```
  `HerdrStream` exposes `AsyncThrowingStream<Data, Error>` for stdout lines and
  `send(Data)` for stdin. The second transport exists: `RelayTransport`, the
  watch asking the phone. It was added without touching `HerdrClient`.
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

## Conventions

- Swift 6.4 toolchain (Xcode 27.1), Swift 6 language mode, strict concurrency,
  `Sendable` everywhere in BleatKit.
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
  `Support/Info.plist` and drops its comments. If the plist shows up in
  `git status` unexpectedly, compare `PlistBuddy -c Print` on both versions
  before staging. ([layout](docs/repository-layout.md))
- Small PR-sized steps; each ends with `swift build && swift test` green.
- Before writing a model, look at the fixture. Before writing a command, run it
  on the host and capture the output into `Fixtures/`.
- Ask before: adding dependencies, adding platform branches, changing the
  transport protocol, or starting Phase 2 work.
- Multi-account note: the developer runs two Claude Code accounts via direnv
  (`CLAUDE_CONFIG_DIR` per directory). A pane's `cwd` implies the account;
  Bleat may show that as a badge later. Not a Phase 1 concern.

## Open questions (resolve against the live host, then delete)

- Whether the host ever sends a non-`terminal.frame` record on stdout. Only
  frames have been observed; `TerminalRecord.unknown` covers the rest.

## Testing against a live host

herdr runs on this Mac, so `LocalProcessTransport` needs no SSH. Never
experiment against the `work` session: start a scratch one with
`script -q /dev/null herdr session attach bleat-test &` and stop it with
`herdr session stop <name>`. **Testing pairing against a scratch sshd needs
`SetEnv HOME=<scratch>`**, or it writes to your real `authorized_keys`. The
scratch sshd recipe and the `PATH` and `NSHomeDirectory` traps are in
[`docs/testing.md`](docs/testing.md).
