# herdr-core (`hc`) facts

What Bleat 2 relies on about `hc`, with where each fact came from. This
file replaces `herdr-facts.md` once the herdr backend is gone. The plan
it serves is [`bleat-2-plan.md`](bleat-2-plan.md).

Sources: **live**, run on this Mac against hc 0.1.19 (Pis and federated
machines run 0.1.18), or **source**, read in
[herdrdev/herdr-core](https://github.com/herdrdev/herdr-core) (Apache-2.0,
branch `master`; paths below are under `crates/herdr-core/src/`). A fact read
from the source has not been seen on the wire until it says **live** too.
When the host disagrees with this file, the host wins.

## Framed mode (source: `wire.rs`)

- After `hello` with `framed: true`, every message is a frame:
  `[channel u32 LE][kind u8][len u32 LE][payload]`, a 9-byte header, payload
  at most 16 MiB.
- **Channel 0 carries JSON-RPC.** Each attach stream gets its own channel.
  Events from `events.subscribe` also arrive on their own channel, as JSON
  lines, with credit.
- Kinds:

  | kind | value | payload |
  |---|---|---|
  | DATA | 0 | bytes: PTY output from the core, keys from the viewer |
  | CREDIT | 1 | u32 LE: "receiver consumed this many bytes" |
  | CLOSE | 2 | JSON reason from the core; empty from a client |
  | RESIZE | 3 | u16 LE cols, u16 LE rows. Viewer → core; core → observer |
  | FOCUS | 4 | 1 gained, 0 lost |
  | FACTS | 5 | JSON display facts |
  | AUTOMATIC_INPUT | 6 | terminal-generated replies, not human activity |

- **Flow control:** each stream starts with a 256 KiB window. A viewer that
  stops reading has up to 4 MiB of output kept for it; past that, the
  backlog is dropped and the viewer gets a **repaint**, not a disconnect.
  This is the suspended phone's case. A client that stops reading
  control replies (more than 64 MiB) is dropped.
- A reference framed client is in `crates/herdr-core/tests/common/framed.rs`.

## The handshake and calls (live, hc 0.1.20, 12 Nov 2026)

- `hc connect` speaks on stdin/stdout. The client writes one plain JSON line,
  `{"jsonrpc":"2.0","id":0,"method":"hello","params":{"framed":true,"generation":1}}`,
  and reads one line back: `result` carries `framed: true`, `generation: 1`,
  `version`, `core: {id, name}`, `features`, `methods`. Every byte after that
  newline is frames (`herdr-core/tests/common/framed.rs` does the same).
- **`methods` is the floor Bleat checks** (live, 14 Nov 2026). The lists
  from 0.1.18 (adam), 0.1.20 (mika) and 0.1.21 (this Mac) are identical;
  of the features, 0.1.18 lacks `restart_environment`, which Bleat does not use. Bleat's floor is five of them,
  what reading a host takes (`HcClient.requiredMethods`): it refuses a core
  without one as `HcProtocolError.outdated`. Methods only creating or
  marking seen use fail at their own call. A hello with no `methods`, or an
  empty list, is not refused.
  `Fixtures/hc-hello-0.1.18.json` is adam's reply.
- A call is one JSON-RPC request in one DATA frame on channel 0; its reply
  comes back the same way, matched by `id`. Errors carry `data.kind`.
- `events.subscribe` answers `{channel, seq, terminals}` on channel 0. The
  notifications then arrive as JSON lines in DATA frames on that channel,
  which needs CREDIT like an attach stream. A `heartbeat` (`{seq}`) every
  15 s.
- Built as `HcClient`; `bleat terminals [--watch]` drives it from a Mac.

## Events and how to apply them (live; source: `remote.rs`)

