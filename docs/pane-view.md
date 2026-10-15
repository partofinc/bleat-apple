# The pane view (Phase 2, verified 5 Sept 2026)

> Moved verbatim from `CLAUDE.md` on 1 Oct 2026. Where the text says "this file", "above" or "below", it means the old single file; a **bold** section name can be found with `grep -r docs/`.

- **Read-only, by `terminal session observe` — superseded on 1 Oct 2026.**
  That was the whole of the Phase 2 gate, and Phase 3 put `control
  --takeover` behind a deliberate gesture. The terminal now always takes the
  pane; see **The terminal always holds the pane**. Measurements below that
  say `observe` describe the stream either command opens: both take
  `--cols`/`--rows` and send the same frames.
- **The host is asked to render at the phone's size, and this is a known
  problem — see below.** `observe --cols --rows` is honoured in the sense that
  the frame reports the size asked for. The size is only knowable after a layout
  pass, which is why the terminal lives in a view *controller*; rotation reopens
  the stream, and the first frame of a new one is `full: true`, so the screen
  simply redraws.

## `--cols` crops. It does not reflow — so the app renders the whole pane

An earlier version of this file claimed a wide pane "arrives already reflowed".
**That is false.** Measured against `w5:p1`, whose grid is 142 columns
(`herdr pane layout --pane w5:p1` → `rect: {width: 142, height: 47}`):

| asked | frame reports | widest content |
|---|---|---|
| 53 | 53 × 12 | 53, cut mid-word |
| 100 | 100 × 12 | 100, cut mid-word |
| 500 | 500 × 12 | **140** |

So `--cols` is a **viewport onto the existing grid** — it crops when narrower
and pads when wider. Asking for a phone's 53 columns hid 63% of every line with
nothing on screen to say so, and `observe` takes no horizontal offset, so
panning has to happen on the client.

**This is not a herdr limitation.** A pane is one pty with one screen buffer of
a single width, and the program inside wrapped its output to it. Any client that
wants different wrapping would have to resize the pty — and no client of this API
can. See below.

## A pane's size belongs to the session. No stream client can change it (verified 6 Sept 2026)

An earlier version of this file said a client "has to resize the pty, which
resizes it for whoever is at the Mac too — `control` can do that via
`terminal.resize`, and Phase 3 will have to decide whether it may." **The second
half was false and is withdrawn.** It was reasoning, not measurement. Measured in
an isolated headless session, against a pane whose rect was 94x39:

| what was attached | pane rect after |
|---|---|
| nothing (headless) | 94x39 |
| `observe --cols 60 --rows 20` | 94x39 |
| `control --cols 60 --rows 20 --takeover` | 94x39 |
| `{"type":"terminal.resize","cols":60,"rows":20}` on stdin | 94x39 |

Nothing moved it, and the resize record was *accepted* — no `input ignored` on
stderr. What it did do is visible in the frames that one client received:
`120x40 full=true` on attach, then `60x20 full=true` after the record. So
`--cols`, `--rows` and `terminal.resize` are all **one client's viewport** and
nothing else.

**Something may have moved on 0.9.3, and it is not settled.** While probing
scrolling on 30 Sept 2026, a `control --takeover` stream opened at 80×30 on a
94×39 pane made `pane read --source visible` return **30 rows** for as long as
it was attached, and 39 again after release. `pane layout` reported 94×39
throughout. So either the program's pty now follows the controlling client, or
`pane read` reports that client's viewport; only `stty size` inside the pane
tells them apart, and that was not measured. It matters less than it would
have — Bleat `stty`s the pty to the phone's grid itself (see **The phone
session**) — but the heading above is a 0.9.0 measurement until it is re-run.

**The geometry comes from the session's terminal size**, which is the attached
TUI's window when one is attached and `server.headless_cols` /
`server.headless_rows` when none is. Proved by restarting the same server under
`headless_cols = 200, headless_rows = 60`: the pane became 174x59 — 200 minus the
26-column sidebar, 60 minus the tab-bar row. Every pane in a session shares it;
on the dev Mac all seven workspaces report `area=142x47+26,1`.

Three consequences:

- **Bleat cannot disturb the Mac through this API, at all.** The Phase 3 question
  this file used to record — whether Bleat "may" resize someone's pane — does not
  exist. Nothing about the pane view needs to be defensive about it.
- **Resizing the Mac's window does change the pane**, because that is the session
  geometry moving. Bleat sees the new rect on its next `pane layout`; its own
  `--cols` never enters into it.
- **A phone-shaped host is a config change, not a client feature.** A herdr
  running headless sits at `headless_cols`/`headless_rows` (120x40 by default), so
  a phone-first setup can set those and every pane really is that size. That is a
  better answer than anything a client can do and needs no code here.

## The phone session, and what a client may change (6 Sept 2026)

A pane's grid belongs to the session, so a phone that wants a readable pane needs
either a session shaped for it or a way to change the pane. Both exist, and they
are different mechanisms — several wrong turns here came from conflating them.

**A stream client cannot change a pane's grid.** `observe --cols/--rows`,
`control` and a `terminal.resize` record are all per-client viewports; measured
above.

**The pty behind a pane can be resized from outside, and that is what reflows
it.** The program writes at the width of its own pty, and `stty` on that tty
raises `SIGWINCH` and makes it repaint. Verified on a clean pane: 53 columns
grown to 100 came back genuinely wrapped at 100, and shrunk to 40 likewise.
herdr's layout rect is **not** a ceiling — growing past it is fine. The tty comes
from `pane process-info` → pid → `ps -o tty=`. This is the only write Bleat makes
to a running program, and it is best effort: no tty, no permission or an older
herdr all fall back to reading the pane at the size it has.

**`herdr agent start` sizes the new agent from the *calling client's* pane.** An
agent started from inside a 142-column herdr pane came up with a 142-column pty
however narrow the target session was, because `HERDR_PANE_ID`/`HERDR_TAB_ID`/
`HERDR_WORKSPACE_ID`/`HERDR_ENV` were in scope. **This is worth knowing because
it looks exactly like something else going wrong**: it produced panes whose
content was wrapped far wider than the session, which was misread for most of a
day as attaching-from-the-Mac corrupting the pane, and led to a working feature
being removed and restored. Strip those variables — `phone-session.sh` does.

**A headless session renders a pane's bottom chrome differently from an attached
one.** Compared at the same moment: the `work` session, with a client attached,
shows a pane's input box as four rows — border, prompt, border, status. The
headless `phone` session shows four blank rows and one row with the border and
status composited together. Reproduced with a fresh agent, no `--resume`, no
contention, the pty matching the rect, at both 53 and 80 columns, and `pane read`
agrees with `observe` — so it is not a stream artifact, a width, or a race.
**Unconfirmed:** attaching a client was not successfully tested, so "attaching
fixes it" is an inference from that comparison rather than a demonstration. Bleat
renders the pane faithfully either way; this is a herdr question.

**Setup.** `~/.config/herdr/phone.toml` (a separate file; the default config is
untouched) sets `headless_cols`/`headless_rows`, and
`~/.config/herdr/phone-session.sh` is `start` (idempotent — server, workspace,
agent), `sync`, `watch`, `say TEXT`, `status`. `say` uses `herdr agent prompt`,
which submits over the socket API with no client attaching.

