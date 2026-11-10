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
- `turn` goes up each time the root record leaves `working`.
- **hc never clears `done`.** "Done, and nobody has looked" is the client's
  own idea. Herdr.app appears to keep it in the `herdr.seen` label (once seen
  as `herdr.seen=6` on a Claude Code terminal, compared with `turn`).
  Unconfirmed; see the plan's question 7. Bleat must never write `herdr.seen`
  unintentionally: it would clear the Mac's marker, the 1.x `agent focus`
  trap again.

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

## Not yet known

- Whether `<session>/<session>.sock` is the general socket path pattern: only
  `~/.local/state/herdr-core/default/default.sock` has been observed.
- Whether a scratch `--session` gets its own core. `hc server` takes no
  session option; sessions are chosen only by `--session`/`HC_SESSION` on the
  client. Check `paths.rs` and `server.rs`.
