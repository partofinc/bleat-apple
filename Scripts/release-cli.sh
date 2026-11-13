#!/bin/bash
# Publishes the `bleat` console tool: builds macOS (universal) and Linux
# (aarch64, x86_64), packs each as a tarball, attaches them with SHA256SUMS to
# a GitHub release, and points the Homebrew formula at them.
#
#   Scripts/release-cli.sh <version> [--draft | --prerelease | --promote] [--skip-tap]
#
# Run from a clean checkout of a commit already on origin/main. The tag is
# `cli-<version>`, created here if it does not exist yet, and <version> must be
# `bleatVersion` in BleatKit/Sources/bleat/Version.swift. Never `v…`: a `v` tag
# starts the app's Xcode Cloud release.
#
# --draft makes a draft release and implies --skip-tap: a draft's assets are
# not downloadable, so a formula pointing at them would break every install.
# The tag is not pushed either; GitHub creates it when the draft is published.
#
# --prerelease publishes a GitHub pre-release that is not marked latest, and
# implies --skip-tap: install.sh's `releases/latest` and Homebrew keep serving
# the release before it. For a tool that only a newer, unreleased app pairs
# with (cli-2.0.0, ahead of Bleat 2 on the App Store). Testers install it with
# BLEAT_VERSION=<version>. Refused unless the repository's latest release is
# another one and the formula is on another version, since its notes promise
# 1.x users exactly that.
#
# --promote makes that pre-release the latest full release and points the
# formula at it, **building nothing**: what testers ran is what ships, with
# the checksums they saw (the formula reads the release's own SHA256SUMS). So
# it needs no checkout of the tagged commit and ignores Version.swift.
#
# Safe to run again for the same version after a failure: an existing release
# of the same kind gets its assets replaced, and an unchanged formula is not
# committed. A release of another kind is refused, never silently converted:
# a full release rerun as a pre-release would stay latest and keep reaching
# 1.x users while the output said it did not.
#
# Signing is optional. With BLEAT_SIGN_IDENTITY set to a "Developer ID
# Application: …" identity, the macOS binary is signed with the hardened
# runtime, and notarized with either an App Store Connect API key
# (BLEAT_NOTARY_KEY, the .p8 path, with BLEAT_NOTARY_KEY_ID and
# BLEAT_NOTARY_ISSUER) or BLEAT_NOTARY_PROFILE, a `notarytool
# store-credentials` profile. The key needs no keychain: a profile lives in
# one, and from a shell that cannot show a prompt notarytool reports the
# profile missing ("No Keychain password item found"). Without them it ships with the linker's ad-hoc signature,
# which Homebrew and `install.sh` accept, since neither marks a download as
# quarantined. A browser download of an unsigned build is blocked by Gatekeeper.
#
# Needs: Xcode, the Linux SDK and toolchain Scripts/build-linux.sh needs, gh.
set -euo pipefail

version=${1:?usage: Scripts/release-cli.sh <version> [--draft | --prerelease | --promote] [--skip-tap]}
shift
kind=full       # full, draft or prerelease: what this run publishes
promote=
skip_tap=
for flag in "$@"; do
    case $flag in
        --draft) [[ $kind == full && -z $promote ]] || { echo "error: pick one of --draft, --prerelease, --promote" >&2; exit 2; }
            kind=draft; skip_tap=1 ;;
        --prerelease) [[ $kind == full && -z $promote ]] || { echo "error: pick one of --draft, --prerelease, --promote" >&2; exit 2; }
            kind=prerelease; skip_tap=1 ;;
        --promote) [[ $kind == full ]] || { echo "error: pick one of --draft, --prerelease, --promote" >&2; exit 2; }
            promote=1 ;;
        --skip-tap) skip_tap=1 ;;
        *) echo "error: unknown flag $flag" >&2; exit 2 ;;
    esac
done

repo=$(cd "$(dirname "$0")/.." && pwd)
slug=partofinc/bleat-apple
tap=partofinc/homebrew-tap
tag=cli-$version
work=${BLEAT_RELEASE_WORK:-${TMPDIR:-/tmp}/bleat-release-$version}
dist=$work/dist

cd "$repo"

