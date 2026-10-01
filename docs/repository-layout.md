# Repository layout

> Moved verbatim from `CLAUDE.md` on 1 Oct 2026. Where the text says "this file", "above" or "below", it means the old single file; a **bold** section name can be found with `grep -r docs/`.

House layout, matching the other projects in `~/Developer`: code lives in a
local Swift package, the `.xcodeproj` holds only targets, and the app target is
a thin shell.

```
Bleat.xcodeproj             # two app targets; sources join via synchronized groups
App/                        # @main App struct and little else
Watch/                      # the watch app's @main; shares App/'s icon and assets
  AppIcon.icon/             # layered Icon Composer document; joins the target by existing
Design/icon.swift           # generates the icon's layers — run it, never edit the PNGs
BleatKit/                   # the local Swift package
  Package.swift
  Sources/
    BleatKit/               # domain + transport. No SwiftUI. Builds for iOS.
      Transport/            # HerdrTransport protocol + SSHTransport (Citadel)
      Relay/                # the second transport: a watch asking the phone
      Protocol/             # NDJSON codec, frame/command types
      Model/                # Codable models for herdr JSON (from schema.json)
      Client/               # HerdrClient: typed API over a transport
      Keys/                 # device ed25519 key + Keychain storage
    BleatUI/                # SwiftUI shared between app targets; MainActor by default
      Context/              # AppContext, routers, stores
      Watch/                # WatchConnectivity: the watch's link, the phone's relay host
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
- **Tailscale on a Linux host works without a re-pair — verified on device,
  19 Sept 2026**, from an iPhone on cellular with Wi-Fi off. The Pi was paired
  *before* Tailscale was installed on it, so its QR carried no overlay
  endpoint; the phone's refresh on reconnect found them. `/sbin/ifconfig`
  gave `tailscale0`'s `100.112.148.125` and `fd7a:115c:a1e0::d82a:947e`, both
  classified `overlay`, and `/usr/bin/tailscale` the MagicDNS name
  `adam.tail2a3bab.ts.net`. This is the first time the refresh was confirmed
  against a Linux host, and it only worked because both probes use absolute
  paths that exist there.
  - **The mDNS probe is the one the refresh cannot run on Linux.** It is
    `scutil`, which a Linux host lacks, so it prints nothing — and
    `EndpointDiscovery.report` reads empty output as *no answer*, not as "no
    name", precisely so an absent tool cannot prune. `adam.local` came from
    the QR and stays: never pruned, never updated. A renamed avahi host keeps
    its old name on the phone until a re-pair, which is the case for asking
    avahi here as `HostInspector` does.
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
