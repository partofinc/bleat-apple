# Releasing

Two products, two channels, two tag shapes. **Never push a `v…` tag for the
tool**: `v` tags start the app's Xcode Cloud workflow.

| | tag | what happens |
|---|---|---|
| the app | `v<MARKETING_VERSION>`, e.g. `v1.0.1` | Xcode Cloud's **Release** workflow archives the `Bleat` scheme (the watch app is embedded) and uploads it to App Store Connect. Build numbers are Xcode Cloud's run numbers. |
| the `bleat` tool | `cli-<bleatVersion>`, e.g. `cli-1.0.0` | `Scripts/release-cli.sh` builds, publishes a GitHub release on this repo, and updates the formula in `partofinc/homebrew-tap`. |

## The app

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
Scripts/release-cli.sh 1.0.0 [--draft] [--skip-tap]
```

It refuses a tree with changes, a commit not on `origin/main`, a version that
disagrees with `BleatKit/Sources/bleat/Version.swift`, and a `cli-` tag on
another commit. **It is safe to rerun** for the same version: an existing
release has its assets replaced, and an unchanged formula is not committed.
**`--draft` skips the tap and pushes no tag**: a draft's assets cannot be
downloaded, so a formula pointing at them would break every install.
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
