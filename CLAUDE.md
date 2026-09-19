# Bleat — native iOS remote for Herdr

Bleat is a thin native client for [Herdr](https://herdr.dev) sessions. It shows
workspaces and agents sorted by attention state, renders live panes, and lets the
user answer approvals, send prompts, and type into a pane from a phone. Herdr and
the agents always run on the host; Bleat never owns a process. App Store name:
"Bleat for Herdr".

The product promise is **zero host setup beyond Herdr itself**. Transport v1 is
plain SSH: the app runs `herdr` CLI commands over exec channels and speaks
Herdr's own JSON. No daemon, no relay, no plugin on the host.

## Current phase: 2 — gate met, 7 Sept 2026

**Pairing verified on device, 5 Sept 2026.** `bleat pair` on the Mac, scanned
with an iPhone: the host key pinned out of band matched
(`SHA256:5kgLcSfLx2/OaEHRcfc7PhrQ2uLNlTc8aL19AfjYn78`, the same one this file
records), `herdr` resolved to `/opt/homebrew/bin/herdr` through a login shell on
first connect, three endpoints were classified and raced, and the swap completed
— device key installed, proved by a second handshake, enrollment key deleted.
The host printed `Paired.`

**Screens verified on device, 6 Sept 2026.** Hosts → session → workspaces →
agents → pane, all live against the `work` session. The pane renders at the
pane's own grid and pans, so nothing is cropped — the sizing problem that held
this gate open is settled; see **`--cols` crops** below. Unpairing revokes the
device key from the host, and `bleat keys` can see and remove one from the Mac
side.

**Runs on a real phone over Tailscale — verified 7 Sept 2026, and this closes
the Phase 2 gate.** Paired and connected from an iPhone **on cellular with
Wi-Fi off**, which is the test that matters: on Wi-Fi the LAN endpoints are
live and usually win the race, so a success there proves nothing about the
tunnel. With Wi-Fi off there is nothing left to win but the overlay address.

**It did not work the way this file claimed, and the difference matters.** The
old text said `bleat pair` detects Tailscale by running `tailscale status
--json` for `Self.DNSName` and `Self.TailscaleIPs`, and called that "written and
unverified" — the last item on the gate. **It had never been written.** What
made Tailscale work was `ifconfig`: the tunnel's `utun` interface holds the
addresses and they pass every filter, and `Endpoint.reach` classifies them.

The CLI **is** consulted now, for the one thing no interface carries — the
MagicDNS name. See the endpoint list under **A peer is a host key, not an
address**. `bleat inspect` on this Mac with the tunnel up:

```
rawillkair.local                           lan       — same network only
192.168.11.54                              lan       — same network only
100.114.119.30                             overlay   — works over the tunnel
[fd7a:115c:a1e0::42a:771f]                 overlay   — works over the tunnel
rawillk.tail2a3bab.ts.net                  overlay   — works over the tunnel
```

**The classification is the load-bearing part.** Tailscale's CGNAT range is not
RFC1918 and its v6 range is a ULA, so the ordinary private-address tests call
both private — and `endpointsToTry` drops private addresses the moment the
phone leaves Wi-Fi. That would discard the one endpoint that works. `reach`
matches the two Tailscale ranges *before* the private checks for exactly this
reason.

**A stored Tailscale address survives reconnects on both ends.** The
`100.64.0.0/10` and `fd7a:115c:a1e0::/48` addresses are assigned by the control
plane and bound to the node's identity rather than its session, so they persist
across logout, reboot, and moving between networks. What does invalidate one is
removing the machine from the tailnet and re-adding it, or re-registering it as
a new node: that is a new node record with a new address, and since endpoints
are captured at pair time and never re-discovered, it costs a re-pair.

The Phase 1 gate is met over real SSH: connect, list sessions/workspaces/agents,
attach to a pane, see live frames, send input, resize, detach cleanly. Verified
against a loopback sshd on 127.0.0.1:2222. **Remote Login is now on** (verified
4 Sept 2026: port 22 answers `SSH-2.0-OpenSSH_10.3`, and mDNSResponder advertises
`_ssh._tcp` as `rawillkair.local:22`), so the throwaway-sshd dance is no longer
required to exercise the SSH path — it remains the fallback on a Mac where
Remote Login is off, since enabling it is a system change needing root.

Read the phase gates before proposing work outside them.

| Phase | Deliverable | Gate to next phase |
|---|---|---|
| **1 — Pipe** ✅ | Platform-agnostic Swift package `BleatKit` + macOS console tool `bleat` | From a Mac terminal: connect over SSH, list sessions/workspaces/agents, attach to a pane, see live frames, send input, resize, detach cleanly. No UI code. |
| **2 — Read-only app** | Xcode project, SwiftUI iOS app | Hosts → session → workspaces → agents (blocked on top) → live pane view (SwiftTerm). No input yet. Runs on a real phone over Tailscale. |
| **3 — Control** | Input + release | Keyboard with accessory row (Esc, Ctrl, Tab, arrows, y/n), prompt composer via `agent prompt`, takeover indicator, reconnect on foreground. TestFlight, then App Store. |

Out of scope until after Phase 3: pairing/relay transport (iroh or WebRTC),
push notifications, watchOS, Live Activities, multi-account badges.

### Must ship before any release

- **The host side is done: `bleat keys list` / `bleat keys revoke <marker>`.**
  Verified 5 Sept 2026 against a scratch `HOME`, including the fingerprints
  matching `ssh-keygen -lf` exactly — that equality is the whole point, since
  comparing the two by eye is how a user identifies which phone a key belongs
  to. See **`bleat keys`** below.
- **The phone's side is done too.** Unpairing revokes over the connection it
  still has and drops the record only once the key is gone; when it cannot, it
  shows the command that finishes the job before offering to forget the record
  that names it. See **Unpairing** below. Verified end to end against a
  throwaway sshd on 5 Sept 2026, including that the revoked key stops
  authenticating.

## Creating panes and sessions from the phone (herdr 0.9.0, 8 Sept 2026)

Read off the live CLI, so this does not have to be rediscovered. **Starting a
session, creating a workspace, adding a tab and starting an agent are built** —
see below. `pane split` is not, deliberately: a tab is the better way to get
another pane, and the measurement that decides it is under **Another pane is a
tab, not a split**.

**Panes, workspaces and tabs can be created, and a plain shell is the default.**

```
herdr workspace create --cwd PATH --label TEXT [--env K=V] [--focus]
herdr pane split [PANE] --direction right|down --cwd PATH [--env K=V]
herdr tab create
```

None of them takes a `--command`, so what launches is the user's shell. Herdr
calls a pane an *agent* only when its detection manifests recognise one, and
`herdr agent start` ("start a supported interactive agent in an existing pane")
is a separate, explicit step. So "new pane, plain terminal, no agent" is not a
mode — it is the default, and an agent is opt-in afterwards. Mechanically this
costs nothing new: they are ordinary `herdr` commands over the exec channel the
transport already opens.

### Starting a session: `herdr session attach`, headless (built, 9 Sept 2026)

**There is still no `session create`** on 0.9.0 — `herdr session` offers only
`list`, `attach`, `stop`, `delete`. `attach` is the one that brings a session
into being, and run with no pty it is the whole of the launch:

```sh
exec 2>/dev/null
env -u HERDR_SOCKET_PATH -u HERDR_SESSION '<herdrPath>' session attach '<name>' </dev/null 2>&1 &
launch=$!
( sleep 10; kill -TERM $launch ) >/dev/null 2>&1 &
watchdog=$!
wait $launch
kill $watchdog >/dev/null 2>&1
true
```

That whole script is pinned by an exact-string test and was run **verbatim**
over a real exec channel — success path, refusal path and watchdog — which is
the rule this file applies to every other command.

**This file used to say the opposite, at length, and the reasoning was never
measured.** It claimed `attach` "wants a pty, and the pty it gets becomes the
session's geometry", and built a `nohup env … herdr server </dev/null >LOG 2>&1
&` around avoiding that. The geometry half is true **only when there is a pty**.
Over an SSH exec channel there is none. Measured 9 Sept 2026 against a throwaway
sshd on 127.0.0.1:2222 — no tty, no `HERDR_*` in the environment, login shell
`zsh`:

| | |
|---|---|
| session created, server reparented to pid 1 | yes |
| the server's stdin/stdout/stderr | **all `/dev/null`** |
| channel returned in | 0.14s |
| pane geometry | **120×40**, the headless default |
| second launch while running | same pid, no error, no second server |
| on a stopped session | resumes it, with the workspaces it had |
| invalid name | **exit 2**, herdr's sentence on stderr, nothing created |
| headless success | **exit 1**, `Inappropriate ioctl for device` |

**The command this replaces never worked over SSH at all**, and that was found
while reviewing the replacement. `nohup` on macOS refuses an exec channel —
`nohup: can't detach from console: Inappropriate ioctl for device` — and bails
*before* exec'ing herdr, so no server started and no session was created.
Measured three ways:

| | |
|---|---|
| old command, local non-pty shell | **works** (this is how it was "verified", 8 Sept) |
| old command, real SSH exec channel | **fails** — nohup refuses, nothing starts |
| same command without `nohup`, over SSH | works |

So starting a session from the phone had never worked on a real device, and the
8 Sept verification was done over a local shell — precisely the gap **Testing
against a live host** warns about. A local non-pty shell is not an exec channel.
Verify over one.

**herdr daemonises the server itself**, so `nohup`, `&` and the stdout redirect
were each defending against something already done — and the first of them was
actively breaking it. All three are gone, and with
them the log file — and the `${TMPDIR:-$HOME}` fallback that existed only
because a predictable name under a world-writable `/tmp` is a symlink this
redirect would have truncated as the SSH user. `SessionLaunch.logCommand` and
`SessionStarter`'s log-fetching `diagnosis` are deleted.

- **Exit 1 is the success path**, which is the sharp edge. The TUI cannot draw
  without a pty, so it complains and exits 1 *after* the server is up — the
  reason the script swallows its own status, as `HerdrLookup.command` does with
  `|| true`. `ShellRunner.run` throws on a non-zero status, so otherwise every
  successful start would reach the user as "the host rejected a command (exit
  1)". **Never show that stderr**: `Inappropriate ioctl for device` appears on
  every start that worked.
- **A refusal is now reported synchronously, in herdr's own words**, off the
  command's merged stderr rather than out of a file fetched afterwards. That is
  strictly better than the old command, whose status was the shell's and
  therefore meant nothing at all.
- **The launch is synchronous now, so it is bounded.** `nohup … &` could not
  hang; a foreground command can, and a herdr that never exits would hold the
  exec channel open forever — `NewSessionModel` never clears `isStarting`, and
  `NewSessionField`'s scrim is deliberately inert while a launch is in flight,
  so the cover could not be dismissed and the app would need relaunching. A
  `( sleep 10; kill -TERM )` watchdog bounds it, the same shape
  `EndpointDiscovery.tailscaleStatusCommand` uses and with the same two
  details: the watchdog's output goes to `/dev/null` so it is not a second
  writer holding the channel open, and `exec 2>/dev/null` suppresses the
  shell's `Terminated: 15`. Verified with a `sleep 600` in herdr's place and a
  3s budget — the channel returned in 3.12s, the hung process was gone, and the
  command still exited 0.
- **Every outcome exits 0**, hence the trailing `true`: the success path exits
  1 and a killed launch exits on a signal, and `ShellRunner.run` throws on
  either.
- **The `session list` read-back stays.** Exit 1 cannot tell "server up, TUI
  could not draw" from "TUI could not draw for another reason", so the launch is
  still a write that must be *checked*. `SessionStarter` polls, as before.
- **`SessionLaunch.diagnosis` strips ANSI before matching `error: `, and that is
  measured.** herdr styles some of its own errors even to a non-tty: captured to
  a file, the nested-herdr refusal arrives as `ESC[1merror:ESC[0m nested herdr
  is disabled by default`, which no prefix test on the raw bytes can match. The
  old code tested the raw line. **CSI alone is not enough either**: stdout and
  stderr are merged, so a title set (`ESC]0;…BEL`) sharing a line with the
  complaint would leave `]0;…error: …` and hide the prefix behind its own
  payload. OSC and the two-byte forms are handled; anything unrecognised is
  skipped rather than consumed, because losing half of herdr's sentence is
  worse than leaving a stray byte in it.
- **Both `HERDR_SESSION` and `HERDR_SOCKET_PATH` are unset.** The name is a
  positional argument now, so an inherited `HERDR_SESSION` would let a login
  profile decide which session starts. Measured clean over SSH; this is for the
  host whose profile exports them.
- **`attach` being idempotent makes the look-before-launch rule matter *more*.**
  The old `herdr server` at least failed loudly against an already-running
  session (`error: herdr server is already running`, into a log nobody read).
  `attach` succeeds silently — same pid, no second server — so the launch is
  indistinguishable from starting a fresh one, and `SessionStarter`'s read of
  `session list` *before* the write is now the only thing standing between that
  and the phone claiming somebody's live session. See **Stopping and deleting**
  for what that claim buys.
- **A new session is *not* empty**, and this file claimed the opposite until it
  was measured. `attach` brings one up holding a single workspace — labelled
  `~`, one tab, one pane, in the SSH user's home directory. The old text ("no
  workspaces, no panes") was carried over from the `herdr server` era and never
  re-checked. Nothing in the UI depended on it, but the workspaces list is not
  empty on a session the phone has just started.
- **A *stopped* session of that name is resumed, not recreated**, with its
  workspaces — measured again here.
- **Resuming does not disturb the geometry either.** This is the case where the
  old design's fear would actually bite, since a resumed session has a real
  layout to lose, so it was measured rather than assumed: a session stopped and
  re-attached came back with both workspaces and **both panes still 120×40**.
- **Its geometry comes from the default config**, not from `phone.toml` — that
  file is reached only via `HERDR_CONFIG_PATH`. So a session started from the
  phone is `headless_cols`/`headless_rows`, 120x40 unless the host's own
  `config.toml` says otherwise, and is **not** phone-shaped. That stays a host
  config question, as this file already argues.

**Session names: validated on the phone, never sanitised** — the `Marker(text:)`
rule. herdr states its own set in its refusals: ASCII letters, numbers, `.`, `_`
and `-`, and not `.` or `..`. `SessionName` adds one rule herdr does not:

- **A leading dash is refused, and this one is not pedantry.** `HERDR_SESSION=-x
  herdr server` starts perfectly well and creates `sessions/-x`. After that
  neither `herdr session stop -- -x` nor `herdr session delete -- -x` can
  address it — both print their usage line, because the name parses as a flag.
  The probe's server had to be killed by pid and its directory removed by hand.
  Without the rule the phone can leave a session running on someone's Mac that
  the Mac's own CLI cannot stop.

### Stopping and deleting a session (built, 8 Sept 2026)

`herdr session stop <name> --json` and `herdr session delete <name> --json`,
both client-side commands — explicit `--json`, no envelope, replies captured in
`Fixtures/session-stop.json` and `session-delete.json`. There is **no "detach"**
for a headless session: detaching is what a TUI client does, and nothing is
attached. Stop and delete are the two verbs herdr has.

**Stopping ends every process in the session.** Measured: a session with one
pane was stopped and its shell was gone a second later, pid and all. On a
session holding agents that is their work ending, with no undo and nothing at
the Mac to say who did it. This is the most destructive thing Bleat does —
unpairing only takes away the phone's own access.

So it is guarded three ways, and all three are needed:

- **The phone may undo what it did, and no more.** Two claims, kept apart on
  purpose:
  - **`startedSessions` — "this phone is why it is running"** — is what **Stop**
    is offered on. Written when a launch the host has confirmed running
    succeeds, and **dropped when the session stops**, because that is when it
    stops being true.
    - **Both claims are derived from what the host said *before* the launch,
      never from the caller.** `SessionStarter` reads `session list` first. A
      version that launched and then asked only "is it running now?" answered
      yes when the launch had done nothing *because it was already up*, and
      recorded a session somebody was working in as ours, which is a Stop over
      their agents. A stale row is all it takes. **`session attach` makes this
      load-bearing rather than belt-and-braces:** the old `herdr server` at
      least failed loudly at a running session, while `attach` is idempotent and
      succeeds silently, so this look is now the only thing that tells the two
      apart. The same look settles the
      other claim: `createdSessions` only when the host had never heard of the
      name, so typing the name of somebody's stopped session into the new-
      session field resumes it without earning a Delete over their layout. Without expiry, starting and stopping the user's own
    `work` session from the phone would leave a permanent claim on the name and
    a Stop button over whatever they started next.
  - **`createdSessions` — "this phone made it from nothing"** — is what
    **Delete** is offered on, and nothing else. Deleting removes the session
    *directory*; for a session somebody else set up, that is their layout.
  - So `SessionControlModel.actions(for:on:)` offers no Stop for a session
    running for somebody else's reasons — the `work` session someone is sitting
    in front of has no swipe at all — and no Delete for one this phone merely
    restarted. It is a name, not an identity: herdr has no notion of who created a
  session, so this is only ever what this install remembers doing. **A reinstall
  forgets and then offers nothing**, which is the safe direction — the record
  lives under Application Support, which is excluded from backup and does not
  restore to a new phone.
  - **The claim is dropped on delete**, and that is not tidiness. The name is
    all that ties a session to this install, so one left behind would be
    inherited by the next session of that name — made by whoever is at the Mac
    — handing the phone a Stop action over their work.
  - **`merging` unions it.** A re-pair builds the incoming record from a
    scanned QR, which carries no sessions, so taking the newer value would
    withdraw the actions from every session this phone had started.
  - Stored as an **optional array**, not a defaulted one: the synthesized
    decoder does not apply default values for a missing key, and
    `PeerRegistry.all()` treats an undecodable file as a hard failure — a
    defaulted `Set` would have stranded every already-paired host on the first
    launch after this shipped.