# What GitHub has for the tag: none, draft, prerelease or full. A failed
# lookup stops the script rather than reading as an answer: a wrong "not a
# pre-release" once meant pointing the formula at one.
release_kind() {
    local out
    if ! out=$(gh release view "$tag" --repo "$slug" --json isDraft,isPrerelease \
        -q 'if .isDraft then "draft" elif .isPrerelease then "prerelease" else "full" end' 2>&1); then
        if [[ $out == *"release not found"* ]]; then echo none; return; fi
        echo "error: cannot read release $tag: $out" >&2
        exit 1
    fi
    echo "$out"
}

# The version the tap's formula is on now.
formula_version() {
    local content
    content=$(gh api "repos/$tap/contents/Formula/bleat.rb" --jq .content) ||
        { echo "error: cannot read the formula in $tap" >&2; exit 1; }
    printf '%s' "$content" | base64 --decode | sed -nE 's/^ *version "([^"]+)"/\1/p'
}

# gh learnt `release edit --latest` and `release create --latest=false` late;
# an old gh would fail part way.
#
# The help is read whole before it is searched: piped into `grep -q`, grep
# exits at the first match, gh dies of SIGPIPE, and under `pipefail` the
# pipeline fails — this refused gh 2.104 on its first run.
need_gh_latest() {
    local help
    help=$(gh release "$1" --help 2>&1) || true
    [[ $help == *--latest* ]] ||
        { echo "error: this gh has no 'release $1 --latest'; update gh" >&2; exit 1; }
}

notes_tail="Static Linux builds for aarch64, from ARMv8.0 (Raspberry Pi 4 and newer), and for x86_64. The x86_64 build is new and less tried: please open an issue if it misbehaves."
notes="The \`bleat\` command for the computer running Herdr: \`bleat pair\` shows the code the Bleat app scans.

