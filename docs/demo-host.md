# The demo host

A disposable Linux machine on Fly (`Demo/`, app `bleat-demo`, personal org,
`sjc`) that runs Herdr, so App Review, or anyone evaluating Bleat without a
computer of their own, has something to pair with. The App Review notes point at
it; `~/.appstoreconnect/bin/bleat_review_notes.py` writes them.

- **https://bleat-demo.fly.dev**: the pairing page, behind a password (HTTP
  Basic; any user name; the Fly secret `DEMO_PASSWORD`). It shows a single-use
  `bleat://pair?d=…` link as an **Open in Bleat** button and a QR. Verified on a
  real iPhone 15 Oct 2026: Safari, the button, the app paired.
- **bleat-demo.fly.dev:22**: SSH, the address every pairing code names.

## What is on it

One herdr session, `demo`, with workspaces running real programs
(`Demo/populate.sh`): a web server and a script polling it, a test suite that
reruns, `htop`, a shell, and herdr's first workspace renamed `home`.

- **Each program sets its terminal title first.** The app titles a pane by its
  terminal title, and bash sets that only at its prompt, so without it every row
  read `demo@bleat-demo: ~`. herdr's own `pane rename` does not reach the app.
- **No AI agent runs here, on purpose.** An agent needs an API key, and a paired
  device has a full shell, so anyone given the pairing password could read it.
  herdr recognises agents by their own screens (per-agent manifests in
  `~/.local/state/herdr/agent-detection/`; `herdr agent explain --file` tests a
  screen against one), so a stand-in would have to imitate a real product, which
  a demo shown to App Review must not do. Adding a real agent later means a
  spending-capped key as a Fly secret and an outbound allowance for that
  provider's API.

## Why it is safe to hand out

A paired device can run anything as `demo`. Each property below was checked on
the deployed machine (15 Oct 2026) after a review found the first version's
holes.

- **Nowhere to go.** New outbound connections are refused machine-wide, DNS
  included: an open port 53 is a way out (the first version allowed it), and
  nothing resolves a name once the machine is up. Machine-wide because Fly's
  kernel has no iptables `owner` match ("Extension owner revision 0 not
  supported"). Side effect: `fly ssh console` hangs; use `fly machine exec <id>
  "<command>"`, which goes through Fly's API.
- **Fails closed.** If the block, the mounts or the limits cannot be put in
  place, `entrypoint.sh` exits and the machine does not come up.
- **Limits reach the panes.** `limits.conf` applies only to SSH logins through
  pam_limits; panes are children of the herdr server, started with `su`, whose
  PAM stack on Debian skips pam_limits. So herdr is started under `ulimit -u 256
  -n 4096 -f 1048576`, and every pane inherits it.
- **Fixed sizes.** `/home/demo` is a 512 MB ext4 image, made fresh at every boot
  (which is also the reset); `/tmp` 64 MB, `/var/tmp` and `/dev/shm` 16 MB. The
  root filesystem is not writable by `demo`.
- **demo cannot take the machine down for others.** The pairing page runs as
  `pairpage`, which demo cannot signal or inspect (its environment holds the
  password), and runs `bleat pair` as demo through one sudo rule. herdr is
  demo's own and demo can stop it; it is started again and, if the session is
  gone, refilled, instead of the machine restarting and unpairing everyone. Only
  sshd or the page exiting restarts the machine.
- **Nothing lasts.** The home, and with it every pairing, is rebuilt at every
  boot, and the machine restarts daily (`DEMO_RESET_SECONDS`). Only the SSH host
  key persists, on the volume, because the app pins it: a new one would look like
  an impostor to every paired device.
- **Key-only SSH** for `demo` alone; no root, no forwarding.

## Pairing, one at a time

Every `bleat pair` removes other pending enrollment keys first, so the page keeps
at most one running. A visitor while one is pending gets that same link; **get a
new code** (`/new`) cancels it, which makes `bleat pair` remove its key, and
starts another. `bleat pair` gets 30 seconds to print its link, read on a thread
so a stall cannot hold the lock and with it every request. The endpoint is
given with `--endpoint bleat-demo.fly.dev:22`, because the machine's own
addresses are private to Fly.

## Cost

One shared-cpu-1x machine with 512 MB, always on; a 1 GB volume; a dedicated
IPv4 ($2/month), because SSH is raw TCP and Fly's shared IPv4 carries only HTTP.