- **A swipe asks; it does not act.** The peer row's rule. The dialog names the
  session and says what goes with it rather than asking "are you sure?".
  - **A confirmed action takes its values as parameters, never reads them back
    out of the model.** SwiftUI clears a `confirmationDialog`'s binding *before*
    running the tapped button, and a model whose `isConfirming` setter resets
    its phase on that write then finds nothing armed — so the action returns
    having done nothing, with no error and no alert. Shipped exactly that: Stop
    removed the row and left the session running. `UnpairFlow` already carried a
    comment about the hazard. Pinned by a test that drives it in SwiftUI's order
    — arm, dismiss, act — against a peer with no endpoints, which
    `PeerConnection.connect` refuses before dialling.
  - **Only a line beginning `error: ` is a cause**, and the ANSI is stripped
    before that is tested. A launch that worked prints `Inappropriate ioctl for
    device`, so a host merely slower than the poll's budget would otherwise
    have herdr's own success shown under the heading "That did not happen".
    (The launch log this rule was written for is gone — see **Starting a
    session** — along with the `${TMPDIR:-$HOME}` symlink hazard it carried.)
  - **`session list`, `session stop` and `session delete` take a
    session-agnostic client.** `useSession` is shared mutable state on one
    transport, read at command dispatch — and the session screen now asks two
    questions over one connection, one of which needs the prefix. Passing
    `session: nil` for the other cleared it out from under an in-flight
    `workspace list` whenever `.task` and `.refreshable` overlapped.
    `ConnectionStore.sessionAgnosticClient` exists for the reason `shell` does.
  - **The refresh belongs to `perform`, not to the dialog's button.** There
    are two ways an action starts — through the confirmation, and straight from
    a button for the one action that needs none — and hanging the reload off
    the first leaves the second working silently: Start brought the session up
    and the screen went on showing it stopped until the user backed out and
    came in again. `SessionControlModel.onCompleted` is installed once by the
    flow and called by `perform`, so every path ends the same way.
  - **A swipe button must not carry `role: .destructive`.** In a swipe action
    that is not a colour: SwiftUI reads it as "this row is going away" and
    animates it out the moment the button is tapped — before the confirmation
    is answered, and still gone if it is cancelled. Wrong for Stop in any case,
    which leaves the session listed and merely not running. Tint red instead.
- **The result is checked, not assumed** — and this one is not paranoia.
  `herdr session delete nosuchsession --json` answers **`{"deleted":true}` and
  exits 0**, having deleted nothing. So `deleted` is not evidence; the list is
  read back and the answer is whether the name is really gone. The same class
  of lie as a `authorized_keys` removal exiting 0 when it matched nothing.

Two more shapes worth knowing:

- **Delete is refused while the session runs** — `session_delete_failed`,
  "stop it before deleting" — so the row offers Stop *or* Delete, never both.
- **Stop is refused when it is not running** (`session_stop_failed`), for the
  same reason the row does not offer it.

Errors arrive as the unenveloped client-side shape, `{"error":{…}}` on stderr
with exit 1, which `HerdrError.fromStderr` already parses.

**Three actions, one of which does not ask.** `start` joins them —
`SessionControlModel` covers all three, and `SessionStarter` holds the launch so
the field that names a new session and the button that restarts a stopped one
cannot drift apart. Starting a stopped session is the *same command* as creating
one, and herdr keeps the session directory, so it resumes with the workspaces it
had. It ends nothing and the way back is the Stop beside it, so it is the one
action with no confirmation — `needsConfirmation` says so in one place, and
`begin(_:about:on:)` is the single entry point so a new button cannot skip the
question.

- **Start is offered for anyone's stopped session**, and that is deliberate.
  It restores rather than creates — measured: a stopped session comes back with
  its workspaces, its panes, and a **freshly spawned shell** in each at its
  recorded cwd — so it ends nothing, and it is the only way back when the Mac
  has rebooted with nothing up, which is the gap this file names below.
  **Agents are not restarted**: `herdr agent start` is a separate step herdr
  does not replay, so a pane that held one comes back as a plain shell. The
  stopped empty state says so.
- A running session offers **Stop** (if the phone started it); a stopped one
  offers **Start**, then **Delete** if the phone created it — Start first, so a
  full swipe reaches the harmless one. Never a pair herdr would refuse.
- **The session screen has a bottom bar too**, the same shape as the peer
  screen's: the action on the left, prominent, and Delete to the right when
  there is one. Empty for a session this phone did not start.
- **`SessionStatus` fetches whether the session is running**, because the route
  cannot carry it: a route's identity would then change the moment the session
  stopped, which is exactly when the screen has to stay put. `nil` means "not
  asked yet", not "stopped" — the bar shows nothing rather than guessing.
- **A stopped session gets its own empty state, in place of the list and not
  over it.** There is no server to answer `workspace list`, so the list's own
  state is a `server_not_running` failure — true and useless. An `.overlay`
  drew one on top of the other: two headings and two paragraphs interleaved,
  both legible and neither readable. Replace the list; do not cover it.
- **Deleting from inside the session pops.** The route names something the host
  no longer has, so every refresh from there on would fail against it.

### Creating a workspace (built, 8 Sept 2026)

```
herdr workspace create --cwd PATH [--label TEXT] --no-focus
```

One command makes three things — captured into `Fixtures/workspace-create.json`
and modelled by `WorkspaceCreated`: a workspace holding one tab holding one
pane, and that pane is a plain login shell (`pane process-info` reports
`argv: ["-zsh"]`, and `agent list` for the session stays empty). **A workspace
is never empty, and neither is a tab.** `tab create` behaves the same way and
answers `tab_created` with its own `root_pane`; `pane split` is the only one of
the three that adds a pane to a tab that already exists.

**herdr accepts a `--cwd` that is not there, and says nothing.** This is the
fact the whole design turns on:

```
$ herdr workspace create --cwd /no/such/dir --label ghost
{"result":{"root_pane":{"cwd":"/Users/ravil",…},"workspace":{"label":"ghost",…}}}
```

Exit 0, `workspace_created`, no error — and a workspace called `ghost` sitting
in the home directory rather than the path that was asked for. The same class of
lie as `session delete` answering `{"deleted":true}` over a session that never
existed, and it takes the same answer: check rather than trust. Three checks, in
the order that costs the user least:

- **The shape, while they type.** `WorkspaceDirectory` refuses a relative path —
  herdr resolves one against the *server process's* working directory, measured:
  the CLI run from `/tmp` with `--cwd ../` produced a pane in
  `/Users/ravil/Developer/rawillk`, the parent of wherever `herdr server` was
  started. From a phone that directory is unknowable. It also refuses a leading
  `~`: every argument reaches the host inside single quotes, so nothing expands
  it, and herdr then falls back to the home directory — which for `~` alone is
  the right answer *by accident* and for `~/Developer` is not.
- **The path, resolved by the host, before anything is created.**
  `DirectoryCheck` runs `cd … && pwd -P` over a plain shell, which settles two
  questions in one round trip: a directory that cannot be entered has no answer,
  and the answer that does come back is the form herdr will report. It exits 0
  either way, for the reason `HerdrLookup.command` ends in `|| true`, and the
  reply is read as a **prefixed line within** stdout rather than compared whole
  — `.zshenv` is sourced for every non-interactive zsh and profiles print
  banners, which is the mistake `PeerConnector`'s `printf ok` probe made. `cd`'s
  own output is redirected inside the substitution, or a `chpwd` hook that runs
  `ls` would be read as part of the path.
  - **Resolving is not tidiness; a plain `test -d` shipped a bug.** herdr
    reports a **canonical** cwd — measured: `/tmp` → `/private/tmp`, `/var` →
    `/private/var`, and both `/Users/ravil//Developer` and
    `/Users/ravil/Developer/../Developer` → `/Users/ravil/Developer`. A phone
    comparing herdr's answer against the string the user typed therefore
    reported a workspace as misplaced that had gone exactly where it was asked,
    for paths as ordinary as `/tmp`. The create sends the resolved form and the
    comparison is against that.
- **Where it actually landed.** `WorkspaceCreated.openedElsewhere(than:)`
  compares the reply's `root_pane.cwd` against the resolved path. With the check
  in front of it this only catches a race, and it is what stops "created it,
  somewhere else" being something the user has to notice for themselves.
- **And on the failure path, whether it happened anyway.** A create that
  *threw* is not proof that nothing happened: if the connection drops between
  herdr running the command and the reply arriving, the workspace exists and a
  plain failure invites the obvious retry, which makes a second one. So the
  ids from `workspace list` are captured before the write and read back after a
  throw — the same shape as `SessionStarter` polling `session list`. Three
  answers, and the third is why it is not a one-liner: nothing new means it is
  safe to try again, a new workspace means say so, and a read-back that *itself*
  fails means "I cannot tell", which must **disarm** rather than re-arm.
  - **A refusal is not a maybe**, and it skips the read-back entirely.
    (`AgentStart.isRefusalBeforeTyping` is the same rule one command along, with
    one extra clause: `timeout` is a `HerdrError` that means "I stopped
    waiting", so it is the one herdr answer that is *not* a refusal. Asking
    "was it a timeout" instead of "did herdr answer" is a mistake that shipped
    here once — it sent a dropped connection and an unreadable reply back as
    "nothing happened, try again", over an agent that had probably started.)
    `ConnectionPolicy.isRefusalByHost` is the other half of
    `isFatalToConnection`: a `HerdrError` is the host answering in its own error
    envelope, having processed the command and declined, so nothing was created.
    Read as unknown it tells the user something may be on their Mac when it
    demonstrably is not — and since unknown spends the button, reopening the
    sheet becomes the only way back from something a retry would have fixed.
    A `DecodingError` is deliberately *not* a refusal: there the command
    succeeded and only the reply was unreadable, so the write almost certainly
    landed and has to be checked.
- **Optional is not decode tolerance**, which is why `WorkspaceCreated` writes
  `init(from:)` out. The synthesized decoder's `decodeIfPresent` tolerates a
  *missing* key and still throws `typeMismatch` on one that is present and
  malformed — measured with a probe — so a herdr emitting an unexpected type in
  `tab`, a field nothing reads, would fail the whole decode and report a
  failure over a workspace sitting on someone's Mac. Each sibling is taken with
  its own `try?`; only `workspace` still throws.
- **A settled attempt spends the button, and only reopening the sheet clears
  it.** The model is `@State` on `WorkspacesView` rather than on the sheet — so
  an in-flight create survives a dismissal — which means everything it holds
  outlives the sheet too. `clearFailure` deliberately does not touch the
  warning, since editing a text field does not undo a workspace; `reset()` does,
  and the plus button calls it. Without that, one "landed elsewhere" left the
  button reading "Done" forever over a stale message, with nothing on the screen
  able to clear it and popping the whole session screen the only way out. The
  path and label are reset too, or a reopened sheet comes up prefilled *and*
  armed, one reflexive tap from a second workspace at the same path.

Three smaller measurements, each of which would otherwise be guessed wrong:

- **The label defaults to the basename** — `/tmp` → `tmp`, `…/bleat-apple` →
  `bleat-apple`, `/` → `/` — **except the home directory, which herdr labels
  `~`.** The phone cannot know which path that is, so
  `WorkspaceDirectory.suggestedLabel` is knowingly wrong there and a test pins
  it as a decision rather than an oversight.
- **An empty label is omitted rather than sent empty**, so herdr picks that same
  basename; the field's placeholder shows it, so leaving it blank is not a
  mystery.
- **Duplicate labels are allowed.** Two workspaces called `dup` were created and
  both appear in `workspace list`, so the footer is a heads-up and not a
  refusal.

**`--no-focus` is passed explicitly**, and it is the one flag here that is about
somebody else: focusing moves the view of whoever is at the Mac, which is why
`agent focus` is banned outright. The measured default is already not to focus
when another workspace holds it, but a default is not a promise. herdr honours
it whenever there is a focus to keep and **ignores it for the first workspace in
an empty session** — `focused: true` whatever is asked, which is the one case
where focusing takes nothing from anybody.

**The plus is offered only while the session is running**, and that changes
which button is prominent in the bottom bar: while a session is up the useful
action is adding to it and Stop is the afterthought, while a stopped one has
nothing to add *to* — a client command against it answers `server_not_running` —
so Start takes the prominent position and the plus is not shown at all.

**Each bottom-bar button keeps its own `ToolbarItem` with a `ToolbarSpacer`
between**, and that is load-bearing rather than layout taste. Start and Delete
are the only pair that appear together and one of them removes somebody's
session directory; rendering both inside a single item — which a `ForEach`
does — puts a destructive action flush against the primary one, a tap's width
apart.

**The directories are suggested, not typed.** The phone has no file browser and
an absolute path is miserable to type on one, but `pane list` already carries
every pane's `cwd`, so the list of directories in use on the host is free. It is
best effort: a host that will not answer leaves a form that still works.

### Starting an agent (built, 9 Sept 2026)

```
herdr agent start <name> --kind <KIND> --pane <ID> --timeout 30000
```

Twenty-three kinds on 0.9.0, and the value is both the kind and the executable:
`--kind claude` runs `claude`. `AgentKind` is a string with a known list rather
than a closed enum, so a herdr that grows a twenty-fourth stays usable — the
"unknown values must decode, never throw" rule applied to a value.

**The pane must already be at a shell prompt**, and herdr means it: a pane
running an ordinary `sleep` is refused exactly like one holding an agent, and a
pane whose shell has not finished spawning is too. So a create-workspace-then-
start-agent flow has to let the pane settle first.

**Every refusal is instant; exactly one failure is slow.** This is the fact the
whole screen is shaped around. Measured, all under 30ms:

| code | meaning |
|---|---|
| `agent_pane_not_found` | no such pane |
| `agent_pane_busy` | the pane holds an agent, *or* is running anything else |
| `invalid_agent_name` | herdr's own name rule, below |
| `agent_name_taken` | that name is in use in this session |
| `invalid_agent_timeout` | outside herdr's bounds, below |

The slow one is `timeout`: herdr types the executable into the pane and waits
for its own detection, so a kind whose binary is missing costs the **full 30
seconds** and then answers `timed out waiting for agent startup`.

**This table was missing a code, and the omission shipped.** `agent_not_ready`
is what herdr answers when the agent came up and **stopped at a dialog**, and it
is not a refusal at all — see **An agent that starts blocked** below. It reached
a device.

**A timeout is not a refusal, and that is the load-bearing measurement.** Given
a 3.5s budget against a 4.9s cold `claude` start, herdr timed out — and the pane
then held a running, detected claude with **`name: null`**, because herdr never
got to record it. So a caller reporting a timeout as a plain failure invites a
retry, which lands on `agent_pane_busy`, over the agent the user was just told
had not started. `AgentStart.isUnknownOutcome` names the one code that means "I
stopped waiting", and the model reads the host back — the same shape as
`NewWorkspaceModel.settle` and `SessionStarter` polling `session list`. Three
answers: an agent in that pane means it came up late and nameless, an empty pane
means nothing started and a retry is safe, and a host that cannot be asked is
genuinely unknown and must **disarm**.

#### An agent that starts blocked (`agent_not_ready`, found on device 12 Sept 2026)

**The common case, not an edge one.** Claude Code shows its workspace-trust
prompt for any directory it has not seen before — which is every workspace the
phone has just made — so an agent started there comes up *blocked* nearly every
time. Reported from a device: *"when you start agent session it might be blocked
right away by trust folder dialog. UI is blocked in this case but it should not
be as opening the session screen and switching to terminal mode solves the
problem."*

Measured in an isolated session against a fresh directory:

| | |
|---|---|
| reply | `{"code":"agent_not_ready","message":"agent probe is blocked during startup and is not ready for prompts"}` |
| exit / elapsed | 1, in **3.9s** — not the 30s timeout |
| `agent list` afterwards | `name: "probe"`, `launch_pending: true` |
| retry, same name | `agent_name_taken` |
| retry, another name | `agent_pane_busy` |
| the pane | the trust dialog, cursor on **`No, exit`** |

**So herdr returned an error over something that had entirely succeeded**: it
typed the executable, the agent came up, herdr recorded the name, and then it
reported a failure because the agent was not ready for *prompts*.

`AgentStart.isRefusalBeforeTyping` asked only "is the code something other than
`timeout`", so this was classified as a refusal-before-typing — the phone showed
herdr's sentence in red, which reads as *nothing happened*, and left the Start
button armed. Both ways forward from there are dead ends, per the table above.
That is the same bug the `timeout` rule was written to prevent, one code along,
and the lesson is the one this file already records about that rule: **ask what
herdr said, not whether it said one particular thing.**

