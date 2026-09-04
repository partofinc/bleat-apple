# Bleat — native iOS remote for Herdr

Bleat is a thin native client for [Herdr](https://herdr.dev) sessions. It shows
workspaces and agents sorted by attention state, renders live panes, and lets the
user answer approvals, send prompts, and type into a pane from a phone. Herdr and
the agents always run on the host; Bleat never owns a process. App Store name:
"Bleat for Herdr".

The product promise is **zero host setup beyond Herdr itself**. Transport v1 is
plain SSH: the app runs `herdr` CLI commands over exec channels and speaks
Herdr's own JSON. No daemon, no relay, no plugin on the host.

## Current phase: 1 — the pipe

We are in Phase 1. Read the phase gates before proposing work outside them.

| Phase | Deliverable | Gate to next phase |
|---|---|---|
| **1 — Pipe** | Platform-agnostic Swift package `BleatKit` + macOS console tool `bleat` | From a Mac terminal: connect over SSH, list sessions/workspaces/agents, attach to a pane, see live frames, send input, resize, detach cleanly. No UI code. |
| **2 — Read-only app** | Xcode project, SwiftUI iOS app | Hosts → session → workspaces → agents (blocked on top) → live pane view (SwiftTerm). No input yet. Runs on a real phone over Tailscale. |
| **3 — Control** | Input + release | Keyboard with accessory row (Esc, Ctrl, Tab, arrows, y/n), prompt composer via `agent prompt`, takeover indicator, reconnect on foreground. TestFlight, then App Store. |

Out of scope until after Phase 3: pairing/relay transport (iroh or WebRTC),
push notifications, watchOS, Live Activities, multi-account badges.

## Repository layout (Phase 1)

```
Package.swift
Sources/
  BleatKit/                 # library, no platform-specific imports
    Transport/              # HerdrTransport protocol + SSHTransport (Citadel)
    Protocol/               # NDJSON codec, frame/command types
    Model/                  # Codable models for herdr JSON (from schema.json)
    Client/                 # HerdrClient: typed API over a transport
  bleat/                    # executable target, macOS console tool
Tests/
  BleatKitTests/            # unit tests: codec, models, fake transport
Fixtures/
  schema.json               # output of `herdr api schema --json` (source of truth)
  *.json                    # captured CLI outputs for decoding tests
```

`BleatKit` must compile for macOS and iOS with no `#if` platform branches.
Anything that needs UIKit/SwiftUI/SwiftTerm lives outside this package (Phase 2).

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
  `Fixtures/schema.json`. Do not hand-invent fields; if a field is missing,
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
  without asking.
- Auth: ed25519 key generated by the app, stored in Keychain (Phase 2) or a file
  under `~/.bleat/` for the console tool. Password auth is allowed only for the
  one-time "install my key" flow.
- Host key: trust-on-first-use, pinned per host. Changed key = hard error.
- The console tool takes `user@host[:port]` plus `--key PATH`; nothing is read
  from `~/.ssh/config` in Phase 1.

## `bleat` console tool (Phase 1 acceptance)

```
bleat hosts add dev user@10.0.0.5 --key ~/.bleat/id_ed25519
bleat sessions dev                        # session list
bleat agents dev [--session work]         # agents sorted by state, one per line
bleat attach dev w1:p1 [--takeover]       # raw frames to the terminal, stdin → terminal.input
                                          # Ctrl-] detaches and sends terminal.release
bleat schema dev > Fixtures/schema.json   # refresh the contract
```

`attach` writing the ANSI bytes straight to a macOS terminal is the Phase 1
renderer. If it looks right there, SwiftTerm will render it in Phase 2.

## Conventions

- Swift 6.2, strict concurrency, `Sendable` everywhere in BleatKit.
- One type per file. Folders by feature, not by kind.
- `async/await` only; no Combine, no callbacks.
- Errors are typed: `HerdrError` (host said no), `TransportError` (network),
  `DecodingError` (contract drift). Never swallow stderr.
- Tests use `FakeTransport` fed from `Fixtures/`. No test touches the network.
- No third-party dependencies beyond Citadel without asking.
- Keep this file current: phase, verified facts, decisions. It is the onboarding
  doc for every session.

## Working style

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
