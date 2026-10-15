#!/bin/bash
# Publishes the `bleat` console tool: builds macOS (universal) and Linux
# (aarch64, x86_64), packs each as a tarball, attaches them with SHA256SUMS to
# a GitHub release, and points the Homebrew formula at them.
#
#   Scripts/release-cli.sh <version> [--draft] [--skip-tap]
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
# Safe to run again for the same version after a failure: an existing release
# gets its assets replaced, and an unchanged formula is not committed.
#
# Signing is optional. With BLEAT_SIGN_IDENTITY set to a "Developer ID
# Application: …" identity, the macOS binary is signed with the hardened
# runtime and, with BLEAT_NOTARY_PROFILE naming a `notarytool store-credentials`
# profile, notarized. Without them it ships with the linker's ad-hoc signature,
# which Homebrew and `install.sh` accept, since neither marks a download as
# quarantined. A browser download of an unsigned build is blocked by Gatekeeper.
#
# Needs: Xcode, the Linux SDK and toolchain Scripts/build-linux.sh needs, gh.
set -euo pipefail

version=${1:?usage: Scripts/release-cli.sh <version> [--draft] [--skip-tap]}
shift
draft=
skip_tap=
for flag in "$@"; do
    case $flag in
        --draft) draft=1; skip_tap=1 ;;
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
    if [[ -n ${BLEAT_NOTARY_PROFILE:-} ]]; then
        # notarytool takes a zip, not a bare binary. A command-line tool
        # cannot be stapled; Gatekeeper checks its ticket online instead.
        # Its exit status is not the verdict, so the status is read.
        ditto -c -k "$mac" "$work/notarize.zip"
        verdict=$(xcrun notarytool submit "$work/notarize.zip" \
            --keychain-profile "$BLEAT_NOTARY_PROFILE" --wait --output-format json |
            sed -nE 's/.*"status" *: *"([^"]+)".*/\1/p' | tail -1)
        if [[ $verdict != Accepted ]]; then
            echo "error: notarization says '${verdict:-nothing}', not Accepted; see notarytool log" >&2
            exit 1
        fi
    else
        echo "warning: signed but not notarized (no BLEAT_NOTARY_PROFILE)" >&2
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
        aarch64) binary=$work/linux/build/release/bleat; kind="ARM aarch64" ;;
        x86_64)  binary=$work/linux/build-x86_64/release/bleat; kind="x86-64" ;;
    esac
    if ! file "$binary" | grep -q "ELF 64-bit LSB executable, $kind"; then
        echo "error: $binary is not a $kind Linux executable" >&2
        exit 1
    fi
    pack "$binary" "bleat-linux-$arch"
done

(cd "$dist" && shasum -a 256 *.tar.gz > SHA256SUMS)
cat "$dist/SHA256SUMS"

notes="The \`bleat\` command for the computer running Herdr: \`bleat pair\` shows the code the Bleat app scans.

\`\`\`sh
brew install partofinc/tap/bleat                       # macOS
curl -fsSL https://raw.githubusercontent.com/$slug/main/Scripts/install.sh | sh   # Linux or macOS
\`\`\`

Static Linux builds for aarch64, from ARMv8.0 (Raspberry Pi 4 and newer), and for x86_64. The x86_64 build is new and less tried: please open an issue if it misbehaves."

echo "== GitHub release $tag"
if gh release view "$tag" --repo "$slug" >/dev/null 2>&1; then
    echo "-- $tag exists; replacing its assets"
    gh release upload "$tag" --repo "$slug" --clobber "$dist"/*.tar.gz "$dist/SHA256SUMS"
elif [[ -n $draft ]]; then
    gh release create "$tag" --repo "$slug" --draft --target "$head" \
        --title "bleat $version" --notes "$notes" "$dist"/*.tar.gz "$dist/SHA256SUMS"
else
    if ! git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
        git tag -a "$tag" -m "bleat $version"
    fi
    git push origin "refs/tags/$tag"
    gh release create "$tag" --repo "$slug" --latest \
        --title "bleat $version" --notes "$notes" "$dist"/*.tar.gz "$dist/SHA256SUMS"
fi

if [[ -n $skip_tap ]]; then
    if [[ -n $draft ]]; then
        echo "== skipped the Homebrew formula: assets of a draft cannot be downloaded"
    else
        echo "== skipped the Homebrew formula (--skip-tap)"
    fi
    exit 0
fi

echo "== Homebrew formula"
sum() {
    local value
    value=$(awk -v f="$1.tar.gz" '$2 == f { print $1 }' "$dist/SHA256SUMS")
    [[ $value =~ ^[0-9a-f]{64}$ ]] || { echo "error: no checksum for $1.tar.gz" >&2; exit 1; }
    echo "$value"
}
sha_macos=$(sum bleat-macos-universal)
sha_arm=$(sum bleat-linux-aarch64)
sha_intel=$(sum bleat-linux-x86_64)
checkout=$work/tap
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
echo "done: $tag released, formula at $version"