- **It is told apart from `timeout` rather than lumped with it**, because the
  remedies differ and that is the whole point. A timeout is genuinely
  *ambiguous* — herdr stopped waiting and may or may not have left an agent — so
  it is followed by reading the host back. This is not ambiguous: herdr says the
  agent is blocked during startup and names it, so it is taken at its word and
  the screen's job is to offer the way to answer it.
- **`AgentStart.isBlockedDuringStartup` is the test**, and `NewAgentModel.blocked`
  carries the message. The sheet shows it unstyled — not red, because the agent
  *is* there — and the confirmation button becomes **"Answer it"** instead of an
  armed Start that could only fail.
- **"Answer it" opens the pane, and the push happens from the sheet's
  `onDismiss`.** SwiftUI will not act on a navigation raised by a view on its way
  out — the hazard `PeerSettingsFlow` records for a confirmation dialog presented
  underneath a sheet, where the dialog was simply never seen. So the form asks
  through a callback, `AgentsView` holds the request, and the route is pushed
  once the dismissal has finished; the request is cleared as it is taken, or a
  later dismissal would open a pane nobody asked about.
- **The list is reloaded before the push**, so backing out of the pane lands on a
  list that shows the new agent. It sorts to the top by itself — `blocked` is
  first in the attention order.
- **This is what `PaneKeyBar` was built for**, and the two features only meet
  here: answering the dialog needs arrows and Enter in terminal mode, and until
  the key bar landed there was nothing for this button to open *to*. The trust
  dialog defaults to `No, exit`, so it still takes a deliberate Down before
  Enter — which is why the bar is six honest keys and not a Yes/No pair.
- **The pane travels with the message, and the type is what enforces it.**
  `NewAgentModel.Blocked` carries the target, because the pane picker stays
  interactive in this state — a version that read the *current* selection at tap
  time sent the user to whichever row they last touched, an unrelated shell,
  while the note went on claiming an agent was waiting. It also had no branch for
  a nil selection, which left Start permanently disabled with Cancel the only way
  out.
- **`blocked` disarms "Add a pane" as well as Start.** Adding a pane creates a
  real tab on the user's Mac and then selects it, so while an agent sits at a
  dialog that would leave a stray tab behind *and* repoint the form at an empty
  pane, over an agent that still needs answering.
- **The route carries the mode, so the button lands in the terminal.**
  `PaneView` defaults to `.chat`, which for an agent that has not got past its
  trust prompt is an empty transcript — the opposite of what was asked for. So
  `NavigationRouter.Route.pane` takes a `PaneMode` (defaulted to `.chat`, which
  keeps every agent row as it was) and `PaneMode` is public for it. The button is
  labelled **"Open the pane"** rather than "Answer it": it shows the dialog, and
  answering still needs control, which the note says.
- `AgentStartTests` pins the classification and was **checked against the bug**:
  with the old one-liner restored, "an agent blocked at a dialog is not a
  refusal" fails.

**The cause of a timeout is written only in the pane.** herdr's own answer names
nothing; the pane holds `zsh: command not found: devin`. `AgentStart.diagnosis`
fetches it and shows the shell's own sentence, the way `SessionLaunch.diagnosis`
reads a launch's stderr — and, like it, **never guesses**: a line has to name the kind
we asked for *and* be a shell's complaint, or the honest "it did not come up in
time" is shown instead.

**Agent names are herdr's rule, stated by herdr itself**: `agent name must start
with a lowercase letter and contain only lowercase letters, digits, '-' or '_'
(1-32 characters)`. `AgentName` validates, never sanitises, like `SessionName`.
The capital is the one that surprises — `Reviewer` is refused — so it is
reported as a character problem rather than a first-character one, since being
told to start with a lowercase letter about a name that *does* start with a
letter reads as a contradiction.

**`--timeout` must be greater than 3000ms and at most 300000ms**, which its
`--help` does not say; below the floor it answers `invalid_agent_timeout` and
starts nothing. Bleat sends herdr's own default of 30000 explicitly. Shortening
it is the tempting mistake: it would buy a faster answer to the rare missing
binary by turning ordinary slow successes into "it may or may not have started",
which is the worst thing this screen can say.

**An agent started by hand at the Mac has no name**, and that is ordinary rather
than exotic — herdr only knows a name if it gave one out. `Agent.name` is
therefore optional, and `Fixtures/agent-list-named.json` carries two named
agents beside one started by typing `claude` in a pane. The same shape comes
back from a timed-out start.

**The pane picker offers panes with no agent**, and occupancy is read from
`agent list` rather than a pane's own fields — both are the host's, and the
agent list is the one that decides. It cannot see a pane merely busy with a
command; that refusal is instant, so it costs a tap rather than a wait.

### Another pane is a tab, not a split (built, 9 Sept 2026)

**One agent per workspace is a dead end, and it is the one this shipped with.**
A workspace made from the phone holds exactly one pane; one agent fills it; and
then Start is correctly disabled with nothing on screen to do about it. Found on
device, and confirmed against the live host: every workspace in the `work`
session has one pane and every one of them is occupied. "Add a workspace to get
another pane" is true and useless.

`herdr tab create --workspace <id> --no-focus` is the way out, and **a tab
rather than a `pane split` is decided by geometry**. Both give a pane an agent
can start in immediately — measured at 3.9s and 4.4s — but in a 120-column
session:

| | pane rect |
|---|---|
| `pane split --direction right` | **60** × 40 |
| `tab create` | **120** × 40 |

A split halves the new pane *and* the one it came from, and this file spends
pages on what a narrow grid does to an agent's output: the program wraps to its
pty's width and no client can reflow it. A tab takes nothing from any pane that
already exists. The split is the thing that *looks* like the answer, which is
why the measurement is written down.

- **No `--cwd` is sent, and that is measured rather than lazy.** A new tab's
  pane inherits the *workspace's* directory — verified against a workspace in
  `/Users/ravil/Developer` while the server had been started in the repo root.
  This is the **opposite of `workspace create`**, which takes the server's cwd
  and must therefore always be told. So adding a pane needs no path typed on a
  phone; the directory is shown before the tap rather than asked for.
- **Only from inside a workspace.** A tab belongs to one, and the session-wide
  agents list is not in one — guessing which workspace should gain a pane puts
  one in somebody's project.
- **A freshly created pane is not always ready.** A new *workspace's* root pane
  answered `agent_pane_busy` moments after creation, because its shell had not
  reached a prompt; a new *tab's* pane took an agent immediately. Both are worth
  knowing before wiring create-then-start into one gesture.

**The gap that remains: nothing can be made from cold, and a pane cannot be
split.** Every one of these commands goes over the socket API, and a client
command will not autostart a server — it returns `server_not_running`. Starting
the session is what closes that for sessions, **including sessions the phone did
not create**, so a Mac that rebooted with nothing up is no longer a walk to the
keyboard. Everything else still needs a session already up.

Splitting is the one command deliberately left out rather than merely not
reached: a tab gives a full-width pane and costs no existing pane anything,
which a split does not. What the phone cannot do is arrange panes *within* a
tab, and that is a layout decision belonging to whoever is looking at the
screen.

**It is not a new privilege, but it is a new affordance.** The device key
already grants a full shell, so nothing here widens what a paired phone *could*
do. It does change what Bleat *is* — from a remote for what is running to
something that creates state on someone's Mac.

For a **pane** that still argues for a deliberate gesture showing where it will
open before it acts, rather than a bare `+` — which is why "Add a pane" names
the directory it will inherit, even though it asks for nothing. A **workspace** gets one too, and it
is why `NewWorkspaceForm` is a sheet with a form rather than the one-line bar
above the keyboard that names a session: a path is long, easy to mistype, and
the thing herdr is silently wrong about, so both values are on screen before the
tap. A **session** is the one case where a `+` alone is honest: it takes nothing
but a name, touches no pane and no agent that already exists, is refused rather
than merged if the name is in use, and the screen it appears on is a list of
sessions. It is behind the plus on `PeerDetailView`, and the name is checked
before anything leaves the phone.

## Repository layout

House layout, matching the other projects in `~/Developer`: code lives in a
local Swift package, the `.xcodeproj` holds only targets, and the app target is
a thin shell.

```
Bleat.xcodeproj             # one app target; sources join via a synchronized group
App/                        # @main App struct and little else
BleatKit/                   # the local Swift package
  Package.swift
  Sources/
    BleatKit/               # domain + transport. No SwiftUI. Builds for iOS.
      Transport/            # HerdrTransport protocol + SSHTransport (Citadel)
      Protocol/             # NDJSON codec, frame/command types
      Model/                # Codable models for herdr JSON (from schema.json)
      Client/               # HerdrClient: typed API over a transport
      Keys/                 # device ed25519 key + Keychain storage
    BleatUI/                # SwiftUI shared between app targets; MainActor by default
      Context/              # AppContext, routers, stores
      Pairing/              # the pairing sheet, scanner and its model
      Sessions/             # the sessions on a host
      Workspaces/           # workspaces in a session
      Agents/               # agents in a workspace, blocked first
      Views/                # screens
      Previews/             # #if DEBUG sample data for #Preview only
    BleatProcess/           # macOS and Linux: LocalProcessTransport, spawns `herdr`
    bleat/                  # executable target, macOS console tool
  Tests/BleatKitTests/      # unit tests: codec, models, fake transport
  Tests/BleatUITests/       # lays views out for real; needs a simulator
  Fixtures/
    schema.json             # output of `herdr api schema --json` (source of truth)
    *.json                  # captured CLI outputs for decoding tests
Support/Info.plist          # the one key that cannot be a build setting
ci_scripts/ci_post_clone.sh # macro fingerprint defaults + `swift test` gate
```

**`BleatProcess` exists because `Foundation.Process` does not on iOS.** The rule
against `#if` branches in `BleatKit` is what forces the split rather than a
platform guard: anything that cannot compile for both platforms gets its own
target, and the iOS app simply does not link it. Verify with
`cd BleatKit && xcodebuild -scheme BleatKit -destination 'generic/platform=iOS' build`
(the package is no longer at the repo root, so this fails from there). Use
`-scheme BleatKit-Package` to compile every target at once, which is the check
that actually catches a target the app would break on.

**The console tool builds for Linux (19 Sept 2026)**, verified on a Raspberry
Pi CM5 (Debian 13, aarch64): `bleat inspect` found herdr, the host key and the
addresses, and `bleat keys list` read `authorized_keys`. The guards on `bleat`
and `BleatProcess` are `#if !os(iOS)` — they exist to keep the targets off iOS,
not because anything needs macOS.

**Build it on the Mac as one static binary; install nothing on the host.**

```sh
swiftly use 6.4.0      # the swift.org toolchain — Xcode's cannot use a Swift SDK
swift sdk install https://download.swift.org/swift-6.4.0-release/static-sdk/swift-6.4.0-RELEASE/swift-6.4.0-RELEASE_static-linux-0.1.0.artifactbundle.tar.gz \
    --checksum 47d2fd89eebfdf9eb4d536b6710414297f755c17926cdebc4742c08982b40a9e
cd BleatKit && ~/.swiftly/bin/swift build -c release --product bleat \
    --swift-sdk aarch64-swift-linux-musl --scratch-path <scratch> -Xswiftc -gnone -Xlinker -s
```