\`\`\`sh
brew install partofinc/tap/bleat                       # macOS
curl -fsSL https://raw.githubusercontent.com/$slug/main/Scripts/install.sh | sh   # Linux or macOS
\`\`\`

$notes_tail"
prerelease_notes="**Pre-release, for Bleat 2.** This \`bleat\` pairs hosts running herdr-core (\`hc\`) with the Bleat 2 app, which is not on the App Store yet; the Bleat 1.x app cannot pair with it. Homebrew and the install script still give 1.x users the release before this one. To try it:

\`\`\`sh
curl -fsSL https://raw.githubusercontent.com/$slug/main/Scripts/install.sh | BLEAT_VERSION=$version sh
\`\`\`

$notes_tail"

# Points the formula at the assets whose sums are in $1 (a SHA256SUMS file).
update_tap() {
    local sums=$1 sha_macos sha_arm sha_intel checkout=$work/tap
    sum() {
        local value
        value=$(awk -v f="$1.tar.gz" '$2 == f { print $1 }' "$sums")
        [[ $value =~ ^[0-9a-f]{64}$ ]] || { echo "error: no checksum for $1.tar.gz" >&2; exit 1; }
        echo "$value"
    }
    echo "== Homebrew formula"
    sha_macos=$(sum bleat-macos-universal)
    sha_arm=$(sum bleat-linux-aarch64)
    sha_intel=$(sum bleat-linux-x86_64)
    rm -rf "$checkout"
    gh repo clone "$tap" "$checkout" -- --quiet
    mkdir -p "$checkout/Formula"
    sed -e "s/@VERSION@/$version/g" \
        -e "s/@SHA_MACOS@/$sha_macos/" \
        -e "s/@SHA_LINUX_ARM@/$sha_arm/" \
        -e "s/@SHA_LINUX_INTEL@/$sha_intel/" \
        Scripts/bleat.rb.template > "$checkout/Formula/bleat.rb"
    if grep -q '@[A-Z_]*@' "$checkout/Formula/bleat.rb"; then
        echo "error: the formula still has a placeholder" >&2
        exit 1
    fi
    ruby -c "$checkout/Formula/bleat.rb" >/dev/null
    git -C "$checkout" add Formula/bleat.rb
    if git -C "$checkout" diff --cached --quiet; then
        echo "-- the formula is already at $version"
    else
        git -C "$checkout" commit -q -m "bleat $version"
        git -C "$checkout" push -q origin HEAD
    fi
}

if [[ -n $promote ]]; then
    need_gh_latest edit
    current=$(release_kind)
    if [[ $current != prerelease ]]; then
        echo "error: $tag is '$current', not a pre-release; --promote only promotes one" >&2
        exit 1
    fi
    rm -rf "$dist" && mkdir -p "$dist"
    gh release download "$tag" --repo "$slug" -p SHA256SUMS -D "$dist"
    # First, so that a failure here leaves everything as it was.
    echo "== promoting $tag to the latest release"
    gh release edit "$tag" --repo "$slug" --prerelease=false --latest --notes "$notes"
    if [[ -z $skip_tap ]]; then update_tap "$dist/SHA256SUMS"; fi
    echo "done: $tag promoted${skip_tap:+ (formula skipped)}"
    exit 0
fi

declared=$(sed -nE 's/^let bleatVersion = "([^"]+)"/\1/p' BleatKit/Sources/bleat/Version.swift)
if [[ $declared != "$version" ]]; then
    echo "error: Version.swift says $declared, not $version" >&2
    exit 1
fi
if [[ -n $(git status --porcelain --untracked-files=no) ]]; then
    echo "error: the working tree has changes; release from a clean checkout" >&2
    exit 1
fi
head=$(git rev-parse HEAD)
# What ships must be what landed: a release from an unmerged commit would
# publish code main never had, and send users to a main/Scripts/install.sh
# that does not match it.
git fetch -q origin main
if ! git merge-base --is-ancestor "$head" origin/main; then
    echo "error: HEAD is not on origin/main; release a merged commit" >&2
    exit 1
fi
if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
    if [[ $(git rev-parse "$tag^{commit}") != "$head" ]]; then
        echo "error: $tag exists and is not HEAD" >&2
        exit 1
    fi
fi
# The remote's tag too: a checkout that never fetched it would otherwise
# rebuild from another commit into a release that names this one.
remote_tag=$(git ls-remote origin "refs/tags/$tag^{}" | cut -f1)
[[ -n $remote_tag ]] || remote_tag=$(git ls-remote origin "refs/tags/$tag" | cut -f1)
if [[ -n $remote_tag && $remote_tag != "$head" ]]; then
    echo "error: $tag on origin is $remote_tag, not HEAD" >&2
    exit 1
fi

# An existing release must already be what this run publishes.
current=$(release_kind)
if [[ $current != none && $current != "$kind" ]]; then
    case $current in
        prerelease) hint="promote it with --promote, or rerun with --prerelease" ;;
        full) hint="a full release is not turned back into a ${kind} here; change it by hand if it must be" ;;
        draft) hint="publish or delete the draft first" ;;
    esac
    echo "error: $tag is already a $current release, not $kind: $hint" >&2
    exit 1
fi
if [[ $kind == prerelease ]]; then
    need_gh_latest create
    # The notes promise 1.x users the release before this one.
    latest=$(gh release view --repo "$slug" --json tagName -q .tagName) ||
        { echo "error: cannot read the latest release" >&2; exit 1; }
    if [[ -z $latest || $latest == "$tag" ]]; then
        echo "error: the latest release is '${latest:-none}'; a pre-release needs another one to leave in place" >&2
        exit 1
    fi
    on_tap=$(formula_version)
    if [[ -z $on_tap || $on_tap == "$version" ]]; then
        echo "error: the formula is at '${on_tap:-nothing}'; a pre-release needs it on another version" >&2
        exit 1
    fi
    echo "-- leaving $latest as latest and the formula at $on_tap"
fi

rm -rf "$dist"
mkdir -p "$dist"

pack() {    # pack <binary> <asset-name>
    local stage=$work/stage-$2
    rm -rf "$stage"
    mkdir -p "$stage"
    cp "$1" "$stage/bleat"
    cp LICENSE "$stage/"
    # Without macOS metadata, which GNU tar on Linux warns about at every install.
    COPYFILE_DISABLE=1 tar --no-xattrs --no-mac-metadata -C "$stage" -czf "$dist/$2.tar.gz" bleat LICENSE
}

echo "== macOS (arm64 + x86_64)"
# Xcode's toolchain, not swiftly's: a universal build needs xcbuild.
(cd BleatKit && xcrun swift build -c release --product bleat \
    --arch arm64 --arch x86_64 --scratch-path "$work/mac" -Xswiftc -gnone)
# Asked, not spelled out: the layout under the scratch path changes between
# toolchains (`apple/` before 6.4, `out/` since).
mac=$(cd BleatKit && xcrun swift build -c release --product bleat \
    --arch arm64 --arch x86_64 --scratch-path "$work/mac" --show-bin-path)/bleat
strip -x "$mac"
if [[ -n ${BLEAT_SIGN_IDENTITY:-} ]]; then
    codesign --force --options runtime --timestamp --sign "$BLEAT_SIGN_IDENTITY" "$mac"
    codesign --verify --strict --verbose=2 "$mac"
    if [[ -n ${BLEAT_NOTARY_KEY:-} ]]; then
        notary_auth=(--key "$BLEAT_NOTARY_KEY" --key-id "${BLEAT_NOTARY_KEY_ID:?with BLEAT_NOTARY_KEY}" \
            --issuer "${BLEAT_NOTARY_ISSUER:?with BLEAT_NOTARY_KEY}")
    elif [[ -n ${BLEAT_NOTARY_PROFILE:-} ]]; then
        notary_auth=(--keychain-profile "$BLEAT_NOTARY_PROFILE")
    else
        notary_auth=()
    fi
    if (( ${#notary_auth[@]} > 0 )); then
        # notarytool takes a zip, not a bare binary. A command-line tool
        # cannot be stapled; Gatekeeper checks its ticket online instead.
        # Its exit status is not the verdict, so the status is read.
        ditto -c -k "$mac" "$work/notarize.zip"
        verdict=$(xcrun notarytool submit "$work/notarize.zip" \
            "${notary_auth[@]}" --wait --output-format json |
            sed -nE 's/.*"status" *: *"([^"]+)".*/\1/p' | tail -1)
        if [[ $verdict != Accepted ]]; then
            echo "error: notarization says '${verdict:-nothing}', not Accepted; see notarytool log" >&2
            exit 1
        fi
    else
        echo "warning: signed but not notarized (no BLEAT_NOTARY_KEY or BLEAT_NOTARY_PROFILE)" >&2
    fi
else
    codesign --force --sign - "$mac"
    echo "warning: ad-hoc signed only (no BLEAT_SIGN_IDENTITY)" >&2
fi
[[ $("$mac" --version) == "$version" ]] || { echo "error: the macOS build does not report $version" >&2; exit 1; }
pack "$mac" bleat-macos-universal

for arch in aarch64 x86_64; do
    echo "== Linux $arch"
    # Its output is shown, not parsed; the binary is where build-linux.sh
    # documents it, and is checked to be the right kind of file.
    Scripts/build-linux.sh "$work/linux" "$arch"
    case $arch in
        aarch64) binary=$work/linux/build/release/bleat; elf="ARM aarch64" ;;
        x86_64)  binary=$work/linux/build-x86_64/release/bleat; elf="x86-64" ;;
    esac
    # Not `kind`, which is what this run publishes: reusing it here left the
    # release step with no case to match on the first cli-2.0.0 run. And the
    # output read whole, as for gh's help, not piped into `grep -q`.
    if [[ $(file "$binary") != *"ELF 64-bit LSB executable, $elf"* ]]; then
        echo "error: $binary is not a $elf Linux executable" >&2
        exit 1
    fi
    pack "$binary" "bleat-linux-$arch"
done

(cd "$dist" && shasum -a 256 *.tar.gz > SHA256SUMS)
cat "$dist/SHA256SUMS"

echo "== GitHub release $tag"
if [[ $current != none ]]; then
    echo "-- $tag exists as a $current release; replacing its assets"
    gh release upload "$tag" --repo "$slug" --clobber "$dist"/*.tar.gz "$dist/SHA256SUMS"
else
    case $kind in
        draft) flags=(--draft --target "$head"); body=$notes ;;
        prerelease) flags=(--prerelease --latest=false); body=$prerelease_notes ;;
        full) flags=(--latest); body=$notes ;;
        *) echo "error: nothing to publish as '$kind'" >&2; exit 1 ;;
    esac
    if [[ $kind != draft ]]; then
        if ! git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
            git tag -a "$tag" -m "bleat $version"
        fi
        git push origin "refs/tags/$tag"
    fi
    gh release create "$tag" --repo "$slug" "${flags[@]}" \
        --title "bleat $version" --notes "$body" "$dist"/*.tar.gz "$dist/SHA256SUMS"
fi

if [[ -n $skip_tap ]]; then
    case $kind in
        draft) echo "== skipped the Homebrew formula: assets of a draft cannot be downloaded" ;;
        prerelease) echo "== skipped the Homebrew formula: a pre-release is not for everyone yet" ;;
        *) echo "== skipped the Homebrew formula (--skip-tap)" ;;
    esac
    exit 0
fi

update_tap "$dist/SHA256SUMS"
echo "done: $tag released, formula at $version"