- Params are `{type, terminal, seq, data}`. `created`/`restarted` carry the
  whole record; `removed` an empty object. The rest set fixed keys, exactly as
  herdr-core's own mirror applies them (`remote.rs`, `apply`):
  `finished`/`lost` → `state`, `reason`, `exit_code`, `signal`,
  `finished_ms`, and drop `foreground`; `status` → `status`, `records`,
  `reported`; `turn`; `title`; `labels` (the whole map); `keep`; `size` →
  `cols`, `rows`; `foreground` → the whole object.
- Seen live for a scratch terminal: `created`, `labels` (Herdr.app adds
  `where` within a second), `foreground`, `labels`, `finished`, `removed`.
- `HcTerminalSet` keeps records as JSON and applies events that way, then reads
  `HcTerminal` out — so a key this build does not model still lands.
- **The snapshot includes federated machines' terminals** (`adam/t8`,
  `mika/t2`) and finished ones. Bleat lists only local (`/`-free), live ones:
  it pairs those machines directly. `terminal.list` hides finished terminals
  (`hidden_finished`).

## What Herdr.app's labels say (live)

- `where`: `"<space> / <tab>"`, e.g. `"nuvio-health / Agent"` — enough to
  group a list by space without reading Herdr.app's doc.
- `herdr.seen`: the turn someone last looked at. `seen 16` beside `turn 16` on
  a `done` terminal that had been read. So "done and not yet looked at" is
  `status.state == done && seen < turn` (no label: unseen).
- `title` is the program's; `foreground.name` for Claude Code is its version
  (`2.1.322`), not a name.
- A terminal started from inside an hc terminal is that terminal's child and
  hc types notes about it into the parent (seen live, in this Claude session).
  Bleat sends `no_parent` and `no_notify` when it creates terminals.

## How Herdr.app takes in a terminal it did not start (source: herdr-app, read 13 Nov 2026; live)

Read in herdr-app's `src/window.rs` (`reconcile`, `adopt`, `write_where`),
`src/mirror_sync.rs` and `docs/labels.md`, then checked on the Mac.

- **Herdr.app shows only terminals labeled `herdr.space=<id>`.** On every
  listing it takes in a live, labeled terminal it is not showing: into that
  space, **in a new tab** unless `herdr.tab=<id>` names an existing one (then
  as a split there). It also sets `keep: true` on it and writes `where`.
  Unlabeled terminals stay hidden, by design ("unlabeled workers").
- **An unknown space id makes a new space** under that id, unnamed, with the
  terminal's directory as its folder.
- **Names live in a core document named `herdr-app`**: `doc.get` returns
  `{value: {spaces: [{id, name, folder, tabs: [{id, name, root}]}]}, version}`
  (`Fixtures/hc-doc-herdr-app.json`, captured from the Mac and anonymized).
  An empty name is called Herdr's way: a space after its folder, a tab by its
  position. **Each machine's core holds its own** (the app reads it with
  `on`); adam's was empty on 13 Nov 2026. Only Herdr.app writes it.
- `where` is written by Herdr.app alone, from those names, and follows
  renames; the ids are what it groups by.
- `docs/labels.md`: "a terminal a client starts gets `herdr.seen=0`". It also
  names `herdr.pinned=1` (pinned on every client).
- **Live, 13 Nov 2026:** labeling the phone's `t68` and `t69` with
  `herdr.space` alone put each in a new tab of that space within seconds; a
  scratch terminal started through the API with `labels: {herdr.space,
  herdr.seen: "0"}` did the same. Removing one Herdr.app has kept: `hc keep
  <t> --off`, then `kill` and `rm`.

## Attaching (live, hc 0.1.20, 12 Nov 2026, on a scratch shell)

- `terminal.attach {terminal, cols, rows, history}` on channel 0 answers
  `{channel, automatic_input, resize_notifications, terminal: {…record}}`
  (`Fixtures/hc-attach.json`; read by `HcAttachment`).
  The record already shows the attach's size: **an active attach takes the
  terminal over at once** (`cols: 40` straight after attaching at 40).
- The first paint and live output are DATA on that channel, credited as they
  are consumed. Typed bytes go back as DATA on the same channel and echo.
