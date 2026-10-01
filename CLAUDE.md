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
push notifications, watchOS, Live Activities, multi-account badges.

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
| [`docs/pairing.md`](docs/pairing.md) | the enrollment-key swap, peer identity, the QR, endpoint discovery and refresh, Tailscale, addresses by hand, local network permission, unpairing, endpoint selection |
| [`docs/app-screens.md`](docs/app-screens.md) | `ConnectionStore`, the list screens, the iPad split view, the host screen, previews, the pairing UI |
| [`docs/creating-from-the-phone.md`](docs/creating-from-the-phone.md) | starting, stopping and deleting sessions; workspaces; agents (including `agent_not_ready`); tabs; terminal rows — with the 0.9.3 re-measurement |
| [`docs/pane-view.md`](docs/pane-view.md) | pane sizing (`--cols` crops), the phone session, scrolling, the terminal always holding the pane, the key bar, typing, the keychain dead end, the repaint investigation |
| [`docs/console-tool.md`](docs/console-tool.md) | `bleat` commands: `pair`, `redeem`, `keys`, and the `authorized_keys` anchoring rules |
| [`docs/repository-layout.md`](docs/repository-layout.md) | the full layout, why `BleatProcess` exists, the static Linux build and what the port needed |
| [`docs/concurrency.md`](docs/concurrency.md) | Swift settings on both sides of the seam, the `RemoteList` `deinit`, why approachable concurrency is off |
| [`docs/app-icon.md`](docs/app-icon.md) | the icon, `Design/icon.swift`, and authoring a `.icon` by hand |
| [`docs/phase-history.md`](docs/phase-history.md) | how each phase gate was verified |

## Repository layout