**Two things that bite when starting agents this way.** Anything spawned from
inside a Claude Code pane inherits `CLAUDE_CODE_CHILD_SESSION`, and an agent
started with it set writes **no transcript** — the pane says "Transcript saving
is off", and chat mode then has nothing to read. A herdr server passes its
environment to every pane it spawns, so it must be stripped at the server. And
`--resume <id>` in a pane whose session another Claude Code already holds works,
but that process reports it cannot take Remote Control.

**The crop was re-verified in the same controlled session**, since it is the fact
the whole design rests on. A single line of `A`x60 + `B`x60 + `C`x54 printed into
a 174-column pane, read by two observers at once:

| client asks | A | B | C |
|---|---|---|---|
| `--cols 174` | 60 | 60 | 54 |
| `--cols 60` | 60 | **0** | **0** |

The B's and C's are **gone, not wrapped onto a second line**. `--cols` crops. It
has never reflowed and cannot.

Two escape hatches found while probing, both worth knowing:
`experimental.allow_nested = true` in the config is what lifts the "nested herdr
is disabled by default" guard that has blocked scratch sessions from inside a
herdr pane, and `HERDR_CONFIG_PATH` lets a probe run on its own config without
touching the user's. Together with `HERDR_SESSION` and an unset
`HERDR_SOCKET_PATH`, that is how to get a disposable session to measure in —
`herdr server` with no subcommand runs one headless.

**What the app does now (option 1 of the four that were weighed).** It asks
`pane layout --pane <target>` for the pane's real grid, opens the stream at
*that* size, renders a terminal of exactly that many cells, and lets the user
pan. Nothing is ever hidden; landscape shows ~118 of 142 columns at once.

- **`PaneLayout` looks the pane up by id.** The layout belongs to a **tab**, not
  a workspace — verified live: `wA` has two panes and `pane layout` for either
  returns a single-pane layout, because they are in different tabs (`wA:t1`,
  `wA:t4`). A split tab puts several in `panes`, and rendering at a sibling's
  width would wrap every line. The tab's `area` is not the pane's rect either:
  `x` was 26, because herdr was drawing a sidebar.
- **A host that will not report a layout still gets a pane.** `HerdrError` and
  `DecodingError` fall back to the phone's size — the host reached and saying
  no, or answering in a shape that has moved. `PaneLayout` makes everything but
  `panes` optional for the same reason: the app reads only a pane's `rect`, and
  a decode failure on a field nothing uses would jump straight over the fallback
  and kill the pane instead of cropping it. A `TransportError` does propagate,
  because swallowing it would spend a second opening a stream that cannot open
  either and then blame the wrong thing. The fallback crops, and since 1 Oct
  2026 nothing on screen says so — see the size badge's removal below.
- **Frames are held until the terminal is actually that size.** SwiftUI
  publishes the grid an async hop before the view resizes to it, and the first
  frame lands in that window — a frame written for 142 columns fed to a
  53-column terminal wraps every line, and `observe` sends a full redraw only
  when it opens, so nothing would repair it. The controller reports the size it
  applied and the model flushes then. Buffered frames are dropped on a reopen:
  they were drawn for the old size.
- **Nothing about the chosen size is written before the cancellation guard.** A
  reader suspended in `pane layout` across a rotation resumes holding the
  pre-rotation viewport, and writing it then would clobber the size the live
  reader had just installed — leaving the screen rendering one grid while the
  stream sends another, and a rotation back deduplicated into doing nothing.
- **The terminal's background is read off its `layer`.** SwiftTerm's
  `setupOptions` moves the real colour into `layer.backgroundColor` and then
  sets `nativeBackgroundColor` to `UIColor.clear`, so the obvious property
  paints a transparent band — white under a black terminal in light mode, and a
  47-row pane leaves ~50pt bare under a portrait iPhone plus the whole overscroll
  region.
- **The terminal is never sized to the screen and then to the grid in one
  layout pass.** `TerminalView` reflows its buffer on every size change and the
  `observe` stream sends a full redraw only when it opens, so a stray
  intermediate size scrambles the screen with nothing left to repaint it. No
  bootstrap pass is needed to measure a cell either: SwiftTerm's
  `cellDimension` comes from the font at init rather than from the frame, and
  although it is internal, `getOptimalFrameSize()` is public and returns exactly
  `cellDimension × (cols, rows)` — so dividing by the terminal's own size
  recovers it without guessing at a font metric.
- **The frame is the only way to ask for a number of columns.** `TerminalView`
  derives its size from its bounds (`Int(width / cellWidth)`) and has no public
  setter. Landing exactly on `cols * cellWidth` puts that division on a boundary
  where an error of one ulp costs a whole column, and a terminal one column
  narrower than the stream it is fed wraps every line. Rounding up and adding
  half a point clears the boundary by far more than any float error and far less
  than a cell.
- **Rotation no longer reopens the stream.** The size asked for is the pane's,
  not the phone's, so turning the device changes only how much of it is visible.
  A stream opened at the *fallback* size does still reopen, because that one is
  cropped to the phone.
- **The pane's own scrollback is not reachable, and that is the price.**
  `TerminalView` is a `UIScrollView` that uses its own `contentOffset` to choose
  which buffer lines to draw, so it cannot both scroll through history and be
  panned bodily by an outer scroll view — two scroll views competing for one
  drag makes the pane unmovable. Its scrolling is off; the outer one pans the
  whole 142×47 grid. Scrolling *history* should not be a local gesture anyway:
  the host tracks it per pane (`pane list` carries `scroll.offset_from_bottom`
  and `max_offset_from_bottom`) and `terminal.scroll` exists as a stdin record.
  **Resolved: `observe` ignores it** — sending one returns a single frame and
  nothing on stderr, not even the "input ignored" a bad record earns on
  `control`. Local scrollback is no answer either: an `observe` frame is
  absolute cursor positioning and SGR colour with **zero newlines**, so nothing
  ever scrolls off into `TerminalView`'s buffer.
- **The screen is dark in terminal mode and the phone's own scheme in chat**,
  via `preferredColorScheme` on `PaneView`. The terminal draws its own black
  and its chrome has to sit on it; the chat is prose and belongs in whatever
  the user has set.
  - **The "hand it back" branch passes `nil`, not `\.colorScheme`.**
    `preferredColorScheme` is a preference that travels *up* to the
    presentation, so what it sets comes straight back down as the ambient
    value — read it and pass it on, and the terminal's `.dark` is re-asserted
    on every evaluation from then on. Opening the terminal once left the chat
    dark for the life of the screen, and popping it was the only way out.
    Measured both ways in `ColorSchemeTests`, which keeps the broken shape
    beside the fixed one as the reason the line is written the way it is.
