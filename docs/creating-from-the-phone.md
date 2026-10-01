# Creating panes and sessions from the phone (herdr 0.9.0, 8 Sept 2026; `session attach` re-measured on 0.9.3, 30 Sept 2026)

> Moved verbatim from `CLAUDE.md` on 1 Oct 2026. Where the text says "this file", "above" or "below", it means the old single file; a **bold** section name can be found with `grep -r docs/`.

**Both the Mac and the Linux host run 0.9.3, and this section has now been
re-measured against it** — `session attach` because it broke outright (below),
then `workspace create`, `tab create` and `agent start` on 30 Sept 2026, in an
isolated session on the Linux host.

**Everything held except two things, and neither is a behaviour change.**

| re-measured on 0.9.3 | verdict |
|---|---|
| `workspace create` reply shape, and `tab create`'s | **identical key set** to `Fixtures/workspace-create.json` and `tab-create.json` |
| herdr accepting a `--cwd` that does not exist, silently | **still true** — exit 0, `workspace_created`, pane in `$HOME` |
| canonical cwd (symlink, `//`, `..` all collapsed) | still true, and still equal to what `cd … && pwd -P` answers |
| label defaults: basename, and `~` for the home directory | both still true |
| relative `--cwd` resolved against the *server's* cwd | still true |
| duplicate labels allowed | still true |
| a new tab's pane inherits the **workspace's** cwd | still true |
| the five instant `agent start` refusals | all five, all at **3ms** |
| `invalid_agent_timeout` bounds | still `> 3000` and `<= 300000`, exclusive floor measured (3000 refused, 300000 accepted) |
| `agent_not_ready` at a trust dialog | still exactly this, at **3.7s**, `launch_pending: true`, `❯ No, exit` still the default |
| a missing binary → `timeout`, pane holds the shell's complaint | still true, and `agent list` is left **empty** for that pane |
| `agent send-keys` without a takeover | still works; `invalid_key` still refused before any byte |
| `agent-list` key set | exactly the union of the four committed `agent-list*.json` fixtures — nothing added, nothing gone |

The two that moved:

- **There are twenty-four agent kinds now, not twenty-three.** `letta` joined,
  between `qwen` and `maki` in herdr's own order. Nothing broke — which is the
  whole point of `AgentKind` being a string with a known list rather than a
  closed enum — and the only cost of being behind was a picker that did not
  offer it. `AgentKind.known` and its test carry the count so that falling
  behind is something a test says rather than something a user finds missing.
- **`agent start --help` now states the timeout bounds** (`default: 30000;
  max: 300000`), which this file recorded as undocumented. The floor is still
  only in the refusal.

Two smaller corrections to what was written here before:

- **A `timeout` costs whatever `--timeout` asked for, not a flat 30s.**
  Measured at 4017ms for `--timeout 4000`. The app sends herdr's own default of
  30000, so "the full 30 seconds" was true of the app rather than of the
  command.
- **`agent_name_taken` now names the holder** —
  `candidates: terminal_id=… pane_id=… workspace_id=…` — where it used to be
  the bare sentence. Nothing reads past the code, so this costs nothing.

**One probe of my own was wrong twice before it was right, and it is worth
saying why**: `pane run` takes its pane *positionally* (`pane run <PANE_ID>
<COMMAND>…`, no `--`), and two attempts to build a busy pane silently ran
nothing, so `agent start` went into an *idle* pane and answered
`agent_not_ready` rather than `agent_pane_busy`. Read as a finding that would
have been "0.9.3 no longer refuses a busy pane", which is false: with a pane
genuinely running `sleep`, the refusal is `agent_pane_busy` in **3ms**, exactly
as before. `pane read` is the same shape — the pane is positional, which is what
`HerdrClient.paneText` already sends.

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

## Starting a session: `herdr session attach`, under a sized pty (rebuilt 30 Sept 2026)

**There is still no `session create`** on 0.9.3 — `herdr session` offers only
`list`, `attach`, `stop`, `delete` — so `attach` is the only thing that brings a
session into being.

**It needs a terminal now, and until 30 Sept 2026 the app did not give it one.**
Reported from a device as "starting a session on adam gets rejected". It was
neither adam's fault nor Linux's: **it was broken on every host**, and had been
since herdr updated. Both machines run **0.9.3**; every measurement this section
used to rest on was taken against **0.9.0**.