The SDK version must match the compiler exactly, and its URL spells the version
`6.4.0` — the `6.4` form 404s. The result is statically linked, stripped, 59 MB
(mostly Foundation's ICU data), and runs on any aarch64 Linux. `scp` it to
`~/.local/bin/bleat`. Apple's `container` CLI is no route here: fetching its VM
init image from ghcr.io reads the login keychain, which is locked in an SSH
session.

What the port needed, each found by the compiler rather than by reading:

- **`@preconcurrency import Crypto` in `SSHKeyPair`.** On Apple platforms `Crypto`
  re-exports CryptoKit, whose `Curve25519.Signing.PrivateKey` is `Sendable`;
  swift-crypto's own implementation (3.15.1), which Linux gets, does not say so.
- **`TerminalWindow` holds the one `ioctl`.** It is variadic in C, so each libc
  imports a different signature; musl wants the request as `UInt`, the branch
  swift-argument-parser also carries. The static SDK is **musl**, so imports need
  a `canImport(Musl)` arm — `canImport(Glibc)` is false there.
- **`Date.RelativeFormatStyle`, not `RelativeDateTimeFormatter`**, which Linux
  Foundation does not have.
- **QR on Linux comes from `QREncoder`**, a port of Nayuki's MIT reference
  encoder in `BleatProcess` — byte mode only, level chosen by the caller and
  never boosted. macOS keeps `CIQRCodeGenerator`; the encoder compiles there
  anyway, with no platform branch, so `QREncoderTests` can hold it against
  CoreImage. It is not in the iOS app, which never links `BleatProcess`.
  - **Identical to CoreImage module for module**, for all 40 versions at all
    four levels, once CoreImage's mask is forced — read out of its format bits.
    Breaking the Reed–Solomon polynomial fails all 160.
  - **The mask choice differs about a third of the time, and that is fine.**
    Any of the eight is valid; the penalty rules only rank them, and encoders
    differ on the finder-like rule. This one's choice is checked by decoding.
  - **CoreImage segments; this does not.** On a real pairing URL CoreImage's
    first byte segment declares 80 of 201 bytes and then switches mode inside
    the base64. Byte mode throughout is valid and, measured on the Pi's payload
    and the seven-endpoint worst case, costs no version — which is what would
    cost terminal rows.
- **The mDNS name is asked of avahi, never assumed from the hostname** —
  `busctl --system call org.freedesktop.Avahi / org.freedesktop.Avahi.Server
  GetHostName`, which answers `s "adam"`. Avahi renames on a collision (two
  Pis on the stock `raspberrypi` become `raspberrypi-2`) and `host-name=` can
  override it; the hostname would put the *other* machine's name in the QR,
  which surfaces as a host key mismatch. `busctl` ships with systemd, and the
  call fails when avahi is not running — exactly when there is no name — but
  **only with `--auto-start=no`**: otherwise the bus activates a stopped-but-
  enabled avahi to answer, and pairing restarts a daemon the user stopped.
- **`tailscale` is looked for in `/usr/bin` too**, where Linux packages put
  it — in both `HostInspector.tailscalePaths` and the phone's
  `EndpointDiscovery.tailscaleStatusCommand`, which must stay in step.
- **Interface addresses need no new parser.** net-tools `ifconfig` lives at
  `/sbin/ifconfig` (off a non-login `PATH`, which is why `command -v` misses it)
  and `InterfaceAddresses` reads its layout — pinned by
  `Fixtures/ifconfig-linux-docker.txt`. **Interface names may contain `-` and
  `_`** (`br-8f2a…`, `wg-home`); the parser used to reject them as headers and
  credit their addresses to the interface before. Two gaps remain: net-tools does not mark
  RFC 4941 `temporary` or `deprecated` addresses, so a host using privacy
  addresses would offer them; and a host without net-tools yields no addresses
  (`ip addr` is not read), leaving the mDNS name and `--endpoint`.
- **Container bridges are ignored.** `docker0` holds `172.17.0.1` and is filtered
  by the flag check only while no container runs; once one does it is `RUNNING`
  and would be offered. `docker`, `br-`, `veth` and `virbr` joined the ignored
  prefixes — the same hazard as Parallels' `bridge100`.

`Keys/KeychainKeyStore.swift` stays Apple-only; the tool never references it.
`HostRegistry` and `KnownHostsStore` persist to `~/.bleat/`, which works as is.

**`BleatKit` stays free of SwiftUI**; shared views live in `BleatUI`. (Phase 1's
note said "outside this package" — that predates the package having more than
one target. The intent was never to contaminate the transport layer, which a
separate target satisfies.)

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
  **An agent pane has no scrollback, at all** below. Its `--source` takes
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

## SSH transport (Phase 1 decisions)

- Library: **Citadel** (SwiftNIO SSH). Approved dependency. Do not add others
  without asking. Pulls in swift-nio, swift-crypto, swift-asn1, BigInt.
- **Citadel forces macOS 15 / iOS 18.** Every stdin-capable API (`withExec`,
  `withPTY`, `withTTY`) is `@available(macOS 15.0, *)`; only the read-only
  `executeCommandStream` works below that. The package platforms were raised
  to match.
- Auth: ed25519 key, parsed with `Curve25519.Signing.PrivateKey(sshEd25519:)`.
  Stored in Keychain (Phase 2) or a file under `~/.bleat/` for the console tool.
- Host key: trust-on-first-use, pinned per `host:port` in `~/.bleat/known_hosts`
  as the OpenSSH `algorithm base64` string. A changed key is a hard error and
  never overwrites the pin; an intentional rekey means deleting the line.
- **Session selection is a command prefix, not channel env.** Citadel can send
  env requests, but they need `PermitUserEnvironment` in sshd, which is off by
  default. sshd runs an exec command through the login shell, so
  `env -u HERDR_SOCKET_PATH HERDR_SESSION=x herdr …` works everywhere. Every
  argument is single-quoted.
- **`herdr` is usually not on the PATH of a non-login shell** — verified: an
  exec channel gets `env: herdr: No such file or directory`. Saved hosts carry
  an absolute `herdrPath`.
- **A clean detach looks like an error at the Citadel layer.** After
  `terminal.release` the remote exits and the channel is gone, so the scoped
  `withExec` teardown throws `Already closed`. `SSHStream` tracks whether
  stdout drained normally first and finishes cleanly when it did — without
  that, every detach reports a spurious failure.
- Citadel is not `Sendable`-audited, so `SSHClient` cannot live in an actor.
  `SSHTransport` is a lock-guarded `final class` and `UnsafeTransfer` is the
  single, documented escape hatch in the package.
- The console tool takes `user@host[:port]` plus `--key PATH`; nothing is read
  from `~/.ssh/config` in Phase 1. Bare IPv6 (`user@fe80::1`) is accepted;
  brackets are required to add a port (`user@[fe80::1]:2222`).

## Pairing and peer identity (stable rules — do not relitigate per PR)

Pairing is how a phone acquires a host. The Mac-side `bleat pair` does the hard
part — it already knows everything the phone needs — and the phone scans one QR.

### The key exchange: the durable private key never leaves the phone

**Never put a long-lived private key in the QR.** A QR on screen is captured by
anyone in the room, by any screen share, and by any recording; in a terminal it
lands in scrollback, which iTerm2 persists to disk by default and tmux keeps in
history, so the key outlives the pairing. An SSH private key is arbitrary
command execution on the host — it is the highest-value secret in the flow.

The QR carries a **single-use enrollment key** instead:

1. `bleat pair` mints a temporary ed25519 key and appends it to
   `~/.ssh/authorized_keys` with a marker comment identifying it as a Bleat
   enrollment key.
2. The QR encodes: endpoints, port, username, the **raw 32-byte seed** of the
   temporary key, and the **host key in OpenSSH `<algorithm> <base64>` form**.
3. The phone scans, connects with the temporary key, and pins the host key by
   comparing it to the one from the QR.
4. The phone's first action over that channel is to generate its **own** key in
   the Keychain, append that public key to `authorized_keys`, and delete the
   temporary line.
5. The tool confirms the swap and exits; on timeout or abort it removes the
   temporary line itself. The temporary key is never reused.

**Dropping the key when nobody redeems it needs three layers**, because no
in-process cleanup is complete (verified 4 Sept 2026, all four paths exercised
against a scratch `HOME`):

| how pairing ends | what removes the key |
|---|---|
| normal exit, or an error | `defer` |
| Ctrl-C, `SIGTERM`, `SIGHUP` | `DispatchSourceSignal`, exit 130 |
| `SIGKILL`, panic, power cut | **nothing can run** — see below |

The third row is why the line carries sshd options:
`restrict,expiry-time="<UTC>Z" <key> bleat-enroll-<id>`.

- `expiry-time` makes **sshd** refuse the key once the moment passes, which
  holds however the tool died. Verified against a real sshd: accepted before,
  `Permission denied` after. UTC with a `Z` suffix, since a local-time deadline
  would shift under DST.
- `restrict` drops forwarding, X11 and PTY. Exec channels still work, which is
  all pairing needs — also verified against a real sshd.
- The deadline gets a 60s grace beyond the tool's own window, so a phone that
  connects a second before the end is not expired mid-swap.
- Every `bleat pair` **sweeps** stale `bleat-enroll-*` lines first, since a
  previous run killed outright could not. The sweep requires the `-enroll-`
  infix and so cannot touch a paired device's key.

**Both sides take a `mkdir` lock** around every mutating command, because
removal is a read-modify-write while the phone concurrently appends — the lost
update drops the phone's key, so it reports success and can never connect.
Three details are load-bearing and each was found by testing, not by reading:

- **Staleness is the lock's age, never how long a caller has waited.** Breaking
  after N failed attempts looks equivalent and destroys mutual exclusion under
  contention, because every waiter eventually reaches N and tears the lock from
  a live holder. Measured with 200 concurrent appends against 200 removals: the
  attempt-count version kept 16 of 200 keys and lost the user's own; by age, all
  200 survive.
- **A failed `mkdir` means contention only if the lock exists.** Otherwise the
  directory is unwritable and retrying can never succeed — that spun forever on
  an `~/.ssh` at mode 500. It now fails immediately, naming the cause.
- **Locked commands must not call `exit`**, or the lock outlives them.

**Cleanup has no "already done" latch.** A signal arriving between installing
the handlers and installing the key finds nothing to remove, and a latch would
mark itself done — then the key is installed a moment later and never removed.
Observed: a cancel 0.6s in exited 130 while leaving the key behind. Removal is
idempotent, so it always runs.

**`exit()` does not run `defer`.** The cancel path therefore runs cleanup
explicitly, and `Cleanup.run()` holds its lock across the shell call so a second
caller waits rather than returning early into `exit`.

**Redemption means a *new* device key appeared**, not that any exists. A host
with a phone already paired has a device key from the start, so the weaker test
would turn any disappearance of the enrollment line into a false success.

Two properties this buys that trust-on-first-use does not: the durable key is
generated on the device and is never transmitted anywhere, and the host key is
pinned **out-of-band** rather than trusted on first sight. Exposure of the
enrollment key is bounded to the seconds between scan and swap, and it
self-destructs regardless of outcome.

Encode the raw 32-byte seed, not an OpenSSH PEM: ~150 bytes of payload instead
of ~600, which is a materially easier scan.

### A peer is a host key, not an address

**The peer's identity is its SSH host key.** The same machine presents the same
host key on every address it answers on — verified: reaching this Mac over
loopback, `.local` and its LAN address all yield
`SHA256:5kgLcSfLx2/OaEHRcfc7PhrQ2uLNlTc8aL19AfjYn78`.

So a paired peer is **one host key plus an ordered list of endpoints**, never a
single address. A machine reachable both on the LAN and over Tailscale is *one
peer with two endpoints*, not two peers.

- Re-pairing is idempotent: if the scanned host key matches an existing peer,
  merge the new endpoint into it. Never create a duplicate peer.
- A host key that changes for a known peer stays a **hard error**, as in Phase 1.
  It is the identity; a mismatch is not a new endpoint.
- `bleat pair` enumerates what it can and accepts `--endpoint` for the rest:
  - mDNS name (`scutil --get LocalHostName` + `.local`) — LAN only
  - routable interface addresses from `ifconfig` — LAN v4, global v6
  - Tailscale addresses arrive **via `ifconfig`** — the tunnel's `utun`
    interface holds them and they pass every filter, then `Endpoint.reach`
    classifies them `.overlay`. Verified on device over cellular, 7 Sept 2026.
    This is how it worked before any Tailscale-specific code existed.
  - The **MagicDNS name** does need the CLI (`tailscale status --json` →
    `Self.DNSName`), because no interface carries it. `TailscaleStatus` parses
    it and `HostInspector` runs the command, from an absolute path — `run` does
    not search `PATH` deliberately, since resolving a tool through the user's
    `PATH` during pairing is a way to execute something else entirely.
    - **`DNSName` comes back fully qualified, with a trailing dot.** Verified
      live: `rawillk.tail2a3bab.ts.net.`
    - Taken only when `BackendState` is `Running` — a stopped or logged-out
      Tailscale still reports the last state it knew, and an endpoint recorded
      from a tailnet the machine may have left is indistinguishable later from
      a host that is merely switched off.
    - …and only when `CurrentTailnet.MagicDNSEnabled` is true, or the name does
      not resolve and every race spends a timeout on it.
    - It earns its place because a node's address is stable only while its node
      record lives: removing the machine from the tailnet and re-adding it
      mints a new one. The name follows the machine across that.
  - **Twingate and similar zero-trust overlays give the host no address of its
    own, and this is a different shape from Tailscale rather than a gap in the
    detection.** A mesh puts an address on every node's own interface, which is
    why `ifconfig` finds Tailscale. A zero-trust client instead runs a Connector
    inside the private network and routes the *client* to resources by their
    ordinary private address or private DNS name. There is nothing new on the
    host to discover, and there never will be.
    - So the endpoint that works over Twingate is the host's **plain LAN
      address**, which is already enumerated and already in every peer record.
      What was wrong was on the phone: `endpointsToTry` dropped private
      addresses the moment the phone left Wi-Fi, so the one candidate that
      would have connected was never dialled. See **Endpoint selection on the
      phone**.
    - A private *DNS name* still has to be user-supplied via `--endpoint`,
      since nothing on the host knows it.

### The QR carries the host key, not its fingerprint

`KnownHostsStore` pins the OpenSSH `<algorithm> <base64>` string —
`PinningHostKeyValidator` builds exactly that via `String(openSSHPublicKey:)`
— so that is the form the QR must carry. A `SHA256:` fingerprint can only be
*displayed*, never compared against a pin, and shipping one would have made
every paired connection fail its pin check. It costs about 30 bytes in the QR.
Show the fingerprint derived from it; never store one as the identity.

### Which host key the QR names (verified 4 Sept 2026)

NIOSSH offers exactly `ssh-ed25519`, `ecdsa-sha2-nistp384`,
`ecdsa-sha2-nistp256`, `ecdsa-sha2-nistp521`, in that order, and **the
client's order wins** — `SSHKeyExchangeStateMachine` walks its own list and
takes the first the server also offers. So on any host with an ed25519 host
key, which is every modern OpenSSH, that is the key the phone sees, and its
fingerprint is what belongs in the QR.

Two consequences:

- **NIOSSH does not speak `ssh-rsa` at all.** An RSA-only host cannot be
  paired, and `bleat pair` should say so at the keyboard rather than hand out
  a QR that fails on the phone.
- A host commonly has four host keys (this Mac has dsa, ecdsa, ed25519, rsa).
  Reading the wrong one yields a key that matches nothing, which surfaces as a
  host key mismatch on every attempt.

**Read the key from the running sshd, not from `/etc/ssh`.** `ssh-keyscan -p
<port>` is ground truth; the files on disk are only the *system* sshd's keys.
A host serving SSH on another port — including the throwaway `/usr/sbin/sshd`
this file's own test procedure runs on 2222 — presents a different key
entirely. Verified: with a throwaway sshd on 2222, `bleat inspect --port 2222`
reports `SHA256:DxXu3g15…` while port 22 reports `SHA256:5kgLcSfL…`. Reading
the file would have pinned the wrong one and made the phone reject every
connection. The files remain a fallback for when nothing answers on the port.

### Which local addresses are offered

Only two of this Mac's ~30 addresses are usable endpoints. The filter drops
loopback and AWDL (`lo0`, `awdl0`, `llw0`), interfaces that are not `UP` **and**
`RUNNING` (a down port still prints its last address), host-only virtual
interfaces (`bridge*`, `vmnet*`, `vnic*`, `vboxnet*` — Parallels, VMware and UTM
addresses pass every other filter, and if the phone's LAN overlaps that range it
reaches an unrelated device and fails *host key verification* rather than merely
failing to connect), link-local (`fe80::/10`, `169.254.`), `deprecated`
addresses, and — the one that would otherwise bite — **`temporary` addresses**. Those are RFC 4941 privacy addresses and rotate by design, so
pinning one gives a peer that works today and fails tomorrow with nothing to
show why. Only the stable `secured` address is kept.

`bleat inspect` prints the whole list with each endpoint's reach, which is the
first thing to run when pairing misbehaves.

### Displaying the QR

`CIQRCodeGenerator` on macOS and `QREncoder` on Linux (see **The console tool
builds for Linux**). `QRMatrix` and its renderer are in `BleatKit` and shared.

- **Draw on the alternate screen** (`\e[?1049h`), never the normal one. A QR on
  the normal screen stays in scrollback, which iTerm2 persists to disk and tmux
  keeps in history, so the enrollment key would outlive the pairing somewhere
  nobody thinks to clear. Restoring is part of `Cleanup`, not a `defer`, because
  `exit` skips defers and the cancel path exits — a cancelled pairing that left
  the alternate screen up would hide the user's shell until they typed `reset`.
- **Half-blocks, two module rows per line.** Terminal cells are about twice as
  tall as wide, so one module per cell doubles the height and many scanners
  refuse it.
- **Set black-on-white explicitly.** The block glyphs carry the *foreground*
  colour as ink, so an unstyled render is inverted on a dark theme.
- **`CIQRCodeGenerator` gives a 1-module quiet zone** and the spec wants 4, so
  three more are added.
- **Read the bitmap rows straight through — do not reverse them.** A
  `CGBitmapContext`'s *coordinate* origin is bottom-left, but its backing buffer
  is stored top row first, so `pixels[0..<size]` is already the top scanline.
  Reasoning from the coordinate origin and reversing mirrors the symbol
  vertically: finder patterns land top-left, bottom-left and bottom-right
  instead of top-left, top-right and bottom-left. **This shipped once.**
- **Decodability is not an orientation test.** `CIDetector` reads a mirrored
  symbol without complaint, which is why a decode round-trip missed the bug
  above; zbar, ZXing and many Android scanners do not. Assert finder positions —
  `QRMatrix.hasCanonicalFinderPatterns(quietZone:)`, covered in
  `BleatProcessTests` — and treat a decode as a separate, weaker check.
- **Not a TTY means no QR**: a pipe or a redirect gets the link only.

**Size, measured with a real payload (5 Sept 2026).** An earlier note quoted
versions measured with a string of `A`s — that is *alphanumeric* mode at 5.5
bits per character, while a `bleat://` URL is lowercase and punctuated and so
encodes in *byte* mode at 8 bits, about 12 modules larger for the same length.
**The payload is a compact binary form, not JSON** (`PairingWire`). JSON keys,
quotes and braces were about forty characters of pure structure, and base64 then
inflated the whole thing by a third — in a medium where every byte is modules
and modules are terminal rows the user may not have. Both ends ship together, so
there is nothing to negotiate and no reason to pay for self-description. Layout
and the reasoning are in `PairingWire`.

Alongside it, three redundancies went:

- The host key travels as its **bare 32 bytes** for ed25519, which is what the
  phone negotiates. The text form named the algorithm and the wire blob repeats
  it again in 19 bytes of framing; `SSHPublicKeyLine.ed25519(rawKey:)` rebuilds
  the exact OpenSSH string the pin compares against. Other algorithms travel as
  a blob, told apart on the way in by length.
- Endpoints **omit port 22**, which `Endpoint(string:)` defaults to.
- Correction level is **L**. The higher levels buy recovery from print wear,
  dirt and creases; this code is drawn pixel-exact, scanned from a foot away and
  gone in minutes.

**`herdrPath` is deliberately not in the QR; the client resolves it.** A baked
path costs 24 bytes and goes stale the moment herdr moves, so discovering it is
both smaller and more robust. `Enrollment` asks `HerdrLookup.command`
(`${SHELL:-/bin/sh} -lc 'command -v herdr'`) on the enrollment connection and
stores the answer on the `PairedPeer` — **before** anything is written, so a
host without herdr is refused with nothing to undo. `PairedPeer.herdrPath` stays
optional because a record can predate that. Reading the answer is
`HerdrLookup.path(inOutput:)` and both ends use it: a login shell sources the
profile, profiles print banners, and taking the whole of stdout stores
`"Welcome back!\n/opt/homebrew/bin/herdr"` as the path.

Measured across these changes on the three-endpoint case: the URL went
**411 → 383 → 350 → 221** characters and the rendered code **85 → 77 → 73 → 61**
columns, 43 → 31 rows.

**Tailscale spends some of that back, and it is worth knowing how much.**
Measured 7 Sept 2026 at level L with a 4-module quiet zone, and pinned by
`QRPayloadSizeTests`:

**Measure at `quietZone: 3`, which is what `bleat pair` renders.** The
parameter is *extra* modules on top of the one `CIQRCodeGenerator` emits, so 3
draws the 4 the spec wants. Measuring at 4 inflates every figure by a row — a
wrong-but-plausible number, which a first version of the table below had.

| endpoints | modules | rows |
|---|---|---|
| 4 — LAN plus both Tailscale addresses | 61 | 31 |
| 5 — and the MagicDNS name | 65 | 33 |
| 7 — everything this Mac offers | 73 | 37 |

So the name costs two rows and a Tailscale-connected Mac costs six over a
LAN-only one. With three rows of chrome the worst case needs **40** — one row
inside the reduced-margin threshold this file measured earlier. A shorter window
falls back to the link. `QRPayloadSizeTests` defends that row.

**Height is the binding constraint, so nothing is spent on it carelessly.**
Chrome is three rows — title, host key, footer — with no blank spacers: the QR's
own quiet zone already separates it from the text, and on a 141×47 window the
two blanks that used to be there were the whole difference between a code and a
fallback. The last line carries no trailing newline, which would scroll the
alternate screen and push the title off when the content exactly fills it.

**The quiet zone adapts rather than giving up.** Four modules is tried first,
then two, and only then does it fall back to the link. Two still scans, and
losing the QR entirely over one row is the worse outcome. Measured on a
141-column window: 47 rows renders at the full margin, 41 at the reduced one, 39
falls back. The shortfall is reported against the **smallest** option tried, so
it names the real gap rather than the gap to the margin we would have preferred.

**Light modules are grey (`0x8C`), not white.** A white panel this size glares
in a dark terminal, and the contrast a decoder needs — roughly 3:1 — leaves
room: black on `0x8C` measures **6.3:1**, against 21:1 for white. That is still
twice the floor, but close enough to it that going darker should be measured
rather than guessed. Only the light modules move; dimming the dark ones would
spend the same margin while making the ink itself less distinct.

Verified end to end: the glyphs written to a pty were parsed back into modules
and decoded with `CIDetector`, returning the exact `bleat://pair?d=…` URL. That
proves the *payload* survives the render; it says nothing about orientation, for
which see the finder-pattern note above.

### The phone's side of the swap (verified end to end, 5 Sept 2026)

`PairingClient` is the whole of it, and `bleat redeem <url>` runs the same code
path from a terminal so it can be exercised against a real `bleat pair` without
a phone. The order is fixed and each step exists because of a way the previous
one lies:

1. **Resolve `herdr` first**, while nothing has been written. A host that cannot
   serve the app is refused with nothing to undo.
2. **Replace this device's line in one command.** Re-pairing a known phone must
   not add a second copy of the same key under a second marker — and must not
   have a moment where the key is *absent* either. A removal followed by an
   append has that moment, and for an already-paired phone it holds its only
   durable credential; if the append then failed quietly the phone would have
   destroyed the access it arrived with. `replaceKeyCommand` does the whole
   edit in a temporary file and lands it with one write.
3. **Verify the line is there.** An append that succeeded loudly and did nothing
   — `StrictModes`, a full disk, an unwritable `~/.ssh` — reads back as absent.
4. **Open a second connection authenticated with the device key.** This is the
   step that matters, and the one a file check cannot substitute for: a line in
   `authorized_keys` is not the claim "sshd will accept this key". Found live —
   an sshd whose `AuthorizedKeysFile` pointed somewhere other than the session's
   own `~` passed every file check and reported a pairing that could never have
   worked. One handshake buys certainty.
5. **Only then delete the enrollment key**, over the *device* session, and
   verify it is gone. `bleat pair` calls the pairing done when the enrollment
   line is gone **and** a new `bleat-device-` marker has appeared, so a removal
   that exited 0 without removing anything would hang the tool while the phone
   claimed success.

Every failure before step 5 leaves the enrollment key live, so the user scans
again rather than walking to the Mac.

**Absence must be a normal answer, not a failed command.**
`HerdrLookup.command` ends in `|| true`, because `command -v` exits 1 when it
finds nothing and the login shell exits with it. Without that, a host without
herdr produces a failed *command* over the exec channel and the user is told
`the host rejected a command (exit 1)` — the `herdrNotFound` guard downstream is
unreachable. Verified both ways against a real shell.

**The phone's verification reads take the `mkdir` lock; the host's poll does
not.** Every write-back here is `cat "$t" > "$f"`, which truncates before it
writes, so an unlocked read landing in that instant sees an empty file — and the
phone's read decides whether a pairing failed. The host polls ten times a second
and would contend continuously, and a wrong answer there only costs a tick.

**The phone deletes the enrollment line by key, not by marker.** The marker is
minted on the host and the QR does not carry it — a field existing only so the
other side can name a line would be paid for in modules on every pairing. The
key is already in the phone's hands. `AuthorizedKeys.keyPattern` matches the
base64 blob as a **whitespace-delimited field** (base64 is not self-delimiting)
and escapes ERE metacharacters — `+` is in base64's alphabet, and unescaped it
would turn the pattern into a wildcard that `grep -v` then deletes by.

**Two host key mechanisms, and the app uses the stronger one.**
`HostKeyPolicy.knownHosts` is trust-on-first-use in a file, keyed by
`host:port` — the console tool's, because it is handed a hostname and has
nothing else. `HostKeyPolicy.expect` compares against a key learned out of band,
from the QR and afterwards from the `PairedPeer`. It writes nothing, which
matters: a peer is identified by its host key while its *addresses* come and go,
and a recycled DHCP lease would otherwise leave a stale pin at
`192.168.1.50:22` that no legitimate pairing could get past. Verified live: with
the genuine sshd stopped and an impostor on another port answering with a
different key, redemption is refused.

**Endpoints are raced, not tried in order.** The first entry is usually a
`.local` name, and off the LAN that does not fail so much as sit there while the
working overlay address behind it never gets a turn.

**The race must return on the first win, and a task group cannot do that.**
Leaving a group's scope awaits every child, and `group.cancelAll()` cannot
shorten a losing attempt: `SSHClient.connect` does not observe task
cancellation, so a dead address still costs its full TCP timeout — which is the
very cost the race exists to avoid. `PeerConnector` therefore runs the group in
a **detached** task and hands the winner back through a continuation; the drain
keeps running, **closes** any connection that finishes late (`SSHClient` has no
deinit that does it, and an abandoned session stays open on the host), and ends
by itself. Measured: with a black-holed address in the list — one that swallows
SYNs for four seconds rather than refusing — pairing completes in **0.2s**.

**What is raced is the handshake, not a command.** `SSHTransport.connect()`
proves TCP, the host key, key exchange and authentication, which is everything
"this endpoint works" can mean. An earlier version ran `printf ok` and compared
stdout exactly — but `.zshenv` is sourced for every non-interactive zsh, so
anything a user's startup file prints would have made every healthy endpoint
fail, and the message blames the network.

**When every endpoint left is an overlay address, the message names the VPN** —
`TransportError.overlayUnreachable`. On cellular against a Tailscale-only host,
`endpointsToTry` has already dropped the `.local` name and the LAN addresses as
unroutable, so if nothing answered the likeliest cause is the tunnel being down
on the *phone*, and "none of N address(es) could be reached" sends the user to
check a network that is working perfectly. `PeerConnector` cannot see the VPN's
state (`Network` is Apple-only and that file compiles for Linux), so it names
the possibility rather than asserting it. A mixed list keeps the ordinary
message: a LAN address among the candidates means the phone is on Wi-Fi and the
host is simply off, asleep, or elsewhere.

- **It fires only when the caller passes `droppedUnroutable`, and that flag is
  load-bearing.** Only `PeerConnection.connect` can vouch for it, because only
  it filtered. Pairing calls the connector a second time with a deliberately
  narrowed list — one endpoint, the one that just carried the enrollment
  handshake — to ask whether this host accepts the new device key, and every
  candidate there is trivially an overlay address. Without the flag the user
  would be told to check a VPN that had demonstrably just worked, at the one
  moment in the flow where the enrollment key may already be spent and
  rescanning is not an option.
- **It is its own error case rather than a `connectionFailed` with different
  words**, because callers classify on the case. `PairingModel` reads a plain
  `connectionFailed` as possibly iOS's local network permission and waits a
  minute for an answer — which cannot be the cause when no local address was
  dialled at all.

A host key mismatch is promoted over every other failure when nothing wins — it
is the only outcome that is not about the network, and reporting it as "no
address answered" sends the user to check their Wi-Fi. Verified live: with the
genuine sshd stopped and an impostor answering on another port, redemption is
refused.

**A merge takes the endpoint that just worked.** `PairedPeer.merging` keeps the
older record's endpoints but takes the newer `lastGoodEndpoint`, for the same
reason it takes the newer `herdrPath`: the fresh record is the one that just
reached the machine. Keeping the stored value sends the next connection to the
network the phone has left. Seen live — a re-pairing reported the *previous*
winner as the address it had just reached.

**Saving the peer is the one fallible step after the point of no return.** By
then the enrollment key is gone from the host, so rescanning the same code
cannot work — `PeerRegistry.all()` tolerates a *missing* file but not an
undecodable one, and that failure would otherwise be reported as a generic
pairing error. `PairingError.peerNotRecorded` says the host half succeeded and
sends the user to run `bleat pair` again rather than back to a dead QR.

**`PeerRegistry` is keyed by host key**, so pairing the same Mac again from a
second network merges into the record that exists. `HostRegistry` is keyed by a
user-chosen name and cannot do that; it predates pairing and stays as the
console tool's own list.

### Endpoints are refreshed on connect, not captured once (Phase 2)

Endpoints used to be read at pair time and never looked at again, so a Mac that
moved network, a Tailscale node removed and re-added, or a tunnel set up after
pairing each cost a full re-pair — walking back to the Mac to run `bleat pair`.
The host is the authority on its own addresses and the phone is already talking
to it, so it asks.

**This is safe because of what authenticated it.** Anything learned over a
connection already verified against the pinned host key is exactly as
trustworthy as the pin, which is what lets a refresh happen silently with
nothing to confirm.

`EndpointDiscovery` in `BleatKit` holds both the three probes and the assembly
of their answers, and **both ends use it**: `HostInspector` runs the commands
locally with `Process` while `bleat pair` mints a QR, and `PeerStore` runs them
over an exec channel on a connection it already has. Two copies of "which
addresses does this machine offer" would drift silently — the phone would keep
folding a peer into a shape `bleat pair` would never have produced.

- Every probe ends in `|| true`, for the reason `HerdrLookup.command` does:
  absence is a normal answer. Without it a host without `scutil` produces a
  *failed command* and the user is told "the host rejected a command (exit 1)"
  about a machine that is working perfectly.
- The probes run **serially**, not with `async let`. Three concurrent exec
  channels would save a few hundred milliseconds of work nobody waits for, in
  exchange for exercising concurrent use of `SSHTransport` — which wraps a
  Citadel client that is not `Sendable`-audited and is lock-guarded for exactly
  that reason. Serial is also what makes the cancellation checks between them
  mean anything.
- It runs **after** the connection is installed and is never awaited by the
  screen, so a list draws at the same speed it always did — and only on a fresh
  dial, since a reused connection returns before reaching it.

**Cancelling the refresh is not enough on its own, and this is the sharp
edge.** `SSHTransport` re-dials lazily when its client is nil and
`SSHClient.connect` does not observe cancellation, so a probe command that runs
after `ConnectionStore.release()` has disconnected opens a **brand new SSH
session** that nothing references and nothing will close — an orphaned session
on the user's Mac, which is the one thing `ConnectionStore` promises not to
leave. So `EndpointDiscovery.probe` checks `Task.isCancelled` between every
command, a cancelled probe reports **nothing at all** rather than a partial
answer, and `release()` *awaits* the task exactly as it already does a dial in
flight.

### The `tailscale` probe, and what running it taught

Same loop as `HostInspector.tailscaleStatusJSON` — absolute paths, in order,
first that *answers* — with a five-second watchdog, since `tailscale` has no
timeout flag and a wedged `tailscaled` would hold the exec channel for the life
of the connection. Four of its details were bugs, and each was found by running
the string rather than reading it:

- **`status` is read-only in `zsh`**, which is what sshd runs on a modern macOS.
  Naming the exit status that aborted the whole loop under the one shell it will
  actually meet, while working under `sh` and `bash`. Verified across all three
  now.
- **Each attempt writes to its own scratch file.** Straight to stdout, the
  attempts concatenate: a binary that emits a partial object before failing, or
  one killed mid-write by the watchdog, glues that fragment to the front of the
  next binary's reply. Reproduced — `{"partial":{…}{"BackendState":…}` — which
  parses as nothing, so the loop written to save the MagicDNS name lost it in
  the exact case it exists for.
- **Exiting 0 is not answering.** A Homebrew CLI that cannot reach the App Store
  app's daemon exits cleanly reporting `NeedsLogin` or `Stopped`, so stopping at
  the first clean exit never tries the bundled binary that would have answered.
  The condition is `BackendState == "Running"`, greped here and checked by
  `TailscaleStatus.isRunning` locally; the two have to agree.
- **The watchdog's output goes to `/dev/null`** so it is not a writer on the
  channel — attached, it holds the command open for the full five seconds on
  every run — and `exec 2>/dev/null` suppresses the shell's `Terminated: 15`
  notice when the watchdog is killed.

**What a refresh may change, and the four rules that bound it.** `PairedPeer`
gains `hostReport`, the host's most recent self-report **kept per probe**.

- **`nil` is not an empty report.** `nil` means never refreshed, so nothing on
  the record can be attributed to the host and the first refresh may add but
  must not prune. Without that distinction every `--endpoint` extra baked into
  a QR would vanish the first time the phone connected after this shipped.
- **A report no probe answered changes nothing.** That is the host being
  unaskable — or the refresh being cancelled — and not the host saying it has no
  addresses. Reading it as one would empty the peer and strand the phone with a
  record it can never connect through again.
- **Pruning is per probe, not per report, and this is the one that matters
  most.** Flattened into a single list, one flaky probe is indistinguishable
  from a host that has dropped a whole category. Tailscale being switched off is
  not even an error — the CLI exits 0 with `BackendState: "Stopped"` — so
  `scutil` and `ifconfig` answering normally would yield a perfectly non-empty
  report with no overlay endpoints in it, and one pass would delete the MagicDNS
  name and both tunnel addresses. The next time the phone was on cellular the
  host would be unreachable **permanently, from a transient condition** — which
  is the exact cost this feature exists to remove. So each of the three fields
  in `EndpointDiscovery.Report` is independently optional: `nil` means "this
  probe gave no confident answer" and prunes nothing, while an empty array is a
  real answer.
- **Only what the host previously claimed may be pruned.** Everything else is
  sticky — `--endpoint` extras, anything added by hand — because detection
  cannot see them and their absence from a report is not evidence of anything.
  This is what protects a Twingate private DNS name.
- **`lastGoodEndpoint` survives, for one refresh.** It completed a handshake
  minutes ago, which outranks any report about it. Putting it back is recorded
  in `Report.reinstated` so the exemption *expires*: unrecorded, it reads as an
  address the host never claimed and becomes permanently un-prunable, so a
  recycled DHCP lease that won one race would live in the peer forever — the
  very hazard the pruning exists for.

**Discovery yields addresses, never ports**, so a refresh must not invent one.
`scutil`, `ifconfig` and `tailscale` all report where a machine is found and
none of them knows what port its sshd binds — that was settled once, by
`bleat pair --port`. `PairedPeer.discoveryPort` is the port the peer already
associates with the host: the most common one across its endpoints.

The obvious alternative strands the peer. Taking the port of the endpoint that
just won the race looks right — it demonstrably reached sshd — but the winner
can be a hand-added port forward, which is the motivating reason to add one. A
peer with three `:22` addresses plus a typed `home.example.com:2222` connects
over the forward from cellular; the refresh then rebuilds every discovered
address at 2222 and supersedes the three that worked. Back on Wi-Fi nothing
connects, and since no connection succeeds no later refresh can repair it — a
re-pair, caused by using the feature exactly as documented.

**Pruning matters as much as adding, and it is the half that is easy to skip.**
A list that only grows accumulates recycled DHCP leases and dead node
addresses, each dialled on every connection afterwards. Worse than the wasted
race slot: a recycled address reaches an unrelated machine and fails *host key
verification*, and `PeerConnector` promotes a mismatch over every other failure
— so a sleeping Mac plus one stale address reports a security warning instead of
"could not reach it". `InterfaceAddresses.ignoredPrefixes` exists to avoid the
identical hazard from virtual interfaces.

`PeerRegistry.recordDiscoveredEndpoints` is a **targeted mutation**, for the
reason `recordHerdrPath` is one and more urgently: `save` merges, a merge takes
the newer record's `lastGoodEndpoint`, and this runs moments after
`recordSuccess`.

**It is a hedge, not a guarantee.** A refresh only happens over a connection
that still works, so a host whose every stored endpoint died at once is still a
re-pair. What it removes is the far more common case where *one* of them
changed.

### Addresses added by hand (Phase 2)

The backstop under the other two. Pairing enumerates what the host can see about
itself and a refresh asks it again on every connection, but **neither can
produce an address the host does not know it has** — which is exactly a
zero-trust overlay's private DNS name, held entirely on the client's side. It
equally covers a port forward or a jump address, which have no discovery story
at all.

`PeerSettingsView`'s "Reachable at" section adds and swipes-to-remove;
`PeerRegistry.addEndpoint` / `removeEndpoint` are targeted mutations like the
rest.

- **An added address is never written into `hostReport`**, which is
  what makes it permanent: a refresh may only prune what the host once claimed,
  so an address the host has never mentioned survives every refresh there will
  ever be. That is the entire point of adding it.
- **Removing the last-good address clears `lastGoodEndpoint`, and that is
  load-bearing.** `refreshingEndpoints` restores the last-good address
  unconditionally — it completed a handshake, which outranks any report — so a
  removal that left the field pointing at a deleted address would be silently
  undone by the next connection's refresh, minutes later, with nothing on screen
  to explain it.
- **The last address cannot be removed**, and the swipe action is hidden rather
  than shown and refused. A peer with none is unreachable *and* unrepairable
  from the phone: nothing is left to connect over, so nothing can add one back.
  Unpairing is the deliberate way to be rid of a peer.
- **An address the host still reports comes back on the next refresh**, and the
  section footer says the list maintains itself so this is not a surprise. A
  tombstone would make removal stick, at the cost of a way to blind the app
  permanently to a working address — racing one extra endpoint concurrently is
  much the cheaper mistake. An address the host has *never* reported stays
  removed, which is the case that matters: a stale entry from a QR.
- The port defaults to **the peer's own**, not 22. An address typed without one
  silently inheriting 22 on a host running sshd elsewhere produces an entry that
  looks right in the list and refuses every connection — the same trap
  `bleat inspect --endpoint` avoids by re-parsing against `--port`.
- **`Endpoint(string:)` is a parser, not a validator**, and this is the first
  place it is fed free text. Anything without a colon becomes a hostname
  verbatim, so `ravil@mac.internal` — a very natural paste — `ssh mac.local` and
  `mac.local/foo` would all enable the button and be stored. Permanently:
  detection can never report them, so no refresh prunes them, and each is
  dialled in every race from then on and counted in the message explaining the
  failure. `Endpoint.isPlausibleHost` is the second half of the check, and it is
  deliberately a plausibility test rather than a hostname grammar — rejecting a
  valid internal name is the worse failure, since the user has no other way to
  add it.
- **`Endpoint` lower-cases its host.** DNS is case-insensitive and
  `Equatable`/`Hashable` are not, and every comparison in the refresh path runs
  on that equality: de-duplication, `Report.superseded`, `endpoints.contains`,
  the `lastGoodEndpoint` match. `RawillkAir.local` beside `rawillkair.local`
  would be two endpoints for one machine, and the second could never be pruned —
  the host reports one form, so the other looks like an address it never claimed
  — leaving every race dialling the host twice forever. Reachable both by typing
  and from `scutil --get LocalHostName`.
- **Removing takes a deliberate tap** (`allowsFullSwipe: false`) and failures
  are shown *here*. An address added by hand is one detection can never report,
  so deleting it is permanent and undone only by retyping it; and a failed write
  would otherwise leave the row where it was with the message a screen back on
  the peer list, so the swipe would look like it had simply done nothing.
- **`PeerSettingsView` takes a host key, not a peer.** `PeerDetailView` can
  take the record as a plain value because `RouteView` looks it up on every
  body evaluation and swaps the whole screen out when it goes — but a sheet is
  presented once, from a router, and a captured `PairedPeer` would be stale the
  moment the user added or removed an address: the list they were looking at
  would not change. It looks the peer up itself and shows the same
  unpaired-message when the record is gone, which the root-level unpair flow
  can do while the sheet is still on screen.

### Connecting to a paired peer (Phase 2)

`PeerConnection.connect` is where the pairing record pays off: everything the
connection needs was learned once, out of band — which machine this is (the host
key), where it answers, who to log in as, and where `herdr` lives. Nothing
prompts, guesses, or trusts anything on first sight.

- **One live connection at a time**, held by `ConnectionStore`. A phone drills
  into a single host, and every screen in that drill-down wants the same SSH
  session rather than a handshake each. Returning to the peer list releases it —
  re-entering costs a handshake, an idle SSH session left open on someone's Mac
  costs their trust.
- **Keeping that promise takes more than a stored reference, because a dial
  cannot be called off.** `PeerConnector` races in a detached task precisely so
  a slow address cannot hold up a fast one, so a handshake started for a screen
  the user has already left will still finish. Two guards follow: concurrent
  callers **join** the dial in flight rather than starting a second (otherwise
  a pull-to-refresh during the first load races every endpoint twice and leaks
  whichever transport loses the assignment), and a dial that completes after
  `release()` **closes itself** instead of installing. `SSHTransport.disconnect`
  documents the same hazard for its own dial; the store reproduced it one level
  up before this.
- **A cached connection is keyed by link state as well as host key.** It is
  raced once and then pinned to the address that won, so one made on Wi-Fi
  against a `.local` name can only fail after the phone moves to cellular —
  and the overlay address that would have worked never gets a turn, because the
  cache answers first. `ConnectionPolicy` holds this and the "is this error
  fatal to the connection?" rule, in `BleatKit` where both are tested.
- **A `HerdrError` does not discard the connection.** The host was reached and
  said no. Reconnecting on it would cost a handshake per retry and hide the
  real problem behind a reconnection that always succeeds. `TransportError`
  does discard it, which is what lets a retry re-race after a network change.
- **Every list load carries a generation.** Pull-to-refresh and the initial
  `task` overlap, and without one a slow first load finishing late overwrites a
  successful refresh with its own failure — an error banner over rows that
  arrived perfectly well. Refreshing also keeps the rows on screen: `refreshable`
  draws its own spinner, and replacing the list underneath it is a downgrade.
- **Reachability is two questions, not one**, and `LinkState` carries both: is
  a local network directly attached, and is there a tunnel. It used to be the
  single question "is this Wi-Fi or Ethernet", which quietly assumed anything
  private needs the attached link — true until a VPN routes the private subnet,
  which is exactly what a zero-trust client does. `Reachability` lives in
  `BleatUI` rather than `BleatKit` — `Network` is Apple-only — while `LinkState`
  and the rules it feeds are in `BleatKit` where they are tested.
  - **The tunnel question needs its own `NWPathMonitor(requiredInterfaceType:
    .other)`.** Asking the default path with `usesInterfaceType(.other)` gets
    the wrong answer for the case that matters: Twingate and most zero-trust
    clients split-tunnel, claiming routes only for configured resources, so the
    **default** path stays on cellular and does not use the tunnel at all. A
    monitor with a required interface type reports satisfied when such an
    interface exists and can carry traffic, which is the question being asked.
  - **`LinkState` is the cache key for a live connection**, not just an input to
    the race. A tunnel coming up widens the candidate list, so a connection made
    before it connected was raced over a strictly smaller set; reusing it would
    pin the phone to that set for as long as the screen stays open — the same
    shape of bug the Wi-Fi/cellular half was added to fix.
    - Compared through **`LinkState.candidateIdentity`**, not as a whole. On the
      local link every endpoint is a candidate whatever the tunnel is doing, so
      a tunnel change there cannot alter the raced list — and comparing it would
      discard a working connection for nothing. An on-demand VPN profile
      connecting and dropping while the app sits on Wi-Fi would otherwise tear
      down the live SSH session and re-handshake on every request.
- **"No address to try here" is not "nothing answered."** A LAN-only peer on
  cellular was not dialled and failed; it was ruled out, and the remedy is a
  different network or an overlay endpoint rather than a host that needs
  starting. The two get different messages.
- **`herdrPath` can still be discovered**, for a record made before pairing
  stored it, and the transport learns it in place rather than being rebuilt —
  a second handshake to carry one string would be absurd.
- **Write-backs after a successful connection are targeted mutations, never a
  `save` of an edited copy.** `save` merges, and a merge takes the newer
  record's `lastGoodEndpoint`; a copy loaded a moment earlier carries the
  *previous* winner, so saving it undoes the one just recorded. Both
  `recordSuccess` and `recordHerdrPath` edit the stored record in place.

### The list screens (Phase 2)

Sessions, workspaces and agents are the same screen three times, so the loading
is written once: `RemoteList` holds the generation token, the cancelled-screen
silence, the drop-a-dead-connection rule and the keep-rows-through-a-refresh
rule. Three copies of that would drift, and each way it drifts is a bug the user
sees rather than a crash anyone catches. `RemoteListView` does the same for the
three states a fetched list has — a result that is empty is not a failure, a
failure needs a way back, and neither should look like the other.

- **Session selection does not cost a reconnect.** `HERDR_SESSION` is a command
  prefix, not something the handshake settles, so `SSHTransport.useSession`
  changes it on a live connection. Making the session part of the connection's
  identity instead would have meant a fresh handshake on every drill-down from
  the session list. It assumes one drill-down at a time, which is what the app
  does.
- **`pane_id` is already the full target.** The host sends
  `"pane_id":"w2:p1"` next to `"workspace_id":"w2"` — in the fixtures and live —
  so joining the two gives `w2:w2:p1` and every attach fails. `Agent.target`
  exists to stop that being rebuilt by hand, which is exactly how it went wrong
  once. A test that built its own `Agent` with a bare `"p1"` passed happily
  while the property was wrong; the test reads the fixture now. **Build model
  test data from `Fixtures/`, not from memory** — CLAUDE.md already said to look
  at the fixture before writing a model, and this is what skipping it costs.
- **A failed refresh keeps the rows it had.** `Loadable.stale` carries the last
  value alongside the failure, because replacing a good agent list with an
  error page over one dropped packet is a worse lie than showing slightly old
  data and saying so. An empty-state overlay is `allowsHitTesting(false)` for a
  related reason: it covers the whole list, and "no agents are running here" is
  precisely the message a user wants to pull-to-refresh out of.
- **A failed load says which of the three error classes it was.** CLAUDE.md's
  conventions name them — `HerdrError` (host said no), `TransportError`
  (network), `DecodingError` (contract drift) — and `RemoteListView` used one
  title for all three: *Could not reach the host*. Found on a live host, 8 Sept
  2026: a `phone` session whose herdr server was a protocol version behind the
  client answered with exactly what was wrong and how to fix it, and the phone
  reported it as a network failure over the top of that message. The user is
  sent to check a network that is working perfectly — the same lie
  `TransportError.authenticationFailed` was added to stop one layer down.
  - `Loadable` carries a `LoadFailure` now rather than a bare string, and
    `ErrorMessage.failure(of:)` does the classification in one place.
    `LoadFailureTests` pins it, on the real protocol-mismatch text.
  - A `HerdrError` shows **herdr's own `message`**, not `description`, which
    prefixes `herdr workspace list failed (1):`. That is right in a terminal
    and noise on a phone; herdr's sentence is usually the whole fix.
- **Ordering is not restated in the UI.** `HerdrClient.agents()` returns them
  already sorted by attention and `workspaces()` likewise, so the app cannot
  disagree with the console tool about what "blocked first" means.
- **`Agent.displayTitle` is in `BleatKit`**, because both the app and
  `bleat agents` have to choose among Herdr's three names — stripped title, raw
  title, agent kind — and each can be missing *or empty*. The tool's own version
  fell back to an empty string, so an untitled pane printed as a blank column;
  the shared one falls back to the pane id, which is at least unique.
- **A pane's `foreground_cwd` is shown in preference to `cwd`**, because it
  follows the running process, and it is truncated at the **head**: every row
  starts `/Users/…/Developer/…`, so truncating at the tail throws away the only
  part that distinguishes one checkout from another.

### A host's screen is its sessions; everything else is a sheet (Phase 2)

`PeerDetailView` used to be a `Form` with the sessions on top and four sections
of pairing detail under them — user, `herdr` path, host key fingerprint,
addresses, device marker, unpair. It is the sessions and a bottom bar now, and
the rest is `PeerSettingsView` behind the gear.

- **It is a `RemoteListView` like the workspaces and agents screens.** The
  section it used to be drew its spinner *in a row* on purpose, so the details
  below stayed readable while the host was being reached. With nothing below,
  that reasoning is spent and the four states belong in the shared list view —
  which is also where "an empty answer is not a failure" and "a failed refresh
  keeps its rows" are written once rather than twice. `SessionsSection` was
  deleted with it; `SessionLink` and `SessionRow` are unchanged.
- **`PeerSettingsRouter` is the third root-level router, for the third time for
  the same reason.** The sheet is opened from a swipe on the peer list *and*
  from the gear on a peer's own screen, and those two are in the navigation
  stack at the same time — a `.sheet` on each would be two presentations of one
  intent, of which SwiftUI raises whichever it reaches first and silently drops
  the other. `PeerSettingsFlow` presents it at the root beside `.unpairFlow()`
  and `.pairingFlow()`.
- **Unpairing from inside the sheet closes it first, and that ordering is
  load-bearing.** The confirmation dialog is presented at the root, *underneath*
  this sheet, so one raised while it is still up is covered by it and never
  seen — the Unpair button would appear to do nothing. The router holds the
  request instead and `PeerSettingsFlow` starts it from the sheet's
  `onDismiss`, which fires only once the dismissal has finished. A plain close
  clears it, or a later dismissal would unpair a host nobody asked about.
  `PreviewSmokeTests.unpairFromSettingsClosesTheSheet` pins both halves.
- **The sheet yields to a `bleat://` link**, exactly as the device-key sheet
  does: SwiftUI will not raise a second sheet over one already presented, so a
  pairing request arriving while settings is up would be lost *and* leave
  `PairingRouter.isPresented` true with nothing on screen — which makes the
  Pair button a no-op until the app is relaunched.
- **The swipe on a peer row still only asks.** It has two actions now, Unpair
  and Settings, and Unpair is declared first so it stays what a full swipe
  reaches — which is what `onDelete` did before. That is safe to trigger by
  accident precisely because it opens a confirmation rather than acting; see
  the unpair section for why a swipe must never revoke a key on its own.
- **The plus starts a session, in a cover rather than an overlay.** A scrim over
  the whole screen with one field above the keyboard and a checkmark beside it.
  A `fullScreenCover` with `.presentationBackground(.clear)`, because on iOS 26
  the bottom bar floats above the screen's content — an `.overlay` would leave
  the navigation bar undimmed and, worse, leave the plus button that opened it
  drawn on top of the scrim and still tappable. The scrim is the only way out
  and is **inert while the launch is in flight**, for the reason the pairing
  sheet cannot be dismissed mid-swap: this is the only place the outcome is
  reported. See **Starting a session** above for the command.
- **The gear zooms.** `matchedTransitionSource` on the gear, `.zoom` on the
  sheet, keyed by host key so it grows out of the gear for *that* host. The
  namespace cannot be local: the sheet is presented at the root and the gear is
  two screens down, so `PeerSettingsFlow` declares it and publishes it through
  `EnvironmentValues.peerSettingsNamespace`. Optional, because a `Namespace.ID`
  cannot be minted outside a `@Namespace` — a preview of `PeerDetailView` alone
  has none, and the swipe on the peer list has no gear on screen to grow from.
  A zoom with an absent source falls back to a plain presentation.
  **`.zoom` is unavailable on macOS** while `matchedTransitionSource` is not, so
  the platform branch lives in `zoomTransition` rather than at each call site.

### Previews (Phase 2)

Every view has a `#Preview`, and they all take `traits: .sampleData`. The trait
injects an `AppContext` — which every screen above a row reads from the
environment, so without one a preview of anything crashes on the missing value.
`.noHosts` is the same context with nothing paired, for the empty state that is
the first screen on a fresh install.

- **The context is real; the registry is not.** `PeerRegistry.sample()` writes
  the sample hosts into a fresh directory under `NSTemporaryDirectory()`, one
  per call. Never `applicationSupport()`: `AddEndpointView` and the unpair flow
  both *write*, so a preview pointed at the real registry edits the device's own
  peer list from the canvas. An earlier `AddEndpointView` preview built a plain
  `PeerStore()`, which is exactly that. A fresh directory per call rather than
  one wiped and reused, because Xcode keeps more than one preview alive and a
  shared path means the one being edited has its file rebuilt underneath it the
  moment another renders.
- **No preview reaches the network**, and that needs a seam rather than a
  promise: `ConnectionStore` is real, and every list screen loads in `.task`.
  `RemoteList.init(previewing:)` hands the rows in and makes `load` a no-op, and
  the screens that own one take a `#if DEBUG` initialiser that uses it. The
  guard is the **first** thing `load` does — after `state = .loading` it would
  show a spinner where a seeded `.failed` was meant to be. `PaneModel`,
  `TranscriptModel`, `PairingModel` and `UnpairModel` take the same treatment,
  parked in a phase; `PaneModel.start()` and `TranscriptModel.follow` return
  early, since a canvas that opened an `observe` stream would hold an exec
  channel on the Mac for as long as the preview lived.
- **The states worth previewing are the ones a working host never produces.**
  A failed refresh over rows that already arrived, a `done` agent, a host that
  refused the device key, a pane whose stream ended, a `bleat pair` that could
  not reach the local network. Those are most of the writing on these screens
  and none of them can be reached by pointing the app at a healthy Mac.
- **`PreviewSmokeTests` lays every one of them out**, in `BleatUITests`, for the
  reason `PaneGeometryTests` exists: a preview that compiles can still trap at
  render, and nothing mechanical would catch it. It also pins the promise —
  `ConnectionStore.endpoint` stays nil through every render, which is what says
  no screen dialled.
- Sample data lives in `Previews/`, `#if DEBUG`, in `BleatUI` rather than
  `BleatKit` so the domain layer ships none. It is hand-written rather than read
  from `Fixtures/` — those are not bundled with the app — but shaped like the
  captured output: `pane_id` already carrying its workspace, opaque workspace
  ids of both lengths, and all five agent states, since a sample list that was
  all `idle` would leave the screen this app is organised around with nothing to
  show.
- Five files have no preview and say why in place: `QRScannerView` and
  `TerminalHost`/`PaneTerminalView` need a camera or a live stream, and
  `PairingFlow`/`UnpairFlow`/`PeerSettingsFlow` present rather than draw —
  `RootView` exercises them, and each previews what it presents.

### The pairing UI (Phase 2)

`PeersView` is the app's first screen and there is no manual host list any more.
Adding a host by typing an address existed because there was no other way to
acquire one; pairing is the way now, and the promise is zero host setup beyond
Herdr. `HostRegistry` stays in `BleatKit` for the console tool.

- **Two ways in, and both are needed.** The camera, and a pasted
  `bleat://pair?d=…` link. `bleat pair` falls back to printing that link when
  the window is too small for a QR or is not a terminal at all, and a fallback
  nothing can consume is not a fallback.
- **A refused camera is not a dead end.** The scan section says what happened
  and offers Settings; the paste field is still there below it.
- **Claiming a scanned code is synchronous.** A camera reports the same QR many
  times a second and each frame spawns a `Task`, so checking "have we tried
  this?" and marking it must happen in one non-suspending step. An `await`
  between them is a place the second frame runs — and the enrollment key is
  single-use, so two redemptions would race to install and then delete it.
- **A code that is not addressed to Bleat is ignored, not failed.** A camera
  sees whatever is in front of it, and turning a Wi-Fi QR into "pairing failed"
  buries the real errors and takes the viewfinder away while the user is still
  aiming. `PairingPayload.looksLikeAPairingCode` checks only scheme and host —
  anything that *claims* to be a pairing code and will not decode is a damaged
  or newer code, and that is worth reporting.
- **"Try again" clears the codes already tried.** Otherwise the button does
  nothing at all: the failure being retried is nearly always transient, so the
  user points the camera at the *same* QR, and every frame of it is filtered.
  For the same reason the paste path must not mark a code as attempted — a
  failed paste would block the camera from ever reading that QR.
- **The sheet cannot be dismissed mid-swap**, by the button or by swiping. A
  pairing left running with nobody watching loses the two outcomes that matter
  most: a host key that does not match the code — the whole point of the
  out-of-band pin — and a peer the host accepted but the phone could not record.
- **The capture session is owned by one `nonisolated ... @unchecked Sendable`
  type and never handed out.** AVFoundation's classes are not `Sendable` and
  cannot be, so every `DispatchQueue.async` that captured one was a
  strict-concurrency diagnostic. `@preconcurrency import` silences the question
  rather than answering it; owning the objects and capturing only `self` answers
  it, and the invariant `@unchecked` stands for — everything touching the
  session happens on its queue — is the serialisation AVFoundation asks for
  anyway.
- **The scanner starts in `viewWillAppear`, not `viewDidLoad`.** SwiftUI
  recycles the rows a representable lives in; started once, a detached and
  re-attached preview comes back permanently black, and the view above has no
  state for "camera stopped" — it would show a viewfinder that can never fire.
- **An app's files go under Application Support, never `~/.bleat`.** On iOS
  `NSHomeDirectory()` is the app container's **read-only root** — only
  `Documents/`, `Library/` and `tmp/` inside it can be written — so a
  home-relative dot-directory cannot be created at all. Found on device, at the
  worst possible moment: the pairing had installed the key, proven it with a
  second handshake and deleted the enrollment key, and then failed to write the
  record with `NSCocoaErrorDomain 513`, leaving a key on the host the phone had
  no memory of. `PeerRegistry.applicationSupport()` is correct on both
  platforms with no branch; `standard()` stays `~/.bleat` for the console tool,
  as do `HostRegistry` and `KnownHostsStore`, and all three now say so.
  The directory is **excluded from backup**: the device key is `ThisDeviceOnly`
  and does not restore to a new phone, so a peer list that did would name hosts
  this device can no longer authenticate to.
- **`PeerStore.deviceKey()` throws instead of writing the shared `failure`.**
  Sharing one error property meant opening the key sheet cleared an
  unreadable-peer-file banner, after which the list said "No hosts yet" —
  confidently wrong, and an invitation to pair again into the same broken file.
- **The result screen shows the host key fingerprint**, because `bleat pair`
  prints the same string above the QR. Matching them by eye is the one check no
  software in this flow can do for the user.
- **`TransportError` describes itself** now, in `BleatKit`. The console tool's
  private rendering could not be reached from the app, so a failed connection
  arrived at the user as `connectionFailed("…")`, enum case and all. The tool
  keeps only the advice it alone can give — which `known_hosts` line to delete
  after an intentional rekey; the phone has no such file.
- **The camera purpose string is `INFOPLIST_KEY_NSCameraUsageDescription`** on
  the app target, and there is still no `INFOPLIST_KEY_` for `CFBundleURLTypes`
  — the generated set covers a fixed list of keys and URL types is not on it.
- **`bleat://` is registered, and a real `Info.plist` does *not* fight
  `GENERATE_INFOPLIST_FILE`** (verified 7 Sept 2026). This file used to say it
  did, which is why the scheme was deferred; the two compose. Setting
  `INFOPLIST_FILE = Support/Info.plist` alongside `GENERATE_INFOPLIST_FILE = YES`
  merges the generated keys *into* that file — checked in the built product,
  where `CFBundleURLTypes` and `NSCameraUsageDescription` and the scene manifest
  are all present. So `Support/Info.plist` carries the one key that cannot be a
  build setting and nothing else, and it sits outside `App/` so the target's
  synchronized group does not also copy it in as a resource.
  - The scheme string is duplicated between that file and
    `PairingPayload.urlScheme`, which is what `bleat pair` puts in the QR. No
    test can read the app target's plist from the package, so the coupling is
    stated in both places and here.
  - **A registered scheme that leads nowhere is worse than none**, so the app
    acts on it: `PairingRouter` is at the root next to the unpair flow, because
    a link can arrive while the user is several screens deep inside a host —
    where `PeersView` is not being evaluated and an `onOpenURL` on it would
    never fire. A link arriving while the sheet is already up is **refused, not
    queued**: a pairing in flight holds a single-use enrollment key it is part
    way through redeeming.
  - Verified end to end on the simulator: `simctl openurl bleat://pair?d=…`
    launched the app, raised the sheet, redeemed the code without a second tap,
    and reported the decode failure for the deliberately bogus payload. Note
    iOS shows an "Open in Bleat?" confirmation when the app is *not* frontmost
    and none when it is.

### iOS's local network permission (Phase 2, found on device 7 Sept 2026)

**The first pairing on a fresh install always failed, and the message blamed
the network.** iOS gates any connection to a `.local` name or a LAN address
behind a permission alert, raised the first time something tries — and it does
not hold that connection open while it waits for an answer. So every endpoint
in `PeerConnector`'s race failed while the alert was still on screen, and
pairing reported `none of N address(es) could be reached`. Granting permission
fixed nothing visible; the user had to know to tap "Try again".

- **The real fix is to ask before there is anything to lose.**
  `LocalNetworkAccess.prime()` runs from the pairing sheet's `onAppear`, so the
  alert arrives while the user is still lining up the camera. Not at launch:
  a cold first-launch prompt with no context is what teaches people to tap
  Don't Allow.
- **There is no API that reports this permission.** It is inferred from an
  `NWBrowser`, which the same permission gates: `.ready` means it is running,
  which it cannot do without access. A `.waiting` or `.failed` carrying DNS
  `-65555`/`-65570` (`NoAuth`/`PolicyDenied`) is the system positively
  refusing, which covers both "the alert is unanswered" and "the user said
  no". **Everything else stays `.unknown` on purpose** — blaming a permission
  for an unrelated failure sends the user to Settings to fix what is not
  broken.
- **Verified on device 7 Sept 2026: pairing on a fresh install is smooth.** The
  alert now arrives with the sheet and is answered before there is a code, so
  the failure that started this never happens. Two things that confirmation
  does *not* cover, because a successful prime means neither runs: the
  wait-and-retry path, and the `-65555`/`-65570` refusal codes, which are
  reasoned from Apple's constants rather than observed. Forcing a denial to
  test them needs a privacy reset, and the only clean route to one is an
  uninstall — which wipes the app's Application Support and strands the device
  key on the host with no `PairedPeer` naming the line to revoke. Not worth it
  for a fallback whose failure mode is "behaves exactly as it did before".
- **`NSBonjourServices` is not optional here.** Without the declaration the
  browser is refused before the permission is ever consulted, so the app would
  conclude "blocked" and never retry. It names `_ssh._tcp`, which is honestly
  what Bleat connects to, and the string must match
  `LocalNetworkAccess.serviceType`.
- **`NSBonjourServices` lives in `Support/Info.plist`** — it is an array, which
  the generated set cannot express — alongside `CFBundleURLTypes`, which is not
  in that set either. `NSLocalNetworkUsageDescription` is an
  `INFOPLIST_KEY_` build setting on the app target. The pair is split, which
  this file previously argued against; the plist's own comment carries the
  explanation so the two halves are still findable from each other. Look in the
  project, not the plist, for the purpose string.
- **Only "nothing answered" is retried.** A host key mismatch or a refused key
  means a machine *was* reached, so waiting on a permission would hide what the
  user has to see. Retrying is safe because the enrollment key is spent only by
  a **completed** swap — an attempt that never reached the host consumed
  nothing — and `bleat pair` holds the code for five minutes, which is why the
  wait is capped at 60s.

### Unpairing (Phase 2)

Unpairing is two things, and the app used to do only the easy one. Dropping the
local record is bookkeeping; removing this device's key from the host is the
part that decides whether a phone can still open a shell on someone's Mac.

- **The record is dropped only once the key is gone.** Forgetting first would
  discard the `PairedPeer` — its endpoints, its host key, its device marker —
  which is everything needed both to reach the host and to name the line to
  delete. There would be nothing to retry with and nothing to name.
- **Revocation matches on the key, not the marker.** The phone always holds its
  key; a marker can be absent from a record made before it was stored, or stale
  if the file was edited. `PairedPeer.deviceMarker` exists for *telling the
  user* which line to remove — `Enrollment` always minted it and
  `PairingClient` used to throw it away.
- **The file is read on both sides of the removal, and *absent before* is a
  failure too.** `removeKeyCommand` ends in `|| true`, so it exits 0 whether or
  not it deleted anything — hence the read after. The read *before* is the
  subtler one, and it is the same failure `Enrollment` was built around: the
  handshake that opened this connection proves sshd accepts the key, so if it
  is not in `~/.ssh/authorized_keys` then sshd is reading a different
  `AuthorizedKeysFile` and nothing done to this file can revoke anything.
  Without that check the app removed nothing, reported success, deleted the
  `PairedPeer`, and left the phone a full shell on that Mac with no record
  naming the line. **A first version shipped without it and a test asserted the
  permissive behaviour** — the same shape as the `Agent.target` test that
  passed while the property was wrong.
- **The connection is released afterwards.** It authenticated with a key that
  is no longer in `authorized_keys` — sshd does not re-check a live session, so
  it keeps working, which is exactly why it must not stay cached.
- **Swiping a row asks; it does not unpair.** Unpairing is not list management,
  and a swipe has nowhere to say what it does.
- **"Forget without removing the key" is offered, third, and named for what it
  leaves behind.** The alternative is worse: a Mac that has been rebuilt or
  sold would otherwise be un-removable, and a list that will not let go of a
  dead entry teaches people to ignore it. It is reachable only from a screen
  that has already shown the command that finishes the job.
- **`RevocationAdvice` lives in `BleatKit`**, for the reason `Agent.displayTitle`
  does: it names a command surface (`bleat keys revoke <marker>`) defined there.
  A phone printing a syntax the tool no longer accepts would be worse than
  printing nothing — the user runs it, sees it fail, and has no reason to think
  the key is still there. It validates the marker with the same
  `Marker(text:)` the tool applies, and falls back to `bleat keys list` plus a
  fingerprint when there is none.
- **`bleat unpair <name>` runs the same path from a terminal**, for the reason
  `bleat redeem` does: taking access away has one failure worth catching —
  reporting success over a key that still works — and only a real host shows
  it.

#### "Reached and refused" is not "could not reach"

`SSHTransport.dial` mapped every failure to `connectionFailed`, so a **revoked
device key looked like a network problem** — on every screen, not just this
one. The user is told to check their Wi-Fi while the truth is that the phone is
no longer paired.

Citadel throws `SSHClientError.allAuthenticationOptionsFailed` for exactly this,
and an address that is not listening throws `NIOConnectionError` (verified live,
5 Sept 2026, by probing a stopped sshd and a revoked key). `dial` now raises
`TransportError.authenticationFailed` — worded to name the possibilities rather
than assert revocation, since sshd also refuses every method under
`MaxAuthTries`/`MaxStartups` throttling, a changed `AllowUsers`, a locked
account or a `StrictModes` permissions drift, several of which are transient
and all of which reach every screen through this one string. `PeerConnector`
promotes it when nothing wins — after `hostKeyMismatch`, since identity outranks credential, and
before "none of N addresses could be reached", since a host that refused us was
reached.

The unpair screen says something different for it, because the advice inverts:
the likeliest reading is that the key has **already** been removed there, so
"the key is still on that Mac" would be false and `bleat keys revoke` would
fail with "no Bleat key with that marker" — reading like a second problem. The
other reading is that the key is in the file and sshd is ignoring it, which is
what a `StrictModes` permissions drift does. Only looking tells them apart, so
the screen names both and offers `bleat keys list`.

### Endpoint selection on the phone

Try last-known-good first with a short timeout, then race the remaining
endpoints and keep whichever completes the SSH handshake first. Persist the
winner per peer.

**Off the local link, skip what cannot work — but a private address is only
unreachable *unaided*.** `Endpoint.Reach` used to have one `lan` case covering
both mDNS names and private addresses, and both were dropped the moment the
phone left Wi-Fi. They are now separate cases because a tunnel treats them
differently:

| reach | needs |
|---|---|
| `linkScoped` (`.local`, loopback, link-local) | the attached link, and **nothing carries these off it** |
| `privateAddress` (RFC1918, ULA) | the attached link **or** a tunnel routing that subnet |
| `overlay` (Tailscale CGNAT/ULA/`.ts.net`) | the tunnel |
| `routable` | nothing |

Dropping `privateAddress` on cellular is what made Twingate look unsupported:
that overlay reaches a host by its ordinary `192.168.x` address, so the single
endpoint that would have connected was discarded before it was dialled.

**Loopback and link-local are `linkScoped`, not `privateAddress`, and that
split is load-bearing.** A VPN routes `192.168.1.20`; none routes `127.0.0.1`,
`::1` or `fe80::1`, which name this device or this wire. Filed with the private
addresses, each would become a candidate the moment any tunnel came up and cost
a full TCP timeout in the race for a destination that cannot exist —
`127.0.0.1:2222` is not hypothetical, it is what this file's own throwaway-sshd
procedure uses, and endpoints can be added by hand. They stay usable *on* the
link, so `bleat redeem` against a loopback sshd still works.

**Nothing here asks which subnets a split-tunnel client has claimed**, because
nothing can — and it would still not answer for a private DNS name. Being wrong
towards trying costs one slot in a concurrent race; being wrong towards refusing
costs the connection. So a tunnel being up is enough.

**"Does this need a tunnel" is link-dependent, and only the caller can answer
it.** `Endpoint.needsTunnel(from:)` is a function rather than a property for
that reason: a mesh address always needs one, while a private address needs one
only off the link — on Wi-Fi it is simply the network the phone is standing on,
and a failure there means the host is asleep. `PeerConnection` computes
`endpoints.allSatisfy { $0.needsTunnel(from: link) }` and hands the verdict to
`PeerConnector.failure` as `everyCandidateNeedsATunnel`.

- It stays a **parameter**, not a computation inside `PeerConnector`, for the
  reason the old `droppedUnroutable` flag existed: pairing hands the connector a
  deliberately narrowed list — one endpoint, the one that just carried the
  enrollment handshake — where every candidate is trivially a tunnel address. A
  self-derived condition would tell the user to check a VPN that had
  demonstrably just worked, at the moment the enrollment key may already be
  spent.
- **An earlier version passed `!link.onLocalLink` and lost a case.** A peer
  whose only endpoint is a Tailscale address, reached from Wi-Fi with the tunnel
  off, is exactly when the VPN advice is right — and exactly when that flag
  suppressed it, sending the user to check a Wi-Fi network that was working.

**The ruled-out message distinguishes the two kinds too.** Off the link with no
candidates left, "connect a VPN that routes it" is right for a peer with a
private address and wrong for one known only by its `.local` name — no tunnel
carries multicast, so that would send the user to set up something that could
never work. `bleat inspect`'s LAN-only note branches the same way.

**Unverified on device, and the blast radius is wider than a missed VPN.**
`NWInterface.InterfaceType.other` is documented as "virtual or otherwise
unknown", not "VPN", and iOS can have `utun` interfaces up for iCloud Private
Relay or an idle on-demand profile. If the monitor reports satisfied without a
tunnel that routes anything useful, `tunnelActive` is stuck true and the
cellular filter stops discarding private addresses at all: a LAN-only peer on
cellular goes from an instant "only reachable on its local network" to a full
TCP timeout per RFC1918 candidate, since cellular black-holes those rather than
refusing them. Shipped that way deliberately — the alternative is the bug being
fixed, and the failure is *slow* rather than *wrong*, since `overlayUnreachable`
still names the right remedy (reaching a LAN-only host from cellular does take a
VPN, whether or not one is up). **Wants measuring on a real phone, on cellular,
with and without the tunnel.**

Whichever endpoint wins, the host key is still checked against the peer's pin.
The endpoint is a hint; the key is the identity.

## `bleat` console tool (Phase 1 acceptance)

```
bleat hosts add dev ravil@10.0.0.5 --key ~/.bleat/id_ed25519 \
      --herdr /opt/homebrew/bin/herdr --session work
bleat hosts list / hosts remove dev
bleat sessions   [host]                   # named sessions
bleat workspaces [host] [--session NAME]  # by attention state
bleat agents     [host] [--session NAME]  # agents, blocked first
bleat attach     [host] w1:p1 [--takeover] [--cols N] [--rows M]
bleat schema     [host] > BleatKit/Fixtures/schema.json
bleat keys list                           # what this machine still lets in
bleat keys revoke <marker>                # take a paired phone's access back
```

Omitting `[host]` uses `LocalProcessTransport`, which spawns `herdr` directly.
That is what makes the tool usable *on* the Herdr machine without a loopback SSH
hop, and it is how the stack is exercised in development. Naming a saved host
switches to `SSHTransport` behind the same `HerdrTransport` protocol — no caller
above the transport changed when SSH landed.

`attach` writing the ANSI bytes straight to a macOS terminal is the Phase 1
renderer. If it looks right there, SwiftTerm will render it in Phase 2. Ctrl-]
sends `terminal.release` and exits 0; SIGWINCH is forwarded as `terminal.resize`.