- **A mode is a mode: one view on screen at a time.** Tried and rejected — the
  terminal as a permanent background with the chat on `glassEffect` over it.
  It looked good and could not be read: a conversation over a live 47-row grid
  is two things competing for the same pixels, and glass tinted by a black
  terminal leaves prose without the contrast it needs. Built, looked at on
  device, reverted. Do not re-propose it without a way to solve the contrast.
  - **Mounting the terminal is gated on it being asked for**, and that gate is
    what the glass layout could not keep. Opening the stream resizes the pane's
    pty (`stty`, below), so an always-live background would reflow the user's
    pane on their Mac every time an agent screen was opened to read the chat.
    Once asked for it stays mounted — hidden by `opacity`, with `isActive`
    false alongside, since a hidden view still lays out and a size reported
    from one is that same write on behalf of nothing. Hidden, the view keeps
    its buffer but **not its stream**: `PaneModel.setActive(false)` releases
    the pane, so reading the chat does not hold the Mac's input.
- **Scrollback: measured properly, 8 Sept 2026, in a disposable session.** An
  earlier note here said "a pane's history is reachable only through
  `pane read`", and a later one over-corrected to "an agent pane has no
  scrollback, at all". Both were wrong in different directions. What is true:
  - **Herdr keeps real scrollback for a normal-screen pane.** `seq 1 200` into
    a 30-row pane left `max_offset_from_bottom: 172`, and `pane read --source
    recent --lines 500` returned **202 lines** against `visible`'s 30. So
    `pane read` *is* a history source, and `recent-unwrapped` returns it
    without the host's wrapping — the only form that reflows to a phone.
  - **`experimental.pane_history` is not the switch.** Measured with it `true`
    and `false`: 172 rows of scrollback either way. It is a red herring for
    anyone who finds it in `config.toml` while looking for this.
  - **But the stream never carries scrollback, and that is the load-bearing
    fact.** The same pane, which had genuinely scrolled 200 lines, sent four
    frames over `terminal session control` — one full repaint and three deltas
    — and **every one had LF=0 and CR=0**, each exactly the 30-row viewport.
    Herdr renders its own buffer and ships absolute cursor positioning. So
    nothing is ever pushed off the top of SwiftTerm's viewport and its
    scrollback — which is implemented, and enabled — stays empty by
    construction. **This is not a sizing problem and not a SwiftTerm setting.**
    No client of this API can grow a scrollback from the stream.
  - **The `work` session's agent panes have none on the host either**: all ten
    report `max_offset_from_bottom: 0`, and `visible`/`recent`/
    `recent-unwrapped` each return exactly the 47 visible rows. Herdr's own
    `--skill` doc names the cause — "the pane is probably running the agent on
    the terminal's alternate screen. Rows that leave the alternate screen do
    not enter Herdr's host scrollback" — so for these panes there is nothing to
    fetch, at the Mac or anywhere else.
  - **What you scroll at the Mac is the agent, not the terminal — and that is
    the whole answer.** Proved with `less`, a classic alternate-screen pager,
    on `seq 1 200` in a 30-row pane: `max_offset_from_bottom: 0` and
    `pane read --source recent` returned **30 lines, not 200** — the same
    signature as every Claude Code pane. Then two spaces were sent as
    `terminal.input`, and the visible buffer went from rows **1–29 to 59–87**
    while the scrollback stayed 0. The earlier content is in *the program*, and
    the only way to see it is to ask the program. (Asking it is
    `terminal.scroll`, which herdr hands to such a program as a wheel event —
    see **`terminal.scroll`, not keys and not wheel bytes** below.)
  - **So the phone can have it, at a price: it takes input ownership.** Built
    — see **Scrolling a pane** below. `observe` is read-only and sends nothing,
    which is exactly why the pane looks frozen at the current screen.
  - **There is no half measure *on this stream*, and this was measured.**
    Against a pane another client held, a `terminal session control` client
    **without** `--takeover` received **no frames and landed no input** — no
    error, no stderr, the screen simply did not move. The same client with
    `--takeover` moved the program from rows 1–29 to 30–58. A `control` attach
    that is not a takeover is silently inert.
    - **The last clause of this bullet used to read "so any design that hoped
      to send a key without seizing the pane is not available", and that is
      false.** It generalised a measurement of the *terminal stream* into a
      claim about herdr, and there is a second surface: `herdr agent send-keys`
      — see **Answering an agent's dialog**. The stream half stands; the
      generalisation never should have been written.
  - **Settled inside SwiftTerm, 8 Sept 2026, because "surely there is a
    setting" is the question that keeps coming back.** There is one, it is on,
    and it works. The same `TerminalView` the app mounts, in one test:

    | fed | newlines | `canScroll` | top visible row |
    |---|---|---|---|
    | 200 ordinary lines | 200 | **true** | 168 |
    | a real pane's stream | **0** | **false** | 0 |

    The second row is `Fixtures/terminal-observe-scrolled.ndjson`, captured
    from a pane that had *genuinely scrolled 200 lines* with 172 rows of
    scrollback on the host. `isCurrentBufferAlternate` is false for it too — so
    it is not even the alternate screen at this end. The emulator is on its
    normal buffer with exactly one screen in it, because one screen is all it
    was sent. `ScrollbackTests` pins both rows.
  - **The alternate screen is pty state, not per-client.** One buffer, rendered
    by herdr, identical for every viewer — so there is no per-client scrollback
    to enable and no SwiftTerm option that could differ between the Mac and the
    phone. SwiftTerm's scrollback is implemented and on; nothing is ever
    written into it.
  - **Therefore**: a history view over `pane read --source recent-unwrapped`
    would show real history for a plain shell pane and nothing beyond the
    current screen for an agent. What holds an agent's history without touching
    input is its transcript, which is what chat mode reads.
    `HerdrClient.paneText` already wraps the command; nothing in the app calls
    it.
## Scrolling a pane (Phase 3, the first piece of input)

The first thing Bleat sends to a host. It used to be two page keys; it is
`terminal.scroll` now, which is what a wheel sends through herdr's own TUI.

### The terminal always holds the pane (1 Oct 2026)

**There is no observe mode any more.** `PaneModel` opens `control --takeover`
whenever the terminal is on screen, and the "Take control" button and its
confirmation are gone. Everything the terminal is for sends — scrolling,
answering a dialog, typing — and a read-only terminal with a confirmation in
front of each of those was a step on every visit for the one screen whose job
is to act. Decided by the user; the cost is stated here so it is not
rediscovered as a surprise.

- **Nothing shows who holds the pane — a known gap (15 Oct 2026).**
  CLAUDE.md's architecture rule says to surface who holds control, and Phase
  3 lists a takeover indicator; neither is met. When the terminal always takes
  the pane, the person it is taken from is at the Mac, not on the phone, so an
  indicator on the phone answers the less urgent question. Recorded so it is
  not described as shipped: an early README and store listing did.
- **Whoever is typing at the Mac loses input** the moment the terminal is
  chosen, with nothing on the phone asking first. The confirmation used to be
  the whole safety story; now choosing the terminal *is* the gesture. The chat
  remains the default mode, and it touches nothing.