| herdr | `attach` with no pty |
|---|---|
| 0.9.0 | **starts the server**, then the TUI fails to draw — exit 1, `Inappropriate ioctl for device`, server reparented to pid 1 |
| 0.9.3 | checks the terminal **first** and creates nothing |

That ordering was the entire premise of the old command, which therefore
swallowed the status and read `session list` back. Three refusals measured,
30 Sept 2026 — over a real SSH exec channel to the Linux host, and locally with
a stripped environment on the Mac:

| host | given | herdr says |
|---|---|---|
| Linux | no pty | `cannot attach without a usable terminal: Not a tty (os error 25); run inside a terminal` |
| macOS | no pty | `cannot attach without a usable terminal: Inappropriate ioctl for device (os error 25); run inside a terminal` |
| Linux | a pty with **no size** (`script` alone) | `cannot attach without a usable terminal: terminal reported a zero-sized grid; run inside a terminal` |

**The third row is the one that would have cost another round trip**: a pty is
not enough, it has to have been sized. So the launch runs under `script` with an
explicit `stty`:

```sh
exec 2>/dev/null
bleat_herdr='<herdrPath>'
bleat_session='<name>'
export bleat_herdr bleat_session
bleat_attach='stty rows 40 cols 120; exec env -u HERDR_SOCKET_PATH -u HERDR_SESSION "$bleat_herdr" session attach "$bleat_session"'
bleat_ready() {
env -u HERDR_SOCKET_PATH HERDR_SESSION="$bleat_session" "$bleat_herdr" pane list >/dev/null 2>&1 &
bleat_probe=$!
( sleep 3; kill -TERM $bleat_probe ) >/dev/null 2>&1 &
bleat_probe_guard=$!
wait $bleat_probe
bleat_answered=$?
kill $bleat_probe_guard >/dev/null 2>&1
return $bleat_answered
}
bleat_log=$(mktemp "${TMPDIR:-/tmp}/bleat-session.XXXXXX") || bleat_log=/dev/null
if script -q -c true /dev/null >/dev/null 2>&1; then
script -q -c "$bleat_attach" /dev/null </dev/null >"$bleat_log" 2>&1 &
else
script -q /dev/null /bin/sh -c "$bleat_attach" </dev/null >"$bleat_log" 2>&1 &
fi
bleat_launch=$!
bleat_deadline=$(($(date +%s) + 15))
bleat_died=
until bleat_ready; do
kill -0 "$bleat_launch" 2>/dev/null || { bleat_died=1; break; }
[ "$(date +%s)" -ge "$bleat_deadline" ] && break
sleep 0.5
done
kill -TERM "$bleat_launch" >/dev/null 2>&1
[ -n "$bleat_died" ] && cat "$bleat_log"
[ "$bleat_log" = /dev/null ] || rm -f "$bleat_log"
true
```

That whole script is pinned by an exact-string test and was run **verbatim** on
both hosts — the Linux one over a real exec channel, the Mac locally with
`env -i`. Measured either way: **exit 0 in about a second**, no output, and
`session list` reporting it running. `stty size` inside the pty reports
**40 120** on both, so the size is deterministic.

**The pane's rect settles to 120×40, but a read taken immediately can catch
94×39, and that is the attached TUI's layout rather than a bug.** While the
client is up the session's geometry is its window *minus herdr's chrome* — 120
less a 26-column sidebar, 40 less a tab-bar row — and the session only goes back
to the headless size once the client is gone. Caught once in three attempts on
the Mac: `94 x 39` immediately, `120 x 40` three seconds later, reproducible by
reading in a loop. It is harmless here because nothing reads geometry until a
pane is opened, screens later — but it is why `pane layout` is not a thing to
assert on right after a start, and the first version of this section claimed a
flat 120×40 on the strength of a single well-timed read.

- **A real SSH pty was the alternative and was not taken.** Citadel has
  `withPTY`, and asking sshd for a sized pty is the conceptually honest answer —
  but it changes `HerdrTransport`, which this file says to ask before doing, and
  `script` keeps the whole fix inside the exec channel the transport already
  opens. The cost is the dependency: **a host without `script` cannot start a
  session**, and the failure is the generic one.
- **Both `script` flavours, chosen by a probe rather than by falling through.**
  BSD has no `-c`; util-linux refuses the BSD form outright (`unexpected number
  of arguments`). So neither spelling works on both, and an `||` chain could not
  tell "this flavour does not exist" from "the launch failed".
  `script -q -c true /dev/null` is the probe — exit 0 on util-linux, non-zero on
  BSD. Measured on both hosts.
