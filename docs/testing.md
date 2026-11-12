# Testing against a live host

herdr-core runs on the dev Mac, so most of the stack needs no SSH: `bleat
terminals [--watch]` runs `hc connect` locally, behind the same
`HcStreamOpening` seam `SSHTransport` sits behind.

- **Never experiment on Ravil's live terminals or agents.** Attaching takes a
  terminal's size, and input lands in a real agent. Read-only calls —
  `hello`, `terminal.list`, `events.subscribe` — are what the app does anyway.
- **A scratch terminal for anything else**:
  `hc run --bg --no-parent --no-notify --name bleat-scratch -- /bin/sh -i`,
  then `hc kill bleat-scratch` and `hc rm bleat-scratch`. **`--no-parent` and
  `--no-notify` are not optional from inside an hc terminal** — where this
  Claude session runs — or hc makes the scratch terminal its child and types
  its exit notes into the session (seen 12 Nov 2026).
- Whether `--session`/`HC_SESSION` gives an isolated core is still open
  (`bleat-2-plan.md`, question 13).
- `ls` here is an alias that hangs without a tty; use `find`.

*(1.x)* herdr's scratch-session recipe — `script -q /dev/null herdr session
attach bleat-test &`, and the `HERDR_*` variables to unset from inside a herdr
pane — is in [`archive/herdr-facts.md`](archive/herdr-facts.md)'s era and no
longer applies.

To exercise the SSH path without changing system settings, generate a host key
and a client key, write an `sshd_config` with `StrictModes no` and
`UsePAM no`, and run `/usr/sbin/sshd -f <config> -D -e` as your own user on a
high port bound to `127.0.0.1`. Remember `hc` may not be on the PATH of the
resulting non-login shell; the gate's lookup also tries `~/.local/bin`, and
`bleat terminals --hc PATH` names it outright.

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

`PATH` cannot describe a host without herdr-core, either: `/etc/profile` runs
`path_helper`, which rebuilds `PATH` from `/etc/paths.d` — and Homebrew installs
a file there — so a login shell puts `/opt/homebrew/bin` back whatever it was
handed. Supply a stub `$SHELL` instead, as `EnrollmentShellTests` does.

Note that `NSHomeDirectory()` **ignores `$HOME`** on macOS — it reads the passwd
entry — so `PeerRegistry.standard()` and `HostRegistry.standard()` still write to
the real `~/.bleat/` under a scratch `HOME`. Pass an explicit directory when that
matters.

## `bleat redeem` writes to the real `~/.bleat`, on Linux too

`FileKeyStore` and `PeerRegistry` find `~/.bleat` through `NSHomeDirectory()`,
which ignores `HOME` on macOS *and* on Linux (found 15 Oct 2026 testing the
demo host from `mika`: `HOME=$tmp bleat redeem` wrote `/home/pi/.bleat`). To
test the phone's side without touching a machine's own state, use a machine
with no `~/.bleat` and delete it afterwards, after `bleat unpair` has taken the
key back off the host.
