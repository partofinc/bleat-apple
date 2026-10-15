#!/bin/bash
# Publishes the `bleat` console tool: builds macOS (universal) and Linux
# (aarch64, x86_64), packs each as a tarball, attaches them with SHA256SUMS to
# a GitHub release, and points the Homebrew formula at them.
#
#   Scripts/release-cli.sh <version> [--draft] [--skip-tap]
#
# Run from a clean checkout of the commit being released. The tag is
# `cli-<version>`, created here if it does not exist yet, and <version> must be
# `bleatVersion` in BleatKit/Sources/bleat/Version.swift. Never `v…`: a `v` tag
# starts the app's Xcode Cloud release.
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
        --draft) draft=--draft ;;
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
    if [[ -n ${BLEAT_NOTARY_PROFILE:-} ]]; then
        # notarytool takes a zip, not a bare binary. A command-line tool
        # cannot be stapled; Gatekeeper checks its ticket online instead.
        ditto -c -k "$mac" "$work/notarize.zip"
        xcrun notarytool submit "$work/notarize.zip" --keychain-profile "$BLEAT_NOTARY_PROFILE" --wait
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
    binary=$(Scripts/build-linux.sh "$work/linux" "$arch" | tail -1)
    pack "$binary" "bleat-linux-$arch"
done

(cd "$dist" && shasum -a 256 *.tar.gz > SHA256SUMS)
cat "$dist/SHA256SUMS"

echo "== GitHub release $tag"
if ! git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
    git tag -a "$tag" -m "bleat $version"
fi
git push origin "refs/tags/$tag"
gh release create "$tag" --repo "$slug" $draft --latest \
    --title "bleat $version" \
    --notes "The \`bleat\` command for the computer running Herdr: \`bleat pair\` shows the code the Bleat app scans.

\`\`\`sh
brew install partofinc/tap/bleat                       # macOS
curl -fsSL https://raw.githubusercontent.com/$slug/main/Scripts/install.sh | sh   # Linux or macOS
\`\`\`

Static Linux builds run on aarch64 from ARMv8.0 (Raspberry Pi 4 and newer) and on x86_64." \
    "$dist"/*.tar.gz "$dist/SHA256SUMS"

if [[ -n $skip_tap ]]; then
    echo "== skipped the Homebrew formula (--skip-tap)"
    exit 0
fi

echo "== Homebrew formula"
sum() { awk -v f="$1.tar.gz" '$2 == f { print $1 }' "$dist/SHA256SUMS"; }
checkout=$work/tap
rm -rf "$checkout"
gh repo clone "$tap" "$checkout" -- --quiet
mkdir -p "$checkout/Formula"
sed -e "s/@VERSION@/$version/g" \
    -e "s/@SHA_MACOS@/$(sum bleat-macos-universal)/" \
    -e "s/@SHA_LINUX_ARM@/$(sum bleat-linux-aarch64)/" \
    -e "s/@SHA_LINUX_INTEL@/$(sum bleat-linux-x86_64)/" \
    Scripts/bleat.rb.template > "$checkout/Formula/bleat.rb"
git -C "$checkout" add Formula/bleat.rb
git -C "$checkout" commit -q -m "bleat $version"
git -C "$checkout" push -q origin HEAD
echo "done: $tag released, formula at $version"