### `bleat pair` (Phase 2)

```
bleat pair [--endpoint HOST[:PORT]]...   # add endpoints detection cannot find
```

Checks that `herdr` is installed and resolvable, enumerates endpoints, mints the
single-use enrollment key, renders the QR in the terminal, and waits for the
phone to swap in its own key. See **Pairing and peer identity** for the rules
that govern it — they are settled, not per-PR decisions.

The QR must be rendered so it does not persist: draw it in the alternate screen
buffer and restore on exit, so it never enters scrollback. This matters even
with the enrollment key being single-use.

### `bleat redeem` and `bleat peers` (Phase 2)

```
bleat redeem <bleat://pair?d=...>   # the phone's side, run from a terminal
bleat unpair <name>                  # revoke this device's key, then forget
bleat peers                          # what pairing produced
```

The same `PairingClient` the app will call. It exists so the swap can be run
against a real `bleat pair` before there is an app, and it is the fastest way to
reproduce a pairing problem. Its device key lives in `~/.bleat/device_key` rather
than the Keychain — `KeychainKeyStore` is `ThisDeviceOnly` and prompts, which is
right on a phone and an obstacle in a terminal.

### `bleat keys` (Phase 2)

```
bleat keys list
bleat keys revoke <marker>...
```

The other half of pairing. A phone that unpairs drops its own record; it cannot
reach the host, and a phone that was lost or wiped cannot do anything at all.
So the host's `authorized_keys` is the only place that knows what may still log
in, and until this existed there was nothing that showed it or removed it.