- RESIZE (`u16 cols, u16 rows`) from the viewer reflows the program in place
  and repaints; `hc get` read 30×10 after one. No reopen.
- A CLOSE from the viewer is answered with a CLOSE, and the terminal's size
  goes back to the next most recent active viewer — here, with nothing else
  attached, the 200×120 headless default. With Herdr.app attached, the Mac.
- `resumed: true` would attach without taking over until the viewer types,
  resizes or focuses (`viewers.rs`: `active_at` unset). Not used: a phone
  watching the Mac's ~130 columns can only crop or shrink them. Decided 12 Nov
  2026, take over on open.
- **No scroll command.** A program that enabled mouse reporting gets wheel
  clicks as input; otherwise the viewer scrolls its own copy of the history,
  which `history` paints first (main screen only).

## Plain mode cannot carry events and requests together (source: schema)

`SubscribeResult` says that in plain line mode, after `events.subscribe`,
"this connection now carries only notifications". **A client that needs
events and requests on one connection must be framed.** HcKit therefore goes
framed straight after `hello`.

## Viewers, input and size (source: `viewers.rs`, `attach.rs`)

- A terminal may have several active viewers.
- "Typing, resizing or focusing makes a viewer the one whose size and colors
  count." The most recently active typing viewer sets size and display facts.
  With no viewer, the terminal runs headless at the configured size (default
  200×120).
- So 1.x's "always takeover" becomes "the most recent active viewer wins". The
  phone reflows the Mac only once it types, resizes or focuses. `observe:
  true` gives a true read-only view.
- `resumed: true` on attach: the viewer sets the size only once it is active
  again.

## Status (source: `status.rs`; live)

- Status is set only by programs that report it (OSC 7501), and kept per
  terminal exactly as reported. **Live:** plain `zsh` terminals have status
  `null`; Claude Code terminals report it.
- States: `idle`, `working`, `done`, `blocked`, **`error`**. `blocked` carries
  an optional reason (`permission`, `question`, `auth`). `working` and
  `blocked` carry an optional progress, 0–100. The core treats `blocked` and
  `error` together as "stuck".
- `turn` goes up each time the root record leaves `working`. **Live, 13 Nov
  2026** (a scratch Claude Code given one prompt;
  `Fixtures/hc-turn-events.ndjson`): `status` working, `title`, `status`
  done, then `turn` with data `{"state":"done","turn":1}`, then `status`
  again with its message — the status first, then the turn, as herdr-app's
  `docs/labels.md` says.
- **hc never clears `done`.** "Done, and nobody has looked" is the
  client's own idea, and Herdr.app's convention is `herdr.seen=<turn>`
  (herdr-app `docs/labels.md`, read 13 Nov 2026): done is `turn > seen`, a
  missing label is not 0. **Bleat writes it on purpose** while a terminal is
  looked at, as Herdr.app's clients do (decided 13 Nov 2026; `HcSeen`,
  [pane view](pane-view.md)). Never write it by accident — outside that
  rule it clears the Mac's marker, the 1.x `agent focus` trap again.

## Reconnect (source: schema)

- `SubscribeResult` carries `seq`. After a `missed` snapshot, events at or
  below its `seq` are ignored.

## Creating terminals (source: schema)

- Children end with their parent unless `outlive_parent`, and `parent`
  defaults to the terminal the call is made from. **Bleat always sends
  `no_parent: true` and `no_notify: true`**, so no change in how `hc` is
  launched can tie an agent's life to the phone's SSH session.
- `env` takes the client's terminal identity (`TERM`, `TERM_PROGRAM`,
  `COLORTERM`). `size` sets the initial grid before the program starts.
  Bleat sends SwiftTerm's identity and the phone's grid.
