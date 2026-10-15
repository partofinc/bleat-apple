# The demo host

A disposable Linux machine on Fly that runs Herdr, so App Review (or anyone
evaluating Bleat without a computer of their own) has something to pair with.

- **https://bleat-demo.fly.dev**: the pairing page, behind a password (HTTP
  Basic; any user name). Each visit shows a single-use `bleat://pair?d=…` link,
  as an **Open in Bleat** button and a QR code.
- **bleat-demo.fly.dev:22**: SSH, the address every pairing code names.

## What is on it

One herdr session, `demo`, with workspaces running real programs
(`populate.sh`): a small web server and a script polling it, a test suite that
reruns, `htop`, and a shell at its prompt. Their files are `project/`.

**No AI agent runs here, on purpose.** An agent needs an API key, and a paired
device has a full shell, so anyone given the pairing password could read the
key. herdr recognises agents by their own programs' screens (its manifests in
`~/.local/state/herdr/agent-detection/`), so a stand-in would have to imitate a
real product, which a demo shown to App Review must not do. Adding a real agent
later means a spending-capped key as a Fly secret and an outbound allowance for
that provider's API, in `entrypoint.sh`.

## Why it is safe to hand out

A paired device can run anything as `demo`. So:

- **Nothing to steal.** No secret is on the machine except the pairing page's
  own password, which only gates pairing.
- **Nowhere to go.** New outbound connections are refused machine-wide, DNS
  included in practice. Fly's kernel has no iptables `owner` match, so the
  block cannot be limited to `demo`; nothing else needs the network once the
  machine is up. Side effect: `fly ssh console` hangs (it needs the private
  network). Use `fly machine exec <id> "<command>"`, which goes through Fly's
  API.
- **Fails closed.** If the block cannot be installed, `entrypoint.sh` exits and
  the machine does not come up.
- **Nothing lasts.** `/home/demo`, and with it every pairing, is rebuilt at
  every boot, and the machine restarts itself daily (`DEMO_RESET_SECONDS`).
  Only the SSH host key persists, on the volume, because the app pins it.
- **Limits** for `demo` logins (`limits.conf`): 256 processes, 4096 files.
- **Key-only SSH** for `demo` alone; no root, no forwarding.

## Pairing, one at a time

Every `bleat pair` removes other pending enrollment keys first, so
`pair-server.py` keeps at most one running. A visitor while one is pending gets
the same link; a new one starts when it is redeemed or expires (10 minutes).
`bleat pair` names the endpoint with `--endpoint bleat-demo.fly.dev:22`,
because the machine's own addresses are private to Fly.

## Running it

```sh
# once
fly apps create bleat-demo --org personal
fly volumes create bleat_demo_data --app bleat-demo --region sjc --size 1
fly ips allocate-v4 --app bleat-demo        # dedicated, $2/month: SSH is raw TCP
fly ips allocate-v6 --app bleat-demo
fly secrets set DEMO_PASSWORD=… --app bleat-demo

# each change
cd Demo && fly deploy --app bleat-demo --remote-only --ha=false
```

The image installs the published `bleat` (`BLEAT_VERSION` in the Dockerfile)
and the latest herdr. One shared-cpu-1x machine with 512 MB, always on.

Verified 15 Oct 2026: the page answers 401 without the password and serves a
link and QR with it; a link redeemed with `bleat redeem` from another machine
paired end to end (device key installed, enrollment key gone) and `bleat
unpair` removed it again; a direct connection to 1.1.1.1 from the machine is
refused; six workspaces are listed.