- **Local only, and not by omission.** Every other command takes an optional
  `[host]` and reaches it over SSH. This one edits the file that decides who
  may reach the machine, and doing that down a channel the file itself
  authorises is a footgun: revoke the wrong line and the command that would fix
  it is the one that no longer connects.
- **A marker typed by a user is validated, never sanitised.**
  `Marker(kind:id:)` sanitises because it *mints* a marker; `Marker(text:)`
  refuses anything that is not already `bleat-(enroll|device)-[A-Za-z0-9._-]+`.
  Sanitising here would turn `bleat-device-ab/12` into `bleat-device-ab12` — a
  different, possibly existing key — and this string names the line `grep -v`
  deletes. Refusing a typo beats repairing it into someone else's key.
- **A revocation is checked before and after.** `removeCommand` exits 0 when it
  matches nothing, so the exit status cannot say whether anything happened.
  Revoking an absent marker is refused outright, and the file is read again
  afterwards — a confident "Revoked" over an unchanged file is the exact
  class of lie the rest of this design is built against.
- **An expired enrollment key is reported as harmless**, because it is: sshd
  already refuses it and the next `bleat pair` sweeps it. A listing that showed
  it the same way as a live device key would send the user chasing a key that
  cannot be used, and teach them to ignore the list.
- **A line whose marker parses but whose key does not is still listed.** A key
  that authenticates and does not appear in the list is the precise failure the
  command exists to prevent; only the fingerprint is lost, and the row says so.