- `hc run --bg --json` returns `address` (like `t4p`), not `id` (live).
- **Measured through the API, 13 Nov 2026 (hc 0.1.20, scratch terminals;
  replies in `Fixtures/hc-run.json`, `hc-run-spawn-failed.json`,
  `hc-templates.json`):**
  - `argv: []` starts the login shell (`/bin/zsh -l` on the Mac); `line` runs
    under `sh -c`. `size` is honoured; `no_parent`/`no_notify` come back as
    `parent: null`, `notify: false`.
  - **Without `cwd` the terminal starts in the core's own directory, `/` on
    the Mac**, and **`~` is not expanded**: `cwd: "~"` fails. So Bleat asks
    the host's `$HOME` and sends an absolute path.
  - **A `cwd` that does not exist fails as `cannot start "/bin/sh": No such
    file or directory`**, kind `spawn_failed`, hint "check the program name
    and cwd": the shell is blamed for the directory. Bleat checks the
    directory first.
  - **Every terminal says Ghostty**: `TERM=xterm-256color`,
    `COLORTERM=truecolor`, `TERM_PROGRAM=ghostty`, `identity: "ghostty"`,
    fixed at start; `env` with `TERM`/`COLORTERM` alone leaves
    `TERM_PROGRAM=ghostty`. Bleat sends no identity (see `HcRunRequest`).
  - A `line` gets the core's environment: `PATH` starts with `~/.local/bin`
    on the Mac and on adam, so a bare `claude` resolves on both.
  - A name already live is `name_taken`: "a live terminal is already named
    …". `terminal.rm` of a live terminal is `live`, "kill it first".
  - `templates.list` gives `name`, `description`, `command` (and `error` for a
    file that cannot be used); templates are the user's own files under
    `~/.config/herdr-core/templates`.

## Installing (source: `install.sh`, read 12 Nov 2026; live in a fresh Debian container)

- `curl -fsSL https://releases.herdr.dev/core/install.sh | sh`. Needs `curl`
  and `tar`; asks nothing, needs no tty or sudo. Linux and macOS, x86_64 and
  aarch64; anything else exits 1 with `hc: no build for …` on stderr. Every
  failure is one `hc: …` line on stderr and exit 1.
- Writes `~/.local/bin/herdr-core` (on a Mac, as a non-root user, the signed
  `Herdr Core.app` it links into). Adds `~/.local/bin/hc -> herdr-core` **only
  if no `hc` exists** on the installer's `PATH` or in `~/.local/bin` — "some
  window managers ship one". So `herdr-core` is the one name that is always
  there.
- **A fresh install does not start a core.** The first `hc connect` does:
  measured as a non-root user in `debian:bookworm-slim`, `hello` and
  `terminal.list` answered straight after install (hc 0.1.20).
- Run again over an existing install, it updates in place (`hc update
  --from`) and running terminals keep running. Exit 0 both times.
- **Piped, a failed download is an empty script that exits 0.** Bleat runs
  the same script fetched to a temporary file first, so curl's failure is the
  command's failure.
- **The core and logout (Linux).** A core started from a login with no
  systemd user manager says `hc: no systemd user manager here: the core ends
  with whatever started it` (the container, live). With one, hc runs the core
  as `systemd-run` user units (`hc-serve-…`, live on adam) and tries
  `loginctl enable-linger --no-ask-password` itself; when that is refused it
  says `the core stops when your last login ends; sudo loginctl
  enable-linger …` (strings in the binary — not yet seen live). adam and the
  other Pis already linger. Whether a fresh Pi's SSH login may turn linger on
  without a password is not yet measured.

## Not yet known

- Whether `<session>/<session>.sock` is the general socket path pattern: only
  `~/.local/state/herdr-core/default/default.sock` has been observed.
- Whether a fresh Raspberry Pi OS user, logged in over SSH only, gets linger
  from hc without a password (polkit's `set-self-linger`), or the core dies
  when the phone disconnects. Blocks Phase B's gate on a fresh Pi.
- Whether a scratch `--session` gets its own core. `hc server` takes no
  session option; sessions are chosen only by `--session`/`HC_SESSION` on the
  client. Check `paths.rs` and `server.rs`.