- **Held only while on screen.** The terminal stays mounted under the chat so
  switching back is instant, and holding the pane through that would take it
  from the Mac for a whole visit spent reading. `PaneModel.setActive(false)`
  sends `terminal.release` and closes the stream; `setActive(true)` takes it
  back, and the takeover's first frame repaints in full. `PaneView` calls it
  from `.task(id: mode)`, before anything there suspends.
  - **`start()` refuses while hidden**, because a hidden view still lays out
    and a layout pass reaching `show()` would otherwise take the pane for
    nobody. `PaneControlTests` pins it against a peer with no endpoints —
    a model that tries to open fails instead of sitting in `.opening` — and
    was **checked against the bug**: with the guard removed, "a hidden
    terminal does not take the pane" fails.
  - **The release goes out before the next takeover.** `suspend()` keeps the
    task sending it in `letGo` and `run()` awaits it first, so a quick flip
    back cannot have the old stream's release land after the new stream has
    taken the pane.
  - `setActive(true)` calls `start()` itself rather than waiting for a layout
    pass: an unchanged grid is de-duplicated in `report`, so nothing else would
    reopen.
- **Release on leaving**: `close()` sends `terminal.release` **before
  cancelling the reader**, or there is no live stream left to send it on and
  herdr holds the pane for a phone that has gone in a pocket.
- **`PaneKeyBar` is unconditional now**, which settles the cost its section
  records: taking and releasing used to add and remove the bar, reopening the
  stream twice per gesture. With no toggle, the bar's 3 rows are a constant.
- **Input with no stream is dropped**, not queued — opening, hidden or ended.
  That replaced the old "not while observing" gate.
- `HerdrClient.observe` stays, for `bleat attach` without `--takeover`; the app
  no longer calls it.

### `terminal.scroll`, not keys and not wheel bytes (measured on 0.9.3, 30 Sept 2026)

**The question that started it:** Termius or iTerm2 attached to herdr scroll
an agent's history with a swipe, so why could the phone not? Not SwiftTerm.
Inside a multiplexer a terminal's own scrollback is barely used; the swipe
becomes wheel events, the multiplexer scrolls, and the terminal paints what it
is sent. Bleat was sending Page Up instead — and from `observe`, nothing.

Measured in a scratch session, over `control --takeover`, one record at a time:

| pane | `terminal.scroll` | raw wheel bytes (`ESC[<64;x;yM`) |
|---|---|---|
| shell, 172 rows of host history | **moves herdr's history** by `lines` (rows 172… → 132–161 after 2×20) | **typed at the prompt** as `64;10;10M` |
| `less --mouse` (alternate screen) | **one wheel event per record**, `lines` ignored | scrolls, one line per event |
| Claude Code, after printing 1–150 | **scrolls**: 10 records moved it as far as 10 wheel sequences (119–150 → 101–132) | scrolls, the same |
| shell with nothing to scroll | nothing — no frame, nothing typed | (typed, as above) |

So **herdr decides what a scroll means**, exactly as its TUI does for a wheel,
and `terminal.scroll` is the one record that is right everywhere.

- **The phone cannot make that decision itself, and both candidate signals
  were checked.** herdr repaints from its own buffer, so a program's mouse
  modes (`?1000h`, `?1006h`) **never appear in the frames** — captured from
  `less --mouse`, only `?2026` and `?25`. And `max_offset_from_bottom` is 0
  both for a program on the alternate screen and for a fresh shell with less
  than a screen of output, where wheel bytes would be typed. Sending raw wheel
  bytes would therefore mean guessing, and guessing wrong types into a shell.
- **Claude Code answers the wheel, and accelerates.** A burst of ten moves it
  further than ten separate notches, and the first event after a change of
  direction is often swallowed. That is the program, not herdr — raw wheel
  bytes behave the same.
- **`observe` still ignores the record**, so scrolling costs control — which
  the terminal now always holds.

What the app does with it:

- **`PaneModel.scroll(_:notches:)`** sends one `.scroll` record per
  notch through the same ordered queue as keystrokes (`outgoing` holds
  `TerminalCommand`s now), and dropped like everything else when there is
  no stream. One record per notch rather than one record carrying the whole
  distance in `lines`, because a full-screen program gets one wheel event per
  record whatever `lines` says and the phone cannot tell which kind of pane
  it has. One line a notch.
- **A drag is continuous, a row for a row (1 Oct 2026).** `PaneScrollGesture`
  sends a one-line notch per row of finger travel, so a shell's history
  follows the finger exactly; a full-screen program scrolls by its own amount,
  so there the match is approximate. It was a three-line notch per three rows,
  which moved a shell the same distance in visible jumps. At most six notches
  per callback. Pulling **down** is scroll up, the direction a scroll view
  moves content with the finger. `TerminalView.isScrollEnabled` stays off: its
  own buffer never fills, and on it would consume the drag.
- **A flick coasts (1 Oct 2026).** The question was why Termius feels better
  attached to herdr than this did. Not a buffer — inside a multiplexer it has
  none either. A desktop or Termius swipe goes on producing wheel events while
  it decelerates; this stopped dead when the finger lifted and threw away
  whatever the burst limit had not sent. `ScrollMomentum` is that tail: the
  drag's lift-off velocity, decayed at `UIScrollView`'s normal rate (0.998 a
  millisecond), emitting notches until it falls under 60 points a second. It
  is a value type with no clock, integrated exactly, so the distance does not
  depend on the frame rate and `ScrollMomentumTests` needs no waiting.
  - Held to 150 notches a second. Each one is a record the host repaints for,
    and a queue that outlives the gesture would go on scrolling after the
    user stopped. **Not measured against the host** — how many scroll records
    a second herdr keeps up with over SSH is unknown, and this is a guess to
    tune on a device.
  - **Only a vertical flick coasts.** A sideways swipe lifts off with a few
    hundred points a second of vertical speed, which is over the floor; the
    coast starts only when the lift-off velocity is more vertical than
    horizontal.
  - **The coast does not wait for its writes, and a scroll is dropped when 30
    commands are already queued.** Awaiting each write stretched a two-second
    coast over however long a slow link took. Keys are never dropped; a
    scroll is a request about now. Neither path has been exercised on a slow
    link.
  - A finger put down stops it — a second, simultaneous
    `DragGesture(minimumDistance: 0)`, because the scrolling drag only wakes
    after sixteen points. So does the pane leaving `.live`.
  - **Still not a scroll view, and it cannot be.** No rubber band at the ends
    (`max_offset_from_bottom` is not a usable extent), and nothing moves
    between rows: every step is a repaint from the host.