```
Bleat.xcodeproj             # one app target; sources join via a synchronized group
App/                        # @main App struct and little else
Design/icon.swift           # generates the icon's layers — run it, never edit the PNGs
BleatKit/                   # the local Swift package
  Sources/
    BleatKit/               # domain + transport. No SwiftUI. Builds for iOS.
    BleatUI/                # SwiftUI shared between app targets; MainActor by default
    BleatProcess/           # macOS and Linux only: LocalProcessTransport, QR encoder
    bleat/                  # executable target, the console tool
  Tests/BleatKitTests/      # unit tests: codec, models, fake transport
  Tests/BleatUITests/       # lays views out for real; needs a simulator
  Fixtures/                 # schema.json + captured CLI output (source of truth)
Support/Info.plist          # the one key that cannot be a build setting
ci_scripts/ci_post_clone.sh # macro fingerprint defaults + `swift test` gate
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
- **`swift build` does not compile `BleatUI/Pane/`** — it is UIKit-only. Use
  `xcodebuild -scheme BleatKit-Package -destination 'generic/platform=iOS'`
  from `BleatKit/`, or the simulator test run.
- **Command-line `xcodebuild` passes `-derivedDataPath`** to a scratch
  directory, or it corrupts the DerivedData the open Xcode uses.
- **`RemoteList`'s empty `deinit` must stay**: without it the optimiser
  segfaults and only the archive fails. ([concurrency](docs/concurrency.md))

## Concurrency settings

| where | settings |
|---|---|
| Xcode targets | `SWIFT_VERSION = 6.0`, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, `SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY = YES` |
| package | `swiftLanguageModes: [.v6]`, `.enableUpcomingFeature("MemberImportVisibility")` on every target, `.defaultIsolation(MainActor.self)` on `BleatUI` only |

`SWIFT_APPROACHABLE_CONCURRENCY` is off on both sides, deliberately. Why, and
the rest, in [`docs/concurrency.md`](docs/concurrency.md).

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
- **The package is named `BleatKit`, not `bleat`, and the reason is a
  filesystem collision.** It used to be `bleat`, against an `.xcodeproj` named
  `Bleat` — and macOS is case-insensitive, so Xcode's two intermediates
  directories, `Intermediates.noindex/bleat.build` (the package) and
  `Bleat.build` (the project), were **the same directory**. Verified by inode:
  both `stat` calls returned `298112417`. The app target's own build directory
  therefore sat inside the package's, alongside `BleatKit.build` and
  `BleatUI.build`. Reproduced from a clean `-derivedDataPath`, so it was
  structural rather than a corrupted cache. Renaming the package separates them
  — the executable *product* is still `bleat`, so the CLI is unchanged.
  - The autocreated package scheme is `BleatKit-Package` now, and it resolves
    only from `BleatKit/`, not from the project.
  - Two schemes still differ only in case (`bleat`, the tool, and `Bleat`, the
    app). That is tolerable where the build directories were not, but it is
    worth knowing when something in Xcode behaves oddly.

- **`git add -A` can silently strip `Support/Info.plist`'s comments, because
  Xcode rewrites that file.** Caught in review, 30 Sept 2026: a commit that
  touched only doc comments also deleted the 25-line XML comment explaining why
  that plist exists at all — the two keys that cannot be build settings, the
  `PairingPayload.urlScheme` coupling no test can assert, and why
  `NSBonjourServices` is not optional. The keys themselves survived; only the
  reasoning went, which is the worse loss in a file nobody reads twice.
  - **`xcodebuild build` is not the culprit** — reproduced with a scratch
    `-derivedDataPath` and the file's md5 was unchanged. It is the **open
    Xcode**, which normalises a plist it manages, and plist serialisation drops
    comments. Same family as the DerivedData note below: the GUI and the command
    line both think they own things in here.
  - So **stage paths deliberately in this repo rather than `-A`**, and if the
    plist does appear in `git status` unexpectedly, diff it before staging:
    `PlistBuddy -c Print` on both versions says whether any *key* really moved.

- **Command-line `xcodebuild` must pass `-derivedDataPath`, or it fights Xcode.**
  Without it, `xcodebuild -scheme Bleat` writes into the *same* DerivedData the
  open Xcode is using. Interleaving configurations and destinations there —
  Debug simulator, Debug device, Release device, in one sitting — leaves the
  build database and the products on disk out of step, and the first thing that
  notices is **previews**, which JIT-link per-file object files:
  `FailedToLaunchAppError` wrapping `ShellCouldNotValidatePathExists: Could not
  validate that build product path exists to link: …/BleatUI.build/
  Objects-normal/arm64/AgentLink.o`. The file was there; the build description
  disagreed. It cost a 2.2 GB DerivedData deletion and a full rebuild to clear.
  Build into a scratch path instead, and let Xcode keep its own.

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

Resolved (7 Sept 2026): **a split tab's `pane layout`**, captured at last —
`Fixtures/pane-layout-split.json`. Both blockers turned out to be avoidable: a
`herdr pane split` needs no `session attach`, so the nested-herdr guard never
came into it, and an isolated probe workspace in the `phone` session meant the
live `work` session was never touched. The numbers justify the design — the
tab's `area` is 54 columns and **each pane is 27** — so a client that rendered a
split pane at `area.width` would wrap every line at double the real width.
Looking the pane up by id is what avoids that, and the test now runs against the
host's own bytes instead of a synthesised sibling. The reply also carries a
`splits` array, a field nothing reads and no fixture had ever contained: the
first real exercise of "unknown keys are ignored, never fatal" on this command.

Resolved (7 Sept 2026): **`blocked` and `done` agent rows**, and with them what
`done` actually means — see the agent-state bullets under **Herdr facts**. The
sort order recorded there was wrong and has been corrected.

Resolved (6 Sept 2026): `observe` ignores `terminal.scroll`, so there is no
host-side scrollback for a reader; and `agent prompt --wait` is documented on the
host — an already-**blocked** agent is rejected with `agent_blocked` *before any
input is sent*, a non-working agent needs an observed state change within 5000ms
or returns `agent_prompt_stalled`, and it does not track turns, so an agent that
was already working may match on that turn's completion.

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
