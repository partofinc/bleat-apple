# `bleat` console tool (Phase 1 acceptance)

> Moved verbatim from `CLAUDE.md` on 1 Oct 2026. Where the text says "this file", "above" or "below", it means the old single file; a **bold** section name can be found with `grep -r docs/`.

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

## `bleat pair` (Phase 2)

```
bleat pair [--endpoint HOST[:PORT]]...   # add endpoints detection cannot find
```

Checks that `herdr` is installed and resolvable, enumerates endpoints, mints the
single-use enrollment key, renders the QR in the terminal, and waits for the
phone to swap in its own key. See [`pairing.md`](pairing.md) for the rules
that govern it — they are settled, not per-PR decisions.

The QR must be rendered so it does not persist: draw it in the alternate screen
buffer and restore on exit, so it never enters scrollback. This matters even
with the enrollment key being single-use.

## `bleat redeem` and `bleat peers` (Phase 2)

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

## `bleat keys` (Phase 2)

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

## `$` is the wrong anchor for an `authorized_keys` line (found in review)

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