- **The client never exits on its own now, so it is always killed.** Given a
  working terminal `attach` *is* the TUI and stays up for as long as the channel
  does. **The server survives the kill**: verified on both hosts, `session list`
  reporting `running: true` after a `kill -TERM` of the `script` holding the
  client.
- **The loop ends on two conditions, and having only one of them was a bug.**
  Waiting purely on the deadline meant *every refusal cost the whole budget* —
  measured at **10.16s** against a herdr that refused instantly, with the
  new-session cover locked for all of it because `NewSessionField`'s scrim is
  deliberately inert while a launch is in flight. `kill -0 "$bleat_launch"` ends
  it the moment the client is gone; the same refusal now returns in **0s**.
- **The bound is wall clock, not a count of tries, and each probe has its own
  watchdog.** A first version polled twenty times and called that the limit —
  but `bleat_ready` runs a `herdr` command with no timeout, so a server whose
  socket exists without answering blocks one iteration indefinitely and holds
  the exec channel open forever. That is the wedged-daemon case
  `EndpointDiscovery.tailscaleStatusCommand` already guards, and the
  `( sleep N; kill )` this replaced *was* a hard wall-clock bound: dropping it
  put back the failure it existed for. Both halves are needed — a deadline, and
  a watchdog on each probe so the deadline can be met.
- **The geometry is ours to choose now, and 120×40 is not arbitrary.** With a
  pty, the pty's size *is* the session's — the hazard the 0.9.0-era design
  feared, and it is unavoidable rather than avoidable now. Those are herdr's own
  headless defaults, so a session started from the phone comes up at exactly the
  grid it used to. The phone's own screen would be the wrong answer for the
  reason this file argues elsewhere: the grid belongs to the session and every
  pane shares it, so a phone-shaped session is a host `config.toml` decision.
