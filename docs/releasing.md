# Releasing

Two products, two channels, two tag shapes. **Never push a `v…` tag for the
tool**: `v` tags start the app's Xcode Cloud workflow.

| | tag | what happens |
|---|---|---|
| the app | `v<MARKETING_VERSION>`, e.g. `v1.0.1` | Xcode Cloud's **Release** workflow archives the `Bleat` scheme (the watch app is embedded) and uploads it to App Store Connect. Build numbers are Xcode Cloud's run numbers. |
| the `bleat` tool | `cli-<bleatVersion>`, e.g. `cli-1.0.0` | `Scripts/release-cli.sh` builds, publishes a GitHub release on this repo, and updates the formula in `partofinc/homebrew-tap`. |

## The app

**An app release on GitHub is never "latest".** `install.sh` downloads the
tool from `releases/latest/download`, so a `v…` release marked latest would
leave `curl … | sh` looking for tool files in a release that has none. Publish
it with `gh release create v<version> --verify-tag --latest=false`, as `v1.0`
was (22 Oct 2026); only `release-cli.sh` passes `--latest`.

After a version ships, `MARKETING_VERSION` (both targets in
`Bleat.xcodeproj/project.xcproj`) moves to the next one, so builds of `main`
upload as that version rather than as another build of the released one.

**2.0 went to TestFlight before Phase D** (decided by Ravil, 14 Nov 2026),
so Bleat 2 builds can reach his phone away from the Mac's cable and network.
`MARKETING_VERSION` is 2.0 and `v2.0` starts the Release workflow as any
`v` tag does. A later TestFlight build of Bleat 2 is another 2.0 build, not
a new version; how it is started (Start Build in App Store Connect on
`main`, or a tag the workflow's start condition matches) is not settled —
the start condition lives in App Store Connect, not in this repo. Do not
move `v2.0`. It is not a release: no GitHub release is made for it, and the
App Store submission is Phase D's.

Xcode Cloud onboarding could not be finished from `main`: it asked for access
to every public dependency repository (`apple/swift-system` first), which
nobody outside those organizations can grant. It was finished on a local branch
with the packages stripped, and only the generated
`Bleat.xcodeproj/xcshareddata/xcodecloud/manifest.json` was kept (#64). The
first cloud build of `main`, with every package, then resolved them without
any grant. If onboarding ever has to be redone, do the same.

Build 1 of 1.0 was uploaded by hand from Organizer, before Xcode Cloud. Its
first run was a plain build, so the first archive is build 2 or later.

## The tool

```sh
# in a clean checkout of the commit to release (a worktree keeps the open
# Xcode's edits out of it), with Version.swift already at the new version:
Scripts/release-cli.sh 1.0.0 [--draft | --prerelease | --promote] [--skip-tap]
```

It refuses a tree with changes, a commit not on `origin/main`, a version that
disagrees with `BleatKit/Sources/bleat/Version.swift`, and a `cli-` tag on
another commit. **It is safe to rerun** for the same version: an existing
release has its assets replaced, and an unchanged formula is not committed.
**`--draft` skips the tap and pushes no tag**: a draft's assets cannot be
downloaded, so a formula pointing at them would break every install.
**`--prerelease` publishes a GitHub pre-release not marked latest, and skips
the tap**, so `install.sh` (`releases/latest`) and Homebrew keep serving the
release before it; testers install it with `BLEAT_VERSION=<version>`. Added
for cli-2.0.0 (13 Nov 2026), which pairs only with Bleat 2 while the App Store
app is 1.x: published as latest, it would have stopped every 1.x user who
upgraded `bleat` from pairing. Its notes promise 1.x users the release before
it, so the script checks that first: it refuses unless the latest release is
another tag and the formula is on another version.

**`--promote` makes that pre-release the latest full release and points the
formula at it, building nothing.** What testers ran is what ships, with the
checksums they saw: the formula is filled from the release's own
`SHA256SUMS`. It needs no checkout of the tagged commit and ignores
`Version.swift`, so it runs from any up-to-date `main`, months later. It
refuses anything but an existing pre-release, and edits the release before
touching the tap, so a failure leaves both as they were. Run it when Bleat 2
goes to App Review: `Scripts/release-cli.sh 2.0.0 --promote`.

**A release is never converted by a rerun.** Rerunning for a version whose
release already exists is for replacing assets after a failure, and is
refused when the existing release is another kind (full, draft, pre-release)
than this run would publish: a full release rerun as `--prerelease` would
have stayed latest and kept reaching 1.x users while saying it did not. The
tag on origin is checked as well as the local one, so a checkout that never
fetched it cannot rebuild into a release that names another commit.
Notarization is judged by notarytool's JSON `status`, not its exit code.
Assets have **no version in their names** (`bleat-macos-universal.tar.gz`,
`bleat-linux-aarch64.tar.gz`, `bleat-linux-x86_64.tar.gz`, `SHA256SUMS`), so
`Scripts/install.sh` can use `releases/latest/download/…`. That needs the tool's
release to be the repository's latest, which the script marks it; the app has
no GitHub releases.

- **macOS** is one universal binary from Xcode's toolchain (`xcrun swift build
  --arch arm64 --arch x86_64`). The output directory is asked for with
  `--show-bin-path`: it moved from `apple/` to `out/` in 6.4.
- **Linux** is `Scripts/build-linux.sh`, once per architecture.
- **Signing is optional.** `BLEAT_SIGN_IDENTITY` (a Developer ID Application
  identity) signs with the hardened runtime. Notarization authenticates with
  the App Store Connect API key (`BLEAT_NOTARY_KEY`, `_KEY_ID`, `_ISSUER`) or a
  `notarytool store-credentials` profile (`BLEAT_NOTARY_PROFILE`). **Prefer the
  key:** a profile lives in the keychain, and from a shell that cannot show a
  prompt notarytool says the profile does not exist (15 Oct 2026: stored and
  used fine, then "No Keychain password item found" minutes later, and
  re-storing failed with "User interaction is not allowed"). `codesign` kept
  working throughout. Without them the binary keeps
  an ad-hoc signature. Homebrew and `install.sh` both download with curl, which
  sets no quarantine flag, so an ad-hoc binary runs; one downloaded in a browser
  is stopped by Gatekeeper. A command-line tool cannot be stapled.
- **Tarballs are written without macOS metadata** (`COPYFILE_DISABLE=1`,
  `--no-xattrs`): GNU tar warns about `LIBARCHIVE.xattr.com.apple.provenance`
  otherwise.

`Scripts/install.sh` takes `BLEAT_DOWNLOAD_BASE=file:///path/to/dist` to install
from a local build before anything is published, `BLEAT_VERSION` to pin one,
and `BLEAT_INSTALL_DIR` (default `~/.local/bin`). It checks the tarball against
`SHA256SUMS` and installs nothing on a mismatch. Verified 15 Oct 2026: the
macOS binary on this Mac (native and under Rosetta), the aarch64 binary on
`mika` (CM4, ARMv8.0), a tampered tarball refused. The x86_64 Linux binary has
not yet run on x86_64 hardware.

The formula is generated from `Scripts/bleat.rb.template`; edit that, never the
tap's copy.