- **The step is the terminal's row height, reported by the terminal.** It was
  the surface's height over the grid's rows, and with the keyboard up the
  surface halves while the grid is frozen — so a drag scrolled about twice too
  fast while typing. `PaneTerminalController.onRowHeight` reports the height
  SwiftTerm draws a row at, and `PaneModel.rowHeight` holds it.
  - **That height is recomputed from the font, not divided out of the frame.**
    SwiftTerm's `cellDimension` is internal. It takes `Int(height /
    cellHeight)` rows and leaves the remainder as a strip at the bottom, so
    `frame.height / rows` is a fraction of a point too large — caught in
    review, where it put the keyboard anchor between rows and between pixels.
    `PaneTerminalController.rowHeight` repeats `computeFontDimensions`:
    `ceil(ascent + descent + leading)`. It assumes SwiftTerm's default line
    spacing of 1.
- **The two scroll buttons are gone (1 Oct 2026)**, at the user's request
  once the drag coasted: they sat over the pane's right edge and the drag now
  does the job better. `PaneScrollControl` is deleted, and `scroll` lost its
  `lines` parameter with its only other caller — every notch is one line.
  **What went with them is the only scroll VoiceOver and Switch Control could
  reach**; a drag is not reachable by either. Nothing replaces that yet. An
  accessibility scroll action on the terminal is the obvious candidate and is
  untried.
- **`TerminalKey.pageUp`/`pageDown` are gone.** Nothing sent them any more;
  whether Claude Code answered Page Up was never verified and no longer
  matters.
  - **The gesture must never be behind an `if`.** Branching builds a
    `_ConditionalContent`, and switching branch changes the structural identity
    of what it wraps — `TerminalHost`, a representable — so the controller would
    be torn down, losing the rendered buffer. It is unconditional now; if it
    ever needs a gate, `.gesture(_:including:)` is the way.

- **The reader mode is gone.** `PaneView` offered a third reading — a
  `pane read` snapshot reflowed to the phone — and it is removed: view,
  previews, sample text and render test. It was lossy in exactly the way that
  mattered, since a pane is a grid of absolutely positioned cells and anything
  wide came back re-wrapped into nonsense, and the chat answers the question it
  was really being opened for while genuinely reflowing. Two modes now, chat
  and terminal.
  - **`HerdrClient.paneText` and the `PaneText` model stay**, with their
    fixture-backed tests. They wrap `pane read`, which is the *only* route to a
    pane's history — the bullet above — and that is a Phase 3 question rather
    than something to delete now. Nothing in the app calls one today, so it is
    library surface with no caller: worth knowing before reading it as live.
- **The size badge is gone (1 Oct 2026)**, also at the user's request. It
  named the grid in the corner (`53×40`) and said "cropped" when the pty could
  not be resized and `--cols` was cutting the pane off. `GridBadge`,
  `PaneModel.isCropped` and `PaneModel.paneGrid` are deleted with it. **The
  cropped case still happens and is now silent**: a pane whose host will not
  report a layout, or whose `stty` fails, renders cut off at the right with
  nothing to say why.
- **`BleatUI` has a test target now** (`Tests/BleatUITests`), which is what the
  cell arithmetic above needed: several sizing bugs on this screen shipped past
  a green run because nothing mechanical ever laid the view out. It needs a
  simulator destination — `swift test` runs the parts that compile for macOS
  and skips the UIKit ones — so the full check is
  `xcodebuild test -scheme BleatKit-Package -destination 'platform=iOS Simulator,…'`
  from `BleatKit/`. `PaneLayout` and its lookup are covered from the captured
  fixtures, including a real split tab.

Not taken: fitting the full width to the screen (~2.8pt type, not viable), or
keeping the crop and merely labelling it. A genuine resize via `control` is not
on the table either — it does not exist, per the section above. The phone-shaped
answer is a session whose *own* geometry is phone-shaped, set by
`server.headless_cols`/`headless_rows` on the host.

Resolved by the same probe: two clients of different sizes attaching to one
session do **not** fight, and nothing shrinks to the smallest as tmux would.
Each gets its own cropped or padded viewport onto one unchanged grid.

- **Frames that arrive before the renderer exists are held, not dropped.** The
  first frame is the full-screen replay, and on an idle pane nothing follows it
  — losing it leaves a blank screen until something changes on the host, which
  may be never.
- **The terminal refuses first-responder status; it does not disable
  interaction.** `isUserInteractionEnabled = false` looks like the way to keep
  the keyboard away and also kills scrolling, which is most of the point of a
  read-only pane. `TerminalView` raises the keyboard from its own tap and
  long-press recognisers, so overriding `canBecomeFirstResponder` is what stops
  it while leaving the scroll view alone.
- **Read the terminal's size after forcing its layout, and take `sizeChanged`
  as authoritative.** `TerminalView` recomputes cols and rows in its own
  `layoutSubviews`, which runs *after* the hosting controller's
  `viewDidLayoutSubviews`, so reading it there without `layoutIfNeeded()`
  reports `TerminalOptions`' default 80×25 — a size the view cannot show, asked
  of the host for the life of the screen. `sizeChanged` is fired from
  `processSizeChange` when the *view's* geometry changes what fits, whatever the
  protocol's own documentation says about remote requests for 132 columns; it is
  the correctly-timed answer and ignoring it is how a wrong size goes
  uncorrected.
- **Closing the previous stream happens alongside the new dial, not before it.**
  `SSHStream.close()` waits up to a second for output to drain and an `observe`
  stream never ends on its own, so that second is always spent — serially, it
  would delay every rotation by a full second behind a stale screen.
- **Every `TerminalViewDelegate` method is a no-op, deliberately.** The protocol
  has no default implementations so each must be written out, and three are
  refusals rather than omissions: `send` has nowhere to go until Phase 3,
  `clipboardCopy` would let a remote pane write to the phone's pasteboard, and
  `requestOpenLink` would let anything a pane prints send the phone to a URL of
  its choosing.

## Answering an agent's dialog (Phase 3, built 10 Sept 2026)

**A blocked agent is one sitting at a question, and until now the phone could
not answer it.** Found the ordinary way: a session started from the phone, a tab
added, `agent start` run — and Claude Code came up on its workspace-trust
prompt, `blocked` with `launch_pending: true`, exactly the row shape this file
already documents.

**`herdr agent prompt` cannot answer one.** herdr's own `--skill` doc states it:
it *"rejects an agent already waiting at an approval or question dialog with
`agent_blocked` before sending any input"*, and adds the instruction this design
follows — *"Inspect the blocked UI and ask the user before answering it."* So the
prompt composer, which Phase 3's gate line names, is structurally unable to move
a dialog. Keys are.

`PaneKeyBar` is those keys: left, up, down, right, `esc`, Enter, in a glass
capsule in the terminal's bottom safe area, shown only while this screen holds
the pane. Glyphs throughout except `esc`, which is a word on every keyboard that
has one.

- **The arrows are the normal-mode forms (`ESC [ A`…), not the application-cursor
  ones (`ESC O A`), and that was measured rather than read.** A program with
  DECCKM on is sent the `O` form by a real terminal, and picking wrong gives a
  dialog that ignores every tap — a failure indistinguishable from the key not
  being handled. Sent over a real `terminal session control --takeover` against
  the live trust dialog, `ESC [ B` moved its selection from `No, exit` to `Yes,
  I trust this folder`. `TerminalKeyTests` pins the byte *and* its base64
  (`G1tC`), so the test and the thing that was verified cannot drift.
- **Enter is CR (`0x0D`), not LF.** Return sends carriage return on a pty; the
  line discipline is what turns it into a newline. An Ink-based TUI — which
  Claude Code is — reads a bare LF as a newline *inside its composer*, so `\n`
  would type into a dialog rather than answer it.
- **The trust dialog's default selection is `No, exit`.** So "just send Enter"
  ends the agent. Any future one-tap affordance has to move the cursor first and
  confirm where it landed; this is why the bar is six honest keys and not a
  Yes/No pair.
- **It is a bar, not an overlay.** A floating pill over the bottom of a terminal
  covers the pane's last row — which is the input line, and on a dialog is
  literally `Enter to confirm · Esc to cancel`. `.safeAreaBar(edge: .bottom)`
  insets instead. **That is not free**, and an earlier draft of this bullet
  claimed it was, on the strength of a design that no longer exists: the
  terminal is `terminalView.frame = view.bounds` with the pty resized to match,
  not a pane-sized grid inside a scroll view. So the bar changes the grid in the
  *ordinary* case — 46 rows without it, 43 with. While control was a toggle,
  each take and release therefore reopened the stream twice; the bar is
  unconditional now, so its height is simply part of the grid.
- **No text entry, deliberately.** Typing is `agent prompt`'s job — it handles
  bracketed paste and ordered submission — and what the phone lacked was only the
  *navigation* of a dialog already on screen.
- **It must never be gated on `phase`.** (It was gated on control while that
  was a toggle; it is unconditional now.)
  This is the sharpest edge on the screen and it reached a device. The terminal
  derives its grid from its own bounds (`terminalView.frame = view.bounds`), so
  anything occupying the safe area makes it shorter, which reports a new grid,
  which reopens the stream and `stty`s the pane. Adding `phase == .live` to the
  condition therefore closed a loop: bar shows → terminal shrinks → reopen →
  `.opening` → bar hides → terminal grows → reopen → `.live` → bar shows, with a
  write to the user's Mac every time round. It surfaced as **"taking control
  spins the loader forever"**.
  - Measured by the regression test: **46 rows without the bar, 43 with it**, so
    the grid alternated 43 ↔ 46 and never settled.
  - The state overlays carry the same `phase` test *safely*, which is what
    makes this easy to copy wrongly: they are `.overlay`s, and an overlay draws
    without changing layout. **Anything in a safe area is layout, and layout
    here is the stream's size.**
  - So per-phase chrome on this screen has to be an `.overlay` or `.disabled` —
    the bar greys out between opens rather than disappearing.
  - `PaneGeometryTests.chromeIsStableAcrossPhases` pins it, and was checked
    against the bug rather than only against the fix: with the gate restored it
    fails on all three of `.opening`, `.ended` and `.failed`. It hosts the view
    in a **key window**, for the reason `PreviewSmokeTests.render` does — a
    hosting controller merely given a frame never lays the representable out and
    reports no grid at all, which is a green test that measures nothing.

**`herdr agent send-keys <agent> <key>...` exists, and it does not need a
takeover.** This is the surface this file previously denied existed (see the
correction under **Scrolling a pane**). Measured against the live blocked agent
by sending `down` and then `up` to put it back:

| | |
|---|---|
| needs `--takeover` | **no** |
| needs a terminal stream | no |
| changed `focused` | no |
| an unsupported key | `invalid_key`, rejected **before any byte is written** |

`PaneKeyBar` does **not** use it, and that is a deliberate deferral rather than
an oversight: the bar lives in the terminal view, whose whole model is the
stream the screen already holds, and mixing a second input path into it would
mean two ways of sending a key with different ownership semantics. The case
`send-keys` genuinely unlocks is **answering a blocked agent from the agents
list without opening or seizing the pane at all** — no confirmation, because it
takes nothing from anybody. That is worth building, and it is a different
screen.

The wider family was found at the same time and none of it is wrapped yet:
`agent get`, `agent read`, `agent wait --until blocked`, `agent explain`,
`agent rename`, `pane run`, `pane wait-output`.

**There is no structured dialog anywhere in the API.** Checked all three places
it could be: `agent get` carries only `blocked` + `launch_pending`; `agent
explain` names the matched rule (`live_blocked_form`, `region=
after_last_horizontal_rule`) and a truncated text excerpt; `agent read --source
detection` gives the region as **text**. Nothing hands out
`{question, options[], selected}`.

- **`--source detection` crops to the dialog only because of which rule
  matched.** On the blocked agent it was **21 lines — the dialog and nothing
  else**; on an idle agent the same source returned all **47**. Useful, but it
  is a consequence of the rule's region, not a promise about dialogs.
- **So a native `Picker` means parsing that text**, which would be a second copy
  of herdr's own versioned detection manifests (`claude.toml 2026.09.04.1`, one
  per kind, 23 of them) — the drift argument this file makes about
  `EndpointDiscovery`. Worse, **the submit is relative**: there is no "select
  option 2", only N arrows from wherever the cursor is, so correctness would
  depend on the parse being right about both the options *and* the current
  selection, and Enter on the wrong row is unrecoverable.
- If a Picker is ever built, the safety must come from **confirming, not
  parsing**: move the cursor, re-read the region, verify `❯` is on the intended
  row, and only then send Enter — falling back to the raw region when it did not
  land. That is this codebase's existing "the result is checked, not assumed"
  shape.

## Typing into a pane (Phase 3, built 10 Sept 2026)

The keyboard, which is the rest of the Phase 3 gate line. `PaneTerminalView`
(was `ReadOnlyTerminalView` — the refusal is a switch now, still off by default)
takes first responder while the pane is held, and
`TerminalViewDelegate.send(source:data:)` forwards what SwiftTerm produces
straight to `PaneModel.send(bytes:)`. **The bytes are never inspected**: they
are what a terminal would have sent, and filtering them would break the very
sequences an agent's UI is driven by. `.bytes` not `.text`, for the reason
`TerminalKey` travels that way — a raw ESC is not legal in a JSON string.

**The keyboard would have resized the user's pane, and that is the whole
design.** This terminal derives its grid from its own bounds and the pty is
`stty`'d to match, so a keyboard covering half the screen takes a pane from ~46
rows to ~24 on the way up and back on the way down. That is a live Claude Code
reflowing on someone's Mac because a phone user tapped a key. Measured by
disabling the fix: **one show/hide round trip reports three grids** — three
stream reopens and three writes to the host.

So the grid is **frozen** and the terminal is **translated, not resized**: it
keeps its full frozen height, slides up under the navigation bar, and has its
top clipped by the view (`clipsToBounds`). The grid never changes and nothing
is written to the host.

- **It slides only as far as the last row in use (1 Oct 2026).** It used to be
  pinned by its bottom edge, always, on the reasoning that the bottom of a pane
  is its input line. True of an agent; false of a shell, whose prompt is
  wherever its output has got to. A shell with three lines in it had its
  prompt slid off the top of the screen by the keyboard raised to type into
  it. `KeyboardAnchor.offset` now lifts the terminal just far enough to clear
  the lowest row that is the cursor's or has something drawn on it, plus one
  row of margin, in whole rows, and never past the old bottom-pinned position.
  - **Cursor and content, because neither is enough alone.** An empty prompt
    has only a cursor; an agent may park or hide its cursor anywhere above
    its status lines, and what marks the bottom of its screen is the last row
    it drew. A screen drawn to the bottom therefore behaves exactly as before.
  - "Drawn" means a visible character: herdr paints blank cells as spaces as
    readily as it skips them.
  - It follows output: `rangeChanged` asks for a layout pass when the anchor
    has moved, so a command that prints ten lines takes the terminal ten rows
    up with its prompt. Only the origin changes — nothing is reported.
  - Pinned by `KeyboardAnchorTests` and three cases in `PaneGeometryTests`.
    **Not yet seen against a real shell on a device.**

- **Frozen before the keyboard animates in, thawed on `keyboardDidHide`.**
  Not `willHide`: unfreezing on the way down reports a grid per frame of the
  dismissal animation. On the way back up the restored grid equals the one it
  left, so `report`'s own de-duplication swallows it and nothing reopens.
- **`PaneGeometryTests` pins both halves**, and both were checked against the
  bug rather than only the fix — with the freeze removed they fail at 2 and 3
  reports respectively.
- **Raised by an explicit control, never by tapping the pane** — now "Type in
  the Pane" in the accessory's mode menu. A tap on
  a surface whose whole job is to be dragged is easy to trigger by accident, and
  the cost is keystrokes into a live agent. The button is also the only version
  VoiceOver and Switch Control can reach.
- **`PaneKeyBar` stays in the safe area, and that is also the bar that rides the
  keyboard.** SwiftUI's keyboard avoidance lifts a `safeAreaBar` clear by
  itself, so one bar covers both cases: nothing appears, disappears or has to be
  kept in step, and the bar cannot vary with anything (which is the rule the
  spinner bug wrote).
  - **It was a `UIKit inputAccessoryView` for a day, and the device said no.**
    Riding the keyboard put the keys hard against the bottom edge, a reach away
    from the arrows they belong beside. `KeyBarAccessoryView` is deleted.
  - **The keyboard toggle lives in the bar too**, for the same reason: in the
    toolbar it sat at the opposite corner from the keys it governs.
  - **SwiftTerm's own accessory has to be taken off**, or its Esc/Tab/Ctrl bar
    rides the keyboard under ours. It installs a `TerminalAccessory` from its
    `setup()`, so `PaneTerminalView.dropBuiltInAccessory()` nils it once.
    **Assigned, not overridden**: `TerminalView.inputAccessoryView` is a settable
    `public override var` backed by SwiftTerm's own storage, so a subclass
    override is refused outright.
  - **The keys are disabled between stream opens; the toggle is not.** A
    keyboard that cannot be dismissed because the stream is reopening is half a
    screen gone with no way back.
- **The keyboard comes down with the pane.** Hiding the terminal and `close()`
  both clear it, and so do a stream that ends or fails: one left up over a pane
  this screen no longer holds would drop every keystroke in silence.
  - **And with the *mode*.** Switching to chat leaves `PaneSurface` mounted at
    `opacity(0)`, which does **not** resign first responder — so the keyboard
    stayed up over the transcript with its only dismiss button hidden behind it,
    and anything typed still reached the live agent. `wantsKeyboard` is passed
    into `TerminalHost` as `model.wantsKeyboard && isActive`, and `PaneView`
    clears the flag outright when the mode changes.
  - **`wantsKeyboard` is passed in, not read off the model inside
    `updateUIViewController`.** Nothing in `PaneSurface.body` reads it, so
    flipping it invalidates only `PaneKeyBar` — a child, whose re-render need
    not drive a representable update. It worked, by accident; `isActive` is
    passed in for this exact reason and the comment saying so was three lines
    above the code ignoring it.
- **Input is serialised, and this is not theoretical.** Every keystroke used to
  get its own unstructured `Task`. Each runs on the main actor only until
  `stream.send` suspends, after which any number are inside `SSHStream.send` at
  once with nothing sequencing the writes — fast typing could transpose two
  characters into a live agent, and SwiftTerm's `paste` calls `send` **three
  times in one runloop turn** (bracketed-paste start, text, end), so the markers
  could land around or after the payload they wrap. `PaneModel` queues and
  drains one at a time, and `start()` clears the queue so a key typed at a dead
  stream cannot arrive at its replacement.
- **`allowMouseReporting` is forced off.** Taking the keyboard re-arms it:
  SwiftTerm gates its tap and pan handlers on `isFirstResponder` and the flag
  defaults to true, so once a pane can be typed into, a tap on it sends a mouse
  press to any program in mouse mode — on an agent at a dialog, a click on one
  of its buttons. That is precisely the accidental input the "a button, not a
  tap on the pane" rule exists to prevent.
- **The freeze has two ways out, because one was not enough.**
  `keyboardDidHide` is the normal path, but with a hardware keyboard no software
  keyboard appears and no notification is ever posted — and SwiftTerm's own
  accessory, which might have shown one, has been removed. The grid would then
  stay frozen for the life of the screen. `thawIfIdle()` also runs on the
  down-edge of `wantsKeyboard`, and **a width change thaws it too**: the frozen
  size holds the width, so rotating with the keyboard up drew a 393pt terminal
  in an 852pt view — a strip with black beside it, measured at 53 columns in
  landscape — until the keyboard went down.
- **Ctrl and Tab were unreachable while typing until 1 Oct 2026.**
  `dropBuiltInAccessory()` removes SwiftTerm's `TerminalAccessory`, which was
  the only source of both, and the iOS software keyboard has neither key. The
  shortcut strip is the answer — see **The accessory** below.

**`swift build` does not compile any of this.** Every file under `Pane/` is
`#if canImport(UIKit)`, and `swift build` targets macOS — so the whole screen is
compiled out and a green `swift build` says nothing about it. This was found the
obvious way: a renamed type left a dangling reference that built clean twice.
Use `xcodebuild -scheme BleatKit-Package -destination 'generic/platform=iOS'`,
or the simulator test run, which is what actually compiles it.

## The accessory: a text field, shortcuts, and the dialog keys (1 Oct 2026)

`PaneKeyBar` was one row of six keys and a keyboard button. It is a two-row
bubble now. The bottom row is those same keys — arrows, `esc`, return — and a
control that chooses what the top row holds (`PaneAccessoryMode`): a **text
field** or a **shortcut strip**. The choice is remembered across panes and
launches.

**Three ways to type, each for something.**

- **The text field** (`PaneInputField`), for a line composed with the system
  keyboard — autocorrect, dictation, a cursor under the finger — and sent whole
  with Enter after it. Tapping it raises the keyboard; nothing reaches the pane
  until it is sent.
- **Straight into the pane** — "Type in the Pane" in the mode menu — for what
  only the program can do: zsh or fish completion, `vim`, anything read a key
  at a time. This is the old keyboard button's behaviour, and the shortcut
  strip shows above the keyboard while it is up whatever mode is chosen,
  because Tab is the point of typing there.
- **The shortcut strip** (`PaneShortcutStrip`), for a key with no text around
  it.

While either keyboard is up the mode control is a **hide-keyboard** button
instead of a menu.

**What a sent line is, measured.** On a scratch session on herdr 0.9.3, over a
real `terminal session control --takeover`:

- zsh ran `echo …` and Claude Code submitted a prompt, both with text and
  carriage return in **one** record and with them in **two**. Two is what
  ships (`SubmittedLine`), queued as one batch so nothing lands between them.
- **One line only.** A newline is Enter to whatever reads it. Bracketed paste
  carries several lines as one — Claude Code took `ESC[200~a\nb ESC[201~` then
  CR as a single two-line prompt — but only a program that asked for it
  understands the markers, and **herdr does not pass `?2004h` through in its
  frames** (only `?25` and `?2026` appeared, at a zsh prompt that sets it). The
  phone cannot tell, so line breaks become spaces. A multi-line field would
  need that signal, or a guess.
- **An empty field sends nothing.** A bare Enter commits an agent's dialog; it
  has its own key on the bottom row.
- The draft is cleared only if there was a live stream to send it on. That
  is a check, not an acknowledgement: a stream that reopens or dies between
  the tap and the write still loses the line, or types it without its Enter.
- **The field is a `UITextField` (`PaneLineField`), because SwiftUI cannot turn
  Smart Punctuation off.** Caught in review before a device saw it: it is on by
  default and rewrites `--oneline` to `—oneline` and `"fix"` to curly quotes a
  shell reads as letters, so the line that ran would not be the line typed.
  Autocorrect stays — it offers, where smart punctuation substitutes. Return
  answers false from `textFieldShouldReturn`, so the keyboard never drops
  between lines; a SwiftUI field gives up focus on Return, and a keyboard that
  hides posts the `keyboardDidHide` that thaws the grid.

**The shortcuts**, in `PaneShortcut.all`: `⌃C`, `⌃C ⌃C`, `tab`, `⇧tab`, `⌃R`,
`⌃O`, `⌃U`, `⌃L`, `⌃D`.

- **`⌃C ⌃C` exits Claude Code**, measured: two `0x03`, 300ms apart, took an idle
  one back to the shell and printed its resume line. One tap, drawn red, no
  confirmation — being one tap is what it is for. Not measured: two in one
  write, and a Claude Code that is mid-turn, where the first Ctrl-C may be
  spent on the turn.
- `⇧tab` is `ESC [ Z`; in Claude Code it cycles the permission mode. `⌃O`
  expands folded output there. Neither was put on the wire.
- **No herdr shortcuts, and that is a guess about where input lands.** herdr's
  keybindings belong to its terminal UI; this stream's input is believed to go
  past that to the pane's pty, so a prefix key would arrive at the shell as a
  control character. Not measured.

**The bubble is one height whatever it holds**, because it is in a safe-area
bar and its height is therefore the grid (see the `PaneSurface` note on the
spinner loop). The top row's height is fixed on the container, not on either
row, and the field is a single line that does not grow.
`PaneGeometryTests.accessoryHeightIsConstant` pins all three states. The
bubble is one row taller than the bar it replaced, so a pane on a phone has a
couple of rows fewer than it did.

**The field's keyboard freezes the grid too.** `wantsKeyboard` was the only
keyboard on this screen and the freeze hung off it; the field raises one the
terminal never asked for. `PaneTerminalController` now also freezes on
`keyboardWillShow` — `will`, so the size is held before the first frame of the
animation — and counts the keyboard as up from then, so nothing thaws it on the
way in. `PaneGeometryTests.anotherKeyboardFreezesTheGrid`.

**One keyboard, one owner.** Focusing the field clears `wantsKeyboard`, or the
terminal takes first responder back on its next update. Switching to chat drops
the field's focus, for the reason it clears `wantsKeyboard`: the surface stays
mounted at `opacity(0)`, which resigns nothing.

**Not yet seen on a device**: the look of the bubble, and whether `keyboardWillShow` arrives before SwiftUI lays the
surface out shorter — the test posts the notification by hand.

## An agent over SSH cannot read the login keychain — out of scope (settled 12 Sept 2026)

**Do not build anything for this.** It was investigated at length, three features
were written and all three were removed. The conclusion is a macOS constraint, not
something a client can work around.

An agent started in a session the phone created reports:

```
⎿  Not logged in · Please run /login
   · Run in another terminal: security unlock-keychain
```

The chain, measured:

- Claude Code's whole test is `security show-keychain-info` exiting **36**
  (`errSecInteractionNotAllowed`, `-25308 & 0xFF`) — read out of the binary.
- That is a fact about **the asking session**, not the keychain. The same
  keychain answered **0, unlocked** in the desktop session at the same minute
  Bleat's SSH channel answered 36.
- Keychain unlock state is per security session, so a remote session starts
  locked whatever the desktop session holds open.
- **On this Mac it cannot be unlocked by hand either**: the login keychain's
  password has diverged from the account password, and `no-timeout` has kept it
  open at the desk ever since, so nothing has asked for it in years. Over SSH the
  passphrase is refused (`errSecAuthFailed`, **51**).
- **No SSH client can do it.** Confirmed on device: a Claude agent run directly
  from a Termius interactive session — a full pty — reports the same thing. So a
  pty is not the missing ingredient and there is no client trick to copy.

What works, and needs no code: **a server started from the desktop session gives
panes that can use the keychain** — measured, `security show-keychain-info`
answered `no-timeout` inside such a pane. So agents started in `work`, or in a
tab added to it, sign in. A session the phone created is the degraded case.

Three dead ends, each removed, so they are not rebuilt:

| tried | why it went |
|---|---|
| `SecuritySession` — compared audit sessions via `launchctl print pid/<pid>` | the theory was wrong; a phone-started server reported the *same* asid as the login session, and that reading may itself be an artifact for a process reparented to pid 1 |
| `bleat login-session` — a LaunchAgent starting the server in `gui/$UID` | the *effect* was probably right, but it is Mac-side infrastructure and the same result comes free from attaching to a session the Mac already runs |
| `LoginKeychain` + an "Unlock the keychain" button | asked for a passphrase that cannot help; and an unlock against an already-unlocked keychain returns 0 **whatever** passphrase it is given, so its own success check was worthless |

If it ever needs solving, the route that does not involve the keychain at all is
`claude setup-token` (a long-lived token, exposed to panes through the server's
environment) — a host auth decision, not a Bleat feature.

## A pane that stopped repainting, and what was ruled out (10 Sept 2026)

**Unresolved. Recorded so it is not investigated from scratch twice.** Reported
on device: with a pane held, typing landed and Enter worked, but the screen did
not visibly change until the pane was reopened or control released. It later
stopped reproducing without a code change, so the cause was never found.

What was *measured* and can be trusted:

- **herdr delivers.** A `terminal session control --takeover` stream sent 9
  frames while input was typed at it. Not a host-side problem.
- **The frames reach the renderer.** Device logging showed every frame arriving
  with a live sink and being fed — including the small 77B per-keystroke deltas
  and the larger redraws.
- **Feeding those exact frames repaints**, including while the keyboard has the
  grid frozen and the terminal translated to a negative origin, and the drawn
  viewport stays on the live screen. `PaneRepaintTests` pins this against
  `Fixtures/terminal-control-typing.ndjson` — real captured frames, because a
  synthesised one would lack the `ESC[?2026h`/`l` markers that make the case
  interesting.
- **Synchronized output is handled by SwiftTerm.** `queuePendingDisplay` and
  `updateDisplay` both early-return while `synchronizedOutputActive`, and herdr
  wraps *every* frame in those markers — but `endSynchronizedOutput` calls
  `refresh` and the delegate re-queues the display, so the pause is closed
  properly. This looked like the answer and is not.

Two things that cost time and are worth knowing next time:

- **`notifyUpdateChanges` is `false` by default**, so `rangeChanged` never
  fires and an attempt to use it as a repaint probe silently proves nothing. It
  is turned on now, which is what makes `PaneRepaintTests` possible.
- **`TerminalView.draw(_:)` cannot be overridden** (not `open`), so the paint
  itself is not directly observable from this side; the delegate callback is
  the only hook.