- **Readiness is the session's own socket answering, not a grep of `session
  list`.** A socket-API command against the session exits 0 only when its server
  is up, which is the question — and it does not depend on two JSON keys
  staying adjacent in herdr's output.
- **`HERDR_SOCKET_PATH` must be cleared in the probe as well as the launch, and
  this is not theoretical.** It caught the probe that measured this change:
  `HERDR_SESSION=<probe> herdr pane list` answered about **`work`**, because the
  socket path was still set in the environment and wins over the name. That is
  the hazard `SSHTransport.command` documents, met in the flesh.
- **Nothing is interpolated into a nested quoting level.** The two values go
  into exported shell variables and the command `script` runs is a *literal*
  single-quoted string that expands them itself. Built the obvious way —
  `script -c "… '<herdrPath>' …"` — a double quote anywhere in the path escapes
  the inner string, and that path is whatever `command -v herdr` answered on
  somebody else's machine.
- **The output is emitted only when the client actually died**, which is what
  makes widening `diagnosis` safe — see below. The first version emitted it
  whenever the readiness probe had not answered, and that is **not the same
  claim**: a herdr server a protocol version behind the client fails `pane list`
  while the session is perfectly up (this file records that happening live on
  the `phone` session), and so does running out of deadline on a slow host.
  Either would `cat` the whole TUI escape stream into `diagnosis`, which then
  scans several KB of escape-stripped terminal paint for a "cause" and shows the
  user whatever fragment matched.
- **`mktemp` holds that output, and its failure must not swallow the launch.**
  An `XXXXXX` template is what retires the old log's `${TMPDIR:-$HOME}` symlink
  hazard — unpredictable name, `O_EXCL`, mode 600, removed at the end, verified
  no stray files on either host. But `mktemp` is not POSIX-mandated, and the
  first version's `|| exit 0` returned *before* `session attach` ran: on a host
  without it, nothing started, nothing was said, and `exec 2>/dev/null` hid the
  only clue. It falls back to `/dev/null` instead — losing the cause of a
  failure is survivable, losing the launch is not. `/dev/null` is then kept away
  from `rm -f`, for the obvious reason.
- **Every outcome still exits 0**, hence the trailing `true`: the last thing to
  run is `bleat_ready || cat`, whose status is the readiness probe's.
- **The `session list` read-back stays, and it is not redundant with the
  script's own poll.** That poll is *inside* the thing being checked and runs on
  the host with nothing above it to disagree; a launch that fell through its
  budget, or a host without `script`, both leave a command that exited 0.
  `SessionStarter` polls, as before.

**`SessionLaunch.diagnosis` reads two prefixes now, and the second one *is* the
reported bug.** herdr writes refusals both ways — `error: nested herdr is
disabled by default` and `herdr: cannot attach without a usable terminal: …` —
and this used to accept only the first. So the failure a user actually met
arrived as the generic "the host did not report a session", throwing away a
sentence that named the cause *and* the remedy. That is why it read as a bare
rejection.

- **Accepting `herdr: ` is safe only because of the change above.** The old rule
  — "only `error: `, because a launch that *worked* printed `herdr: Inappropriate
  ioctl for device`" — was right when the output was the launch's, merged, on
  every run. It is not any more: there is no success path through `diagnosis`.
  Widening the prefix *without* emitting only on failure would re-introduce
  exactly the bug the old rule defended against, and the test that used to pin
  it now pins the reversal and says so.
- **The pty echoes its own EOF over the top of herdr's first line, and that
  defeated the prefix test — the fix shipped with the bug inside it.** Found in
  review. `script` writes the EOF character to the master (stdin is
  `</dev/null`) and the line discipline echoes it as the two **printable**
  characters `^D` plus two backspaces to rub them out, so a refusal arrives as
  `5E 44 08 08 68 65 72 64 72 3A 20 …` — captured bytes, from a real run on the
  Mac. `trimmingCharacters(in: .whitespacesAndNewlines)` touches neither piece,
  so `hasPrefix("herdr: ")` was false and the user got the generic message that
  widening the prefix was meant to replace.
  - **Stripping control characters is the wrong fix**, which is the trap: `^D`
    is `^` and `D`, two ordinary printable bytes, so removing the `\b`s leaves
    them and the prefix still does not match. `applyBackspaces` does what the
    backspaces ask, which is also the general answer — anything else a pty
    echoes over its own output arrives the same way.
  - **Searching *within* the line was the alternative and is not taken.** It is
    what `HerdrLookup.path(inOutput:)` does for profile banners, but this scans
    whatever the TUI painted before it died, and a substring match over that is
    far likelier to find a "cause" that is a fragment of somebody's prompt.
- **Anything else is still nil rather than guessed.** A shell's own complaint
  about an unresolvable `herdrPath` reads as `env: '/no/such/herdr': No such file
  or directory` — measured on the Linux host — which is true but is not herdr
  explaining itself, so the generic message is the honest answer.
- **It still strips ANSI before matching**, for the reason it always did: herdr
  styles some of its own errors even to a non-tty.

Everything below was measured against 0.9.0 and re-confirmed on 0.9.3 unless
noted:

- **A refusal is reported synchronously, in herdr's own words**, off the
  command's merged stderr rather than out of a file fetched afterwards.
- **Both `HERDR_SESSION` and `HERDR_SOCKET_PATH` are unset.** The name is a
  positional argument, so an inherited `HERDR_SESSION` would let a login profile
  decide which session starts.
- **`attach` being idempotent makes the look-before-launch rule matter *more*.**
  The old `herdr server` at least failed loudly against an already-running
  session. `attach` succeeds silently — measured again on 0.9.3: a second launch
  against a running session exits 0 in a second with no output and no second
  server — so `SessionStarter`'s read of `session list` *before* the write is
  the only thing standing between that and the phone claiming somebody's live
  session. See **Stopping and deleting** for what that claim buys.
- **A new session is *not* empty.** `attach` brings one up holding a single
  workspace — labelled `~`, one tab, one pane, in the SSH user's home
  directory. Confirmed on the Linux host: `w1:p1`, cwd `/home/pi`.
- **A *stopped* session of that name is resumed, not recreated**, with its
  workspaces.
- **The command this all replaced never worked over SSH at all**, and that was
  found while reviewing its replacement in Sept. `nohup` on macOS refuses an
  exec channel — `nohup: can't detach from console: Inappropriate ioctl for
  device` — and bails *before* exec'ing herdr. It was "verified" over a local
  non-pty shell. **A local non-pty shell is not an exec channel**; that lesson
  is why the Linux half of this change was measured over one.

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

## Stopping and deleting a session (built, 8 Sept 2026)

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

**Stop is offered for every running session, and it used to be gated.** Changed
29 Sept 2026, on the report that starting and stopping sessions is the handy
thing about having the phone: the gate was `startedSessions`, and it withheld
Stop from every session started at the Mac and from every session a reinstall
had forgotten — which is nearly all of them. A phone that can start a session
and cannot stop the one it is looking at is the wrong shape, and the `work`
session is exactly the one a person wants to put down from the sofa.

**So there are two guards now, not three — and the claim did not disappear, it
moved from the gate to the confirmation's wording.** That makes "the dialog is
the whole safety story for stopping" literal rather than nearly so: there is
nothing behind it. What follows is the two remaining guards, and first what
became of the claims, which still gate **Delete**.

- **What the two claims are for.** Kept apart on purpose, as they were:
  - **`startedSessions` — "this phone is why it is running"** — now decides
    **what the stop confirmation says**. A session this phone did not start gets
    an extra sentence naming it as somebody else's, so ending a scratch session
    and ending somebody's afternoon do not ask the same question. Written when a
    launch the host has confirmed running succeeds, and **dropped when the
    session stops**, because that is when it stops being true.
    - **The wording lives on `SessionControlModel`, not in
      `SessionControlFlow`.** `confirmation(for:about:on:)` is a static function
      beside `needsConfirmation` because a `private var message` on a view
      modifier is reachable by no test, and with the gate gone that sentence is
      the guard. `SessionActionsTests` pins both halves: that it appears for a
      session this phone did not start, and that it does **not** appear for one
      it did — a warning shown every time is one to tap through on the occasion
      it is true.
    - **Both claims are derived from what the host said *before* the launch,
      never from the caller.** `SessionStarter` reads `session list` first. A
      version that launched and then asked only "is it running now?" answered
      yes when the launch had done nothing *because it was already up*, and
      recorded a session somebody was working in as ours, which is now a Delete
      over their layout and used to be a Stop over their agents. A stale row is
      all it takes. **`session attach` makes this
      load-bearing rather than belt-and-braces:** the old `herdr server` at
      least failed loudly at a running session, while `attach` is idempotent and
      succeeds silently, so this look is now the only thing that tells the two
      apart. The same look settles the
      other claim: `createdSessions` only when the host had never heard of the
      name, so typing the name of somebody's stopped session into the new-
      session field resumes it without earning a Delete over their layout. Without expiry, starting and stopping the user's own
    `work` session from the phone would leave a permanent claim on the name, and
    the confirmation would then describe whatever the person at the Mac started
    next under it as this phone's own doing.
    - **A stop this phone did not perform still has to expire the claim, and
      `forgetStartedSession` cannot see one.** It is called from the stop path
      only, so a session the phone started and the *Mac* stopped — a reboot, or
      somebody stopping and re-attaching it at the keyboard — kept the claim, and
      the person at the Mac was then working in a session the phone called its
      own. While the claim gated Stop that was an unearned button; now that it
      words the confirmation it is worse, because the warning is the last guard
      and it would go missing in exactly the case it exists for.
      `PeerStore.reconcileStartedSessions(with:forHostKey:)` drops the claim for
      every claimed name the host reports as **stopped**, and both screens that
      read `session list` call it — `PeerDetailView`'s fetch and
      `SessionStatus.load`, which is the one behind the bar that offers Stop.
      - **On `running: false`, never on absence from the list**, and never on
        presence. Reconciling on presence would drop the claim on every refresh;
        absence means the session was *deleted*, which `forgetCreatedSession`
        already covers where the phone did it. Keyed by host key and read back
        from the store, so a caller holding a stale record cannot decide against
        a stale copy of the field being reconciled. `StartedClaimTests` pins all
        three halves, including that a still-running session keeps its claim.
  - **`createdSessions` — "this phone made it from nothing"** — is what
    **Delete** is offered on, and that one is still a gate. Deleting removes the
    session *directory*; for a session somebody else set up, that is their
    layout, and unlike a stop there is no command that puts it back.
  - So `SessionControlModel.actions(for:on:)` offers Stop for anything running,
    whoever started it, and **no Delete for one this phone merely restarted.**
    It is a name, not an identity: herdr has no notion of who created a
  session, so this is only ever what this install remembers doing. **A reinstall
  forgets, and then every stop asks the longer question and nothing can be
  deleted** — the safe direction, and the record lives under Application
  Support, which is excluded from backup and does not restore to a new phone.
  - **The claim is dropped on delete**, and that is not tidiness. The name is
    all that ties a session to this install, so one left behind would be
    inherited by the next session of that name — made by whoever is at the Mac
    — handing the phone a Delete over their layout.
  - **`merging` unions it.** A re-pair builds the incoming record from a
    scanned QR, which carries no sessions, so taking the newer value would
    withdraw the Delete action from every session this phone had created.
  - Stored as an **optional array**, not a defaulted one: the synthesized
    decoder does not apply default values for a missing key, and
    `PeerRegistry.all()` treats an undecodable file as a hard failure — a
    defaulted `Set` would have stranded every already-paired host on the first
    launch after this shipped.
- **A swipe asks; it does not act.** The peer row's rule, and for Stop it is now
  the only thing between the gesture and somebody's agents. The dialog names the
  session, says what goes with it and says whose it is, rather than asking "are
  you sure?" about a verb.
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
  same reason the row does not offer it — which is the one thing still gating
  Stop, and it is the session's own state rather than a claim about it.

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
- A running session offers **Stop**, whoever started it; a stopped one offers
  **Start**, then **Delete** if the phone created it — Start first, so a full
  swipe reaches the harmless one. Never a pair herdr would refuse, and **nothing
  at all for a name `SessionName` will not accept**: herdr takes `-x` and this
  app cannot address it, so a row created at the Mac under such a name would
  otherwise offer an action that fails by construction.
- **The session screen has a bottom bar too, and Start and Stop share its
  leading corner** (1 Oct 2026). One `ToolbarItem` holds whichever of the two
  the session's state allows, so the button does not move: stopping a session
  and starting it again is the pair most often done in a row, and with Stop on
  the right and Start on the left the second tap was at the far side of the
  screen from the first. The trailing corner takes what is left — the plus
  while the session runs, Delete once it has stopped and the phone created it.
- **The plus is trailing on every screen** (1 Oct 2026): hosts (Pair), a
  host's sessions, a session's workspaces, a workspace's agents. It used to be
  leading on three of them and moved when Stop took the session screen's
  leading corner; one place for the whole drill-down beats two. The host
  screen's gear and the host list's key took the leading corner in exchange,
  and the agents screen has a lone `ToolbarSpacer` before its plus, which is
  all that puts a single item on that side.
- **A bar button's confirmation is attached to the button, not to the screen**
  (1 Oct 2026). On iOS 26 a `confirmationDialog` opens out of the view it is
  attached to, so on the button it grows from under the finger and on the
  screen it appears from nowhere in particular. `SessionConfirmation` is the
  dialog; each bar button carries one naming its own action, and
  `SessionControlFlow` is told `confirmsHere: false` so the screen does not
  raise a second — two dialogs over one question is one that never appears.
  - **The peer screen still asks from the screen**, because its actions are
    swipes: a swipe button is gone by the time the question is up, so there is
    no view to attach to.
  - **Each button's binding is guarded on its own action, in both
    directions.** Start and Delete sit on one bar over one model; without the
    guard Delete's question could be presented from Start, and a dismissal
    written by the button that was never presented would cancel the other's.
  - `PreviewSmokeTests.barDialogSource` pins it against UIKit: the dialog is a
    popover whose `sourceItem` is the bar button item titled with the action.
    Measured on the simulator, not yet looked at on a device.
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

## Creating a workspace (built, 8 Sept 2026)

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
so Start is the prominent one and the plus is not shown at all. Prominence
follows the action, not the corner: the plus is prominent on the trailing side
and Stop is plain on the leading one, where Start will be.

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

## Starting an agent (built, 9 Sept 2026)

```
herdr agent start <name> --kind <KIND> --pane <ID> --timeout 30000
```

**Twenty-four kinds on 0.9.3** (twenty-three on 0.9.0 — `letta` joined), and the
value is both the kind and the executable: `--kind claude` runs `claude`.
`AgentKind` is a string with a known list rather than a closed enum, so a herdr
that grows another stays usable — the "unknown values must decode, never throw"
rule applied to a value, and **it has now been exercised for real**: the app
went a version behind and the only symptom was a picker missing one row.

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

### An agent that starts blocked (`agent_not_ready`, found on device 12 Sept 2026)

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
  labelled **"Open the pane"** rather than "Answer it": it shows the dialog,
  and the terminal takes the pane on opening, so it can be answered there.
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

**`--timeout` must be greater than 3000ms and at most 300000ms** — 0.9.3's
`--help` states the default and the maximum, where 0.9.0's said neither, and the
floor is still only in the refusal. Both ends measured: 3000 is refused and
300000 accepted, so the floor is exclusive and the ceiling is not. Below the
floor it answers `invalid_agent_timeout` and starts nothing. Bleat sends herdr's own default of 30000 explicitly. Shortening
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

## Another pane is a tab, not a split (built, 9 Sept 2026)

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

## A pane with no agent is a terminal, and the phone can now see one (20 Sept 2026)

**Herdr's default pane is a plain shell, and the phone could make one but never
find it again.** None of `workspace create`, `tab create` or `pane split` takes
a `--command`, so what launches is the user's own shell and an agent is an
explicit step afterwards — "Add a pane" inside the agent sheet has always
produced exactly that. Both ends were missing: the workspace screen lists
`agent list`, which does not report a pane herdr has not recognised an agent in,
so a shell had no row and no route; and the only button on it was Start Agent.

- **The screen asks `pane list` as well, and the two lists are one fetch.**
  `Pane.withoutAgents(in:)` in `BleatKit` is what tells them apart, and
  **occupancy is read from the agent list, never from a pane's own fields** —
  the rule `NewAgentModel` already followed, and the one that covers the pane a
  timed-out start left holding a detected agent herdr never got to name. Pinned
  against the captured fixtures, which happen to be the perfect case: ten panes,
  seven agents, three shells.
- **One `RemoteList` over a `WorkspaceEntry`, not two lists side by side.** The
  loading is where the subtle rules are — the generation token, a cancelled
  screen saying nothing, rows kept through a failed refresh — and two of them
  would mean two spinners, two failures, and a screen that can be half loaded.
- **Two sections, each drawn only when it has rows.** A heading over nothing
  reads as a list whose other half failed to arrive.
- **A terminal row opens in `.terminal`, never `.chat`.** A shell writes no
  transcript, so the chat an *agent* row opens would be an empty screen with a
  button on it. `TranscriptModel` already has `.unavailable` and names the plain
  shell as its first cause; the route carries the mode so it is not reached.
- **The row shows the directory only when the title does not already say it.**
  A login shell titles itself with where it is —
  `ravil@rawillkair:~/Developer/autorq/link-apple` in `Fixtures/pane-list.json`
  — so a path underneath would repeat the line above it on every idle shell. A
  running command retitles the pane, and then the path is what says which shell
  it is running in. Both are truncated at the head, as the agent rows are.
- **The plus is a menu: New Terminal, then Start Agent…** New Terminal has no
  sheet because there is nothing to ask — no name, no kind, no timeout, and no
  path, since a new tab's pane inherits the *workspace's* directory. It is one
  `tab create`, and the pane it brings is opened straight away.
  - **Only from inside a workspace**, because a tab belongs to one.
  - **The pane is taken from the reply's own `root_pane`**, never from
    "whichever pane is new" — in a workspace that already had a free pane that
    is a shell somebody at the Mac may be sitting in. A `root_pane` that did not
    decode is nil, and then nothing is opened and the reload simply lists it.
  - **The list reloads on the failure path too**, and that is the failure path's
    whole answer. A create that threw is not proof that nothing happened: a
    connection dropping after herdr ran the command leaves the tab there, and a
    plain refusal invites the retry that makes a second one. What landed is on
    screen under Terminals instead.
  - The refusal itself is an alert, for the reason `SessionControlFlow` uses
    one: there is no sheet of its own for it to be read in.
- **Opening a terminal row `stty`s that pane, and puts it back on the way
  out.** `PaneModel` resizes the pty to the phone's grid before it opens the
  stream — the same write it already makes for an agent's terminal — and
  `restore` returns it when the screen goes. What is new is *which* panes are
  one tap away: an agent's pane belongs to an agent, while this section lists
  the shell somebody at the Mac may be typing in, and looking at it reflows
  their window for as long as the phone is on that screen. Kept, because a
  terminal row has nothing else to show and the tap is the ask — but it is why
  the list only lists, and why nothing here opens a pane the user did not name.
- **Opening a terminal row takes the pane**, as every terminal does since 1 Oct
  2026 — see **The terminal always holds the pane** in
  [`pane-view.md`](pane-view.md). herdr allows one input
  owner and a `control` attach that is not a takeover is silently inert, so
  there is no way to type into a shell without becoming it.
