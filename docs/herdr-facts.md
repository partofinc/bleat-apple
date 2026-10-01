# Herdr facts (verified live against herdr 0.8.2, 4 Sept 2026)

> Moved verbatim from `CLAUDE.md` on 1 Oct 2026. Where the text says "this file", "above" or "below", it means the old single file; a **bold** section name can be found with `grep -r docs/`.

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
- **All five agent states have now been captured live** (7 Sept 2026), in an
  isolated probe workspace in the `phone` session: `idle`, `working`,
  `unknown`, plus `blocked` and `done` in `Fixtures/agent-list-blocked.json`
  and `Fixtures/agent-list-done.json`. Unknown values must still decode, never
  throw.
- **`done` is not "finished". It is "finished, and nobody has looked."** Herdr
  defines it (`herdr --skill`) as "the same underlying idle state after unseen
  background work finishes", so `idle` and `done` differ by exactly one thing:
  whether the tab has been seen. Confirmed live in both directions — prompting
  an agent in an unfocused tab settled it to `done`, and `agent focus`
  collapsed it straight back to `idle`.
  - **Sort order in the UI is blocked → done → working → idle → unknown**, and
    this file used to say `done` came *last*. That buried the one row worth
    opening beneath every agent already dealt with. `blocked` and `done` are
    both waiting on a person; a `working` agent is making progress without one.
  - **Bleat must never call `agent focus`.** It is what marks a tab seen, so
    focusing from the phone would silently clear the `done` marker for whoever
    is at the Mac. A CLI *read* does not mark it seen — verified — which is
    what makes a read-only phone client safe here.
- A `blocked` row carries **no `agent_session` and no `interactive_ready`**;
  neither is known until the agent is past its dialog. It has `launch_pending`
  instead, which nothing reads. A required `agentSession` would have thrown on
  precisely the row the app most needs to show.
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
- `pane read` caps at ~1000 lines (undocumented). Don't build history views on
  it — and for an agent pane there is nothing to build one *from*; see
  **Scrollback: measured properly** in [`pane-view.md`](pane-view.md). Its
  `--source` takes
  `visible`, `recent`, `recent-unwrapped` or `detection`, and
  `recent-unwrapped` is the one worth knowing: the buffer without the host's
  wrapping, which is the only form that can be reflowed to a phone.
- Environment: use `HERDR_BIN_PATH`-style absolute paths when a login shell
  might not have `herdr` on PATH. Treat non-zero exit as an error with stderr
  attached.
- Useful for later: `herdr --remote <ssh-target>` exists natively, and
  `herdr --skill` prints the agent-facing usage doc.

When something contradicts this section, the live host wins. Re-verify and
update this file in the same commit.
