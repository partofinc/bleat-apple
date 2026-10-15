# Repository layout

> Moved verbatim from `CLAUDE.md` on 1 Oct 2026. Where the text says "this file", "above" or "below", it means the old single file; a **bold** section name can be found with `grep -r docs/`.

House layout, matching the other projects in `~/Developer`: code lives in a
local Swift package, the `.xcodeproj` holds only targets, and the app target is
a thin shell.

**`App/` is a synchronized group of both app targets**, and the watch excepts
only `BleatApp.swift`. So anything else put in `App/` joins the watch app too:
the icon, the asset catalog and the privacy manifest, on purpose. **No Swift
file but `BleatApp.swift` belongs there** — a second one would be compiled into
the watch as well, and code belongs in the package anyway.

**`App/PrivacyInfo.xcprivacy`** declares no tracking, no collected data, and
the one required-reason API the app uses: `UserDefaults` (`@AppStorage` in
`PaneKeyBar`), reason `CA92.1`. App Store Connect checks it at submission and
TestFlight does not, so a new API from Apple's required-reason list needs its
line here before it ships. Added 3 Oct 2026.

```
Bleat.xcodeproj             # two app targets; sources join via synchronized groups
App/                        # @main App struct, icon, assets, PrivacyInfo.xcprivacy
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
Scripts/build-linux.sh      # the console tool for Linux: aarch64 (ARMv8.0 and up), or x86_64 (untried on hardware)
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
Scripts/build-linux.sh <scratch>            # aarch64; prints the binary's path
Scripts/build-linux.sh <scratch> x86_64     # the same for x86_64
```

The SDK version must match the compiler exactly, and its URL spells the version
`6.4.0` — the `6.4` form 404s, though the compiler calls itself `6.4`. The
result is statically linked, stripped, 62 MB (mostly Foundation's ICU data),
and runs on any aarch64 Linux from ARMv8.0 up. **x86_64 uses the installed SDK
unpatched** (added 15 Oct 2026): mimalloc 2.2.4's CMakeLists adds an
architecture flag on arm64 only, so the stock x86_64 allocator was built for
the SDK's own baseline. Not yet run on real x86_64 hardware. `scp` it to
`~/.local/bin/bleat`. Apple's `container` CLI is no route here: fetching its VM
init image from ghcr.io reads the login keychain, which is locked in an SSH
session.

**The stock SDK's binaries need ARMv8.1, so the script patches a copy of it
(3 Oct 2026).** The first build ran on `adam`, a CM5 (Cortex-A76, ARMv8.2).
On `mika`, a CM4 (Cortex-A72, ARMv8.0, `Features: fp asimd evtstrm crc32
cpuid`), the same binary exited 132 — SIGILL — before `main`. gdb on the host,
with an unstripped build:

```
=> 0x185cdf4 <_mi_options_init+24>:	ldaddal	x8, x8, [x9]
#2  _mi_options_init () at /home/build-user/source/mimalloc/src/options.c:176
#4  0x000000000182d330 in libc_start_init ()
```

- **The static SDK swaps musl's allocator for mimalloc**, as one `mimalloc.o`
  member of its `libc.a` (swiftlang/swift-docker,
  `swift-ci/sdks/static-linux/scripts/build.sh`). mimalloc 2.2 turns on
  `-march=armv8.1-a` for arm64 unless `MI_NO_OPT_ARCH` is set
  (`CMakeLists.txt:149`), and that script does not set it — so its LSE
  atomics (`ldaddal`, `casal`, `swp`) are inline, with no CPU check. Any
  binary the stock SDK makes fails the same way on a Pi 4 or CM4.
- **Nothing else in the binary has the problem.** Every inline LSE instruction
  in an unstripped build was in mimalloc; the Swift runtime and our code reach
  LSE only through the `__aarch64_*` outline helpers, which test the CPU at
  run time. The 72 left in the stripped binary are those helpers.
- **The script rebuilds mimalloc for ARMv8.0** — the SDK's own CMake flags
  plus `-DMI_NO_OPT_ARCH=ON`, with the swiftly clang, which is the same LLVM
  commit the SDK was built with — and replaces the member in an APFS clone of
  the installed SDK, built against with `--swift-sdks-path`. The installed SDK
  is never touched. The rebuilt object exports and imports exactly the
  original's symbols; the original had 379 LSE instructions and the script
  refuses a rebuild with any.
- **Verified on both boards**, 3 Oct 2026: `bleat inspect` and `bleat keys
  list` on `mika` and on `adam` from the one binary.
- **Drop the patch when the SDK sets `MI_NO_OPT_ARCH`** — reported as
  [swiftlang/swift-docker#604](https://github.com/swiftlang/swift-docker/issues/604)
  — and keep `mimalloc_version` in the script equal to the SDK's pin until then.

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
  `adam.tailf00d42.ts.net`. This is the first time the refresh was confirmed
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

## Working in this repository

Moved here from `CLAUDE.md`, which keeps the one-line rules.

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

- **`git add -A` can silently strip `Support/Info.plist`'s comments, because
  Xcode rewrites that file.** Caught in review, 30 Sept 2026: a commit that
  touched only doc comments also deleted the 25-line XML comment explaining why
  that plist exists at all — the two keys that cannot be build settings, the
  `PairingPayload.urlScheme` coupling no test can assert, and why
  `NSBonjourServices` is not optional. The keys themselves survived; only the
  reasoning went, which is the worse loss in a file nobody reads twice.
  - **`xcodebuild build` is not the culprit** — reproduced with a scratch
    `-derivedDataPath` and the file's md5 was unchanged. It is the **open
    Xcode**, which normalises a plist it manages, and plist serialisation drops
    comments. Same family as the DerivedData note below: the GUI and the command
    line both think they own things in here.
  - So **stage paths deliberately in this repo rather than `-A`**, and if the
    plist does appear in `git status` unexpectedly, diff it before staging:
    `PlistBuddy -c Print` on both versions says whether any *key* really moved.

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
