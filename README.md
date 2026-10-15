<p align="center">
  <img src="docs/images/icon.png" width="128" height="128" alt="Bleat app icon">
</p>

<h1 align="center">Bleat</h1>

<p align="center">
  <strong>A native iPhone, iPad and Apple Watch remote for <a href="https://herdr.dev">Herdr</a>.</strong><br>
  See which coding agent is waiting on you, watch its terminal live, and answer it from anywhere.
</p>

<p align="center">
  <a href="https://apps.apple.com/app/id6823156554">App Store</a> ·
  <a href="#install-the-bleat-command">Install the command</a> ·
  <a href="docs/">Docs</a> ·
  <a href="LICENSE">MIT licence</a>
</p>

---

Herdr runs your agents in terminal workspaces on your own computer. Bleat is the
remote: a thin native client that connects to that computer over SSH and speaks
Herdr's own JSON. **Herdr and the agents always run on the host; Bleat never owns
a process.** There is no account, no relay and no server of ours in between.

## What it does

- **Who needs you, first.** Workspaces and agents are sorted by attention state.
  An agent waiting for approval sits above the ones that are working or done.
- **A live terminal.** Panes render through a real VT100/xterm emulator
  ([SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)), so an agent's
  screen looks the way it does at your desk.
- **Answer from anywhere.** Answer a tool approval, send a prompt, or type into
  the pane, with the arrows, Esc and Return above the keyboard and a menu of
  shortcuts (⌃C, Tab, ⇧Tab, …). Opening a terminal takes control of its pane;
  leaving it gives the pane back.
- **Start and stop work.** Sessions, workspaces, agents and tabs, from the phone.
- **iPad and Apple Watch.** A split view on iPad. On the watch, your hosts,
  sessions, workspaces and agents, relayed through the phone.

## How it works

```
 iPhone / iPad ──── SSH (LAN, Tailscale, any route you have) ────▶ Mac or Linux host
       ▲                                                            └─ herdr ─ agents
       │ WatchConnectivity
 Apple Watch
```

The app runs `herdr` CLI commands over SSH exec channels, plus one long-lived
channel per open pane for its terminal stream. List polling and the pane stream
share a single SSH connection. The watch cannot open a socket of its own, so it
asks the phone.

## Getting started

1. **Install [Herdr](https://herdr.dev)** on the Mac or Linux computer your
   agents run on, and turn on SSH (on a Mac: System Settings › General ›
   Sharing › Remote Login).
2. **Install the `bleat` command** on that computer (below).
3. **Run `bleat pair`** there. It shows a QR code in the terminal.
4. **In the app, tap "Pair a host"** and scan it.

To reach the computer away from home, give the phone a route to it, such as
[Tailscale](https://tailscale.com) on both. `bleat pair` finds the computer's
Tailscale addresses itself.

## Install the `bleat` command

**macOS** (Apple silicon and Intel), with Homebrew:

```sh
brew install partofinc/tap/bleat
```

**Linux** (arm64, including Raspberry Pi 4 and newer, and x86_64): one static
binary, installed into `~/.local/bin`:

```sh
curl -fsSL https://raw.githubusercontent.com/partofinc/bleat-apple/main/Scripts/install.sh | sh
```

Or download a build from [Releases](https://github.com/partofinc/bleat-apple/releases).

### Commands

```
bleat pair                 # show a pairing code for this computer
bleat keys list            # every device this computer lets in
bleat keys revoke <marker> # take a device's access away

bleat sessions | workspaces | agents   # what herdr has, from the terminal
bleat attach <pane> [--takeover]       # a pane's live stream; Ctrl-] detaches
```

`bleat help` lists the rest, including saved hosts for using the same commands
over SSH.

## Security

Pairing never puts a lasting secret on screen:

- The QR carries a **single-use enrollment key**. `bleat pair` adds it to
  `~/.ssh/authorized_keys` with `restrict` and an `expiry-time`, so sshd itself
  refuses it after a few minutes, even if the tool was killed.
- The phone connects with it, pins the host key from the QR, installs **its own
  key** (made on the phone, kept in the Keychain as device-only), and deletes
  the enrollment key.
- Access is revocable from either end: **Unpair** in the app removes the
  phone's key from the host; `bleat keys revoke` does it from the host.

The full reasoning is in [`docs/pairing.md`](docs/pairing.md).

## Building from source

Requirements: Xcode 27.1 (Swift 6.4), iOS and watchOS 26.

```sh
open Bleat.xcodeproj                 # the app and the watch app

cd BleatKit
swift build && swift test            # the package and the console tool
swift run bleat help
```

`BleatUI`'s pane view is UIKit-only and is not compiled by `swift build`; use
`xcodebuild -scheme BleatKit-Package -destination 'generic/platform=iOS'` from
`BleatKit/`. The Linux binaries come from `Scripts/build-linux.sh`, which uses
the static Linux SDK with an allocator that also runs on ARMv8.0 (Raspberry Pi
4 and CM4).

```
App/ Watch/        the two app targets (thin: an @main and assets)
BleatKit/          the Swift package
  BleatKit/        domain and transport, no UI; iOS, watchOS, macOS, Linux
  BleatUI/         SwiftUI shared by the phone and the watch
  BleatProcess/    macOS and Linux only: local herdr, the terminal QR
  bleat/           the console tool
  Fixtures/        captured herdr output, the source of truth for the models
docs/              one file per area, with the reasoning behind each decision
```

[`CLAUDE.md`](CLAUDE.md) is the index to `docs/` and the rules that have cost
the most to learn.

## Licence

[MIT](LICENSE).