- **The listing is one block per key, not one row.** Marker, fingerprint and
  note total about 130 columns on one line. The fingerprint gets its own line
  because comparing it against what the phone shows is the one check no
  software in this flow can do for the user — and it is byte-identical to
  `ssh-keygen -lf`, verified.
- Reads take the `mkdir` lock, for the reason `containsKeyCommand` does: every
  write-back truncates before it writes, and an unlocked read landing in that
  instant reports an empty file — which here reads as "no keys on this
  machine". **The post-revocation proof reads through the locked listing too**,
  not through `containsCommand`, which is deliberately unlocked for the host's
  ten-times-a-second poll and would answer "gone" from that same empty read.
- **Both checks happen before anything is removed.** Validating only the
  *format* up front is not enough: `revoke <good> <typo>` then removed the
  first key before finding the second was not there. Markers are also
  de-duplicated, or the same one is revoked once and reported twice. That pass
  rules out a *missing* marker; a removal that fails partway can still leave an
  earlier one revoked, so the message says which rather than claiming nothing
  happened.
- **A concrete `bleat keys revoke <marker>` is only suggested when exactly one
  device is paired.** With two, naming either is naming an arbitrary one, and
  the user pastes it and revokes the phone they meant to keep. Which key is
  which phone is a question only the fingerprints answer.

### `$` is the wrong anchor for an `authorized_keys` line (found in review)

A `$`-anchored pattern does **not** match a line ending in a space — and sshd
still accepts the key on that line. Every marker pattern shared the anchor, so
such a key was invisible to `listCommand`, `containsCommand` **and**
`removeCommand` at once: it could be neither seen nor revoked, which is the
exact failure `bleat keys` exists to prevent. The same shape reaches a
`bleat-enroll-` line, where it survives `bleat pair`'s own sweep and cleanup.

`AuthorizedKeys.lineEnd` (`[[:space:]]*$`) is now the single definition, used
by every one of them so the listing and the deletion cannot disagree. A `\r`
from a Windows-edited file is covered by the same class. `Entry.parse` splits
on whitespace, which tolerates it already — the two ends have to agree or the
tool lists a key it cannot then remove.

Related, from the same review:

- **sshd accepts `YYYYMMDD` and `YYYYMMDDHHMM` as well as the full stamp**,
  with or without `Z` (without one it is *local* time, which is why nothing
  here writes that form). Reading only the written form reported a deadline
  sshd is enforcing as no deadline at all. `Entry` keeps the raw `expiryStamp`
  beside the parsed `expiresAt`, so "no deadline" and "a deadline this build
  cannot read" stay different answers.
- **Options can contain a quoted space** (`command="echo hi",restrict`), which
  splits into two fields and pushes the key past a fixed two-field window.
  `Entry` scans for the field pair that parses instead.
- `locked()` creates `~/.ssh` with `mkdir -m 700`, since the lock wraps reads
  now and a listing left a new directory behind at the umask default.

**Piped output is block-buffered, and both commands print before a long wait.**
`bleat pair`'s fallback link and `bleat redeem`'s progress line are flushed
explicitly. Without that, `bleat pair > file` shows the link only once the tool
exits — by which point the key it carries has been removed, which makes the
entire non-TTY path useless exactly where it is needed.

## The pane view (Phase 2, verified 5 Sept 2026)

- **Read-only, by `terminal session observe`.** It cannot disturb whoever holds
  input on the pane, which is the whole of the Phase 2 gate and the right
  default besides: Herdr allows one input owner, and taking it from a running
  agent because someone glanced at their phone would be indefensible. `control`
  and `--takeover` are Phase 3, behind a deliberate gesture.
- **The host is asked to render at the phone's size, and this is a known
  problem — see below.** `observe --cols --rows` is honoured in the sense that
  the frame reports the size asked for. The size is only knowable after a layout
  pass, which is why the terminal lives in a view *controller*; rotation reopens
  the stream, and the first frame of a new one is `full: true`, so the screen
  simply redraws.

### `--cols` crops. It does not reflow — so the app renders the whole pane

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

### A pane's size belongs to the session. No stream client can change it (verified 6 Sept 2026)

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

### The phone session, and what a client may change (6 Sept 2026)

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
  either and then blame the wrong thing. The fallback crops, so the badge says
  so.
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
    from one is that same write on behalf of nothing.
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
    the only way to see it is to ask the program.
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
### Scrolling a pane (Phase 3, the first piece of input)

The first thing Bleat sends to a host, and it is deliberately two keys.

- **`PaneModel.control` is `.observing` or `.controlling`**, and only
  `takeControl()` crosses. `run()` opens `observe` for the first and
  `attach(takeover: true)` for the second; nothing else differs.
- **The confirmation is not politeness, it is the whole safety story.** Taking
  the pane takes it *from someone*, and per the measurement above there is no
  way to send a key without doing so. `PaneView` says that in a
  `confirmationDialog` before it happens rather than leaving it to be
  discovered by the person at the Mac.
- **Release is on three paths**: the toolbar button, `close()` when the screen
  goes away, and `releaseControl()`. `close()` sends `terminal.release`
  **before cancelling the reader**, or there is no live stream left to send it
  on and herdr holds the pane for a phone that has gone in a pocket.
- **Keys, not `terminal.scroll`.** Herdr's scroll record moves a pane's *host*
  scrollback, which an agent does not have. The earlier output is inside the
  program, so the program's own keys are what move it. `TerminalKey` carries
  the xterm sequences and `TerminalCommand.bytes` puts them on the wire —
  **`text` cannot**, because a raw ESC inside a JSON string is not legal JSON
  and the host answers `input ignored`.
- **Which keys work is the program's business.** `less` and every full-screen
  pager answer Page Up; whether Claude Code does is **unverified** — a probe
  that launched it in a scratch pane stalled on a workspace-trust prompt before
  it could be asked. If it wants something else, `TerminalKey` is where that
  goes and it is a one-line change.
- **A drag pages it, and `TerminalView.isScrollEnabled` is off to allow that.**
  It was on for a while on the theory that a program which did scroll would
  then work; nothing can, so all it did was consume every vertical swipe on
  behalf of a buffer that never fills. `PaneScrollGesture` gets the drag
  instead and quantises it into page keys — half a terminal of travel per page,
  pulling **down** for earlier output, the direction a scroll view moves
  content with the finger.
  - **It will always feel like paging, not scrolling, and that is structural.**
    There is no buffer under the finger to move: the earlier output is inside
    the program, which redraws a whole screen per key. A drag can only decide
    *when* to ask for the next one.
  - The two buttons stay. A drag is not reachable by VoiceOver or Switch
    Control, and a gesture nothing advertises is not an affordance.
  - **The gesture is attached always and gated with `including:`.** Branching
    — `if controlling { content.gesture(drag) } else { content }` — builds a
    `_ConditionalContent`, and switching branch changes the structural identity
    of what it wraps. What it wraps is `TerminalHost`, a representable: every
    take and every release would tear the controller down, lose the rendered
    buffer and blank the pane until the next full frame.
  - **The take/release button is shown whenever the pane is held**, not only in
    terminal mode. Gated on the mode alone, switching to chat hid both the one
    thing saying the pane was seized and the only way to give it back.
- `PaneControlTests` guards every path into `.controlling`, including the one
  that matters most: a pane with no viewport cannot be seized, because nothing
  is on screen yet to release it.

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
- **A badge in the corner names the grid**, and says "cropped" when the fallback
  is in use. The pane is deliberately larger than the screen now, and a scroll
  indicator that appears only once you already know to drag is not an
  affordance on its own; the indicators are also flashed once when there is
  something off-screen to find.
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

### Answering an agent's dialog (Phase 3, built 10 Sept 2026)

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
  *ordinary* case — 46 rows without it, 43 with — and taking or releasing
  control reopens the stream and `stty`s the pane. Correct, since the terminal
  really did get shorter, but each gesture costs two `start()`s: its own, and
  the one the layout pass triggers when the bar appears. Reserving the bar's
  height in both modes is how to collapse that if it ever matters.
- **No text entry, deliberately.** Typing is `agent prompt`'s job — it handles
  bracketed paste and ordered submission — and what the phone lacked was only the
  *navigation* of a dialog already on screen.
- **Its visibility is gated on `control` and must never be gated on `phase`.**
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
  - `PaneScrollControl` carries the same `phase` test *safely*, which is what
    makes this easy to copy wrongly: it is an `.overlay`, and an overlay draws
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

### Typing into a pane (Phase 3, built 10 Sept 2026)

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
keeps its full frozen height with its bottom pinned above the keyboard and its
top clipped by the view (`clipsToBounds`). The grid never changes, nothing is
written to the host, and what stays on screen is the bottom of the pane — the
prompt and the input line, which is what is being typed into.

- **Frozen before the keyboard animates in, thawed on `keyboardDidHide`.**
  Not `willHide`: unfreezing on the way down reports a grid per frame of the
  dismissal animation. On the way back up the restored grid equals the one it
  left, so `report`'s own de-duplication swallows it and nothing reopens.
- **`PaneGeometryTests` pins both halves**, and both were checked against the
  bug rather than only the fix — with the freeze removed they fail at 2 and 3
  reports respectively.
- **Raised by an explicit toolbar button, never by tapping the pane.** A tap on
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
- **The keyboard comes down with the pane.** `releaseControl()` and `close()`
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
- **Ctrl and Tab are currently unreachable while typing**, and that is a known
  gap rather than a decision. `dropBuiltInAccessory()` removes SwiftTerm's
  `TerminalAccessory`, which was the only source of both, and the iOS software
  keyboard has neither key. So there is no way to send Ctrl-C to interrupt an
  agent from the phone. Both are named in the Phase 3 gate line;
  `terminalAccessory?.controlModifier` falls back to `controlModifier`, so a
  Ctrl toggle in `PaneKeyBar` is a small addition when it is wanted.

**`swift build` does not compile any of this.** Every file under `Pane/` is
`#if canImport(UIKit)`, and `swift build` targets macOS — so the whole screen is
compiled out and a green `swift build` says nothing about it. This was found the
obvious way: a renamed type left a dangling reference that built clean twice.
Use `xcodebuild -scheme BleatKit-Package -destination 'generic/platform=iOS'`,
or the simulator test run, which is what actually compiles it.

### An agent over SSH cannot read the login keychain — out of scope (settled 12 Sept 2026)

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

### A pane that stopped repainting, and what was ruled out (10 Sept 2026)

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

## Concurrency settings (verified 4 Sept 2026)

The package and the Xcode targets must state the same thing, or a file changes
behaviour when it moves across the seam.

| where | settings |
|---|---|
| Xcode targets | `SWIFT_VERSION = 6.0`, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, `SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY = YES` |
| package | `swiftLanguageModes: [.v6]`, `.enableUpcomingFeature("MemberImportVisibility")` on every target, `.defaultIsolation(MainActor.self)` on `BleatUI` only |

- **`RemoteList` writes an empty `deinit`, and deleting it breaks the archive.**
  `swift-frontend` 6.3.3 segfaults optimising `BleatUI` without it — `pass
  SILFunctionTransform "EarlyPerfInliner" on SILFunction
  "@$s7BleatUI10RemoteListCfD"`, which is that class's *synthesized*
  deallocating destructor. Writing the destructor out, even empty, avoids
  whatever shape the inliner chokes on; the members are released exactly as
  before, so nothing changes at runtime.
  - **It is invisible to the ordinary loop.** `swift build`, `swift test` and
    every debug run on a device pass with it removed; only `-O` fails, so the
    first thing it breaks is the archive — the last step before TestFlight and
    the slowest place to find out. `ci_scripts/ci_post_clone.sh` now runs
    `swift build -c release --target BleatUI` for exactly this, four seconds.
  - Not caused by the previews work: verified on `main` at `5bdf5ae`, same pass
    and same symbol. `@Observable` is not the trigger either — removing it still
    crashes. `RemoteList` is the module's only *generic* class, which is the
    obvious suspect, but a standalone package reproducing its shape (generic
    `@Observable final class`, a generic enum payload, an optional class
    reference, a `@Sendable` async closure, the same `load` body) compiles
    clean, so the trigger needs the whole module and is not characterised
    further.

- **`SWIFT_APPROACHABLE_CONCURRENCY` is off on both sides, deliberately.** Its
  package half, `NonisolatedNonsendingByDefault`, reproducibly segfaults the
  test bundle on Swift 6.3.3: `swift test` dies with signal 11, while
  `swift test --no-parallel` passes all 70 and every suite passes alone — so it
  only bites under swift-testing's parallel execution. Enabling it for the app
  alone would be worse than leaving it off for both, because then the seam
  really would differ. Revisit on a newer toolchain.
- **`.defaultIsolation(MainActor.self)` is on `BleatUI` only.** `BleatKit` is a
  transport and domain library whose work belongs off the main actor, and the
  console tool links it with no main actor in sight. Isolation there is
  expressed per type.
- `SWIFT_VERSION` is the setting that silently lags: the isolation settings can
  be on while strict checking is not actually running. Check it before believing
  the project is on Swift 6.

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
- Keep this file current: phase, verified facts, decisions. It is the onboarding
  doc for every session.

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
