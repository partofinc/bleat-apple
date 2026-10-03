#!/bin/bash
# Builds the console tool for aarch64 Linux as one static binary that runs on
# ARMv8.0 — a Raspberry Pi 4 or CM4 as well as a Pi 5.
#
#   Scripts/build-linux.sh <work-dir>
#
# The static Linux SDK replaces musl's allocator with mimalloc, and mimalloc
# 2.2 builds for `-march=armv8.1-a` on arm64 unless told not to. Its LSE
# atomics are inline, not behind a CPU check, so every binary the stock SDK
# makes dies with SIGILL in `_mi_options_init` before `main` on a Cortex-A72.
# This rebuilds mimalloc for ARMv8.0 and swaps it into a *copy* of the
# installed SDK — the installed one is never touched. Why, and how it was
# found: docs/repository-layout.md.
#
# Needs: swiftly with the toolchain below, that SDK installed, cmake and ninja.
set -euo pipefail

swift_version=6.4.0
bundle=swift-${swift_version}-RELEASE_static-linux-0.1.0.artifactbundle
# The version the SDK's own build script pins (swiftlang/swift-docker,
# swift-ci/sdks/static-linux/scripts/fetch-source.sh); keep them in step.
mimalloc_version=2.2.4
mimalloc_sha256=754a98de5e2912fddbeaf24830f982b4540992f1bab4a0a8796ee118e0752bda

work=${1:?usage: Scripts/build-linux.sh <work-dir>}
mkdir -p "$work"
work=$(cd "$work" && pwd)
repo=$(cd "$(dirname "$0")/.." && pwd)
bin=$HOME/.swiftly/bin
installed=$HOME/Library/org.swift.swiftpm/swift-sdks/$bundle

# The compiler calls itself `swift-6.4-RELEASE`; the SDK's URL needs `6.4.0`.
if ! "$bin/swift" --version 2>&1 | grep -qE "\(swift-(${swift_version}|${swift_version%.0})-RELEASE\)"; then
    echo "error: needs the swift.org $swift_version toolchain: swiftly use $swift_version" >&2
    exit 1
fi
if [[ ! -d $installed ]]; then
    echo "error: $bundle is not installed; see docs/repository-layout.md" >&2
    exit 1
fi

sdks=$work/sdks
sdk=$sdks/$bundle
sysroot=$sdk/swift-${swift_version}-RELEASE_static-linux-0.1.0/swift-linux-musl/musl-1.2.5.sdk/aarch64
marker=$sdk/.armv8.0-mimalloc-$mimalloc_version

if [[ ! -f $marker ]]; then
    echo "== copying the SDK"
    rm -rf "$sdk"
    mkdir -p "$sdks"
    cp -c -R "$installed" "$sdks/"     # an APFS clone: instant, and no extra space

    echo "== mimalloc $mimalloc_version for ARMv8.0"
    src=$work/mimalloc
    rm -rf "$src"
    mkdir -p "$src"
    curl -sfL "https://github.com/microsoft/mimalloc/archive/refs/tags/v$mimalloc_version.tar.gz" \
        -o "$src/source.tar.gz"
    echo "$mimalloc_sha256  $src/source.tar.gz" | shasum -a 256 -c --quiet
    tar xzf "$src/source.tar.gz" -C "$src"

    cat > "$src/toolchain.cmake" <<EOF
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR aarch64)
set(CMAKE_C_COMPILER_TARGET aarch64-unknown-linux-musl)
set(CMAKE_CXX_COMPILER_TARGET aarch64-unknown-linux-musl)
set(CMAKE_SYSROOT $sysroot)
set(CMAKE_C_COMPILER $bin/clang)
set(CMAKE_CXX_COMPILER $bin/clang++)
set(CMAKE_C_FLAGS_INIT "-resource-dir $sysroot/usr/lib/swift/clang")
set(CMAKE_CXX_FLAGS_INIT "-resource-dir $sysroot/usr/lib/swift/clang -stdlib=libc++")
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)
set(CMAKE_FIND_ROOT_PATH $sysroot)
EOF
    # The SDK's own flags, plus the one that matters: MI_NO_OPT_ARCH.
    cmake -G Ninja -S "$src/mimalloc-$mimalloc_version" -B "$src/build" \
        -DCMAKE_TOOLCHAIN_FILE="$src/toolchain.cmake" \
        -DCMAKE_BUILD_TYPE=RelWithDebInfo \
        -DMI_LIBC_MUSL=ON \
        -DMI_BUILD_SHARED=OFF \
        -DMI_BUILD_STATIC=ON \
        -DMI_BUILD_TESTS=OFF \
        -DMI_NO_OPT_ARCH=ON >/dev/null
    ninja -C "$src/build" >/dev/null

    # LDADD, CAS, SWP and the rest of LSE: none may be left inline. An atomic
    # whose result is unused disassembles as its ST* alias (STADDL), and CASP
    # is the pair form.
    lse=$("$bin/llvm-objdump" -d "$src/build/mimalloc.o" |
        grep -cE '\s((casp?|swp|ldadd|ldclr|ldset|ldeor|ldsmax|ldsmin|ldumax|ldumin)(a|l|al)?[bhw]?|st(add|clr|set|eor|smax|smin|umax|umin)l?[bhw]?)\s' || true)
    if [[ $lse != 0 ]]; then
        echo "error: the rebuilt mimalloc.o still has $lse LSE instructions" >&2
        exit 1
    fi

    # libc.a carries the allocator as one member, mimalloc.o; replace it.
    (cd "$src/build" && "$bin/llvm-ar" r "$sysroot/usr/lib/libc.a" mimalloc.o)
    cp "$src/build/libmimalloc.a" "$sysroot/usr/lib/libmimalloc.a"
    touch "$marker"
fi

echo "== bleat"
(cd "$repo/BleatKit" && "$bin/swift" build -c release --product bleat \
    --swift-sdk aarch64-swift-linux-musl --swift-sdks-path "$sdks" \
    --scratch-path "$work/build" -Xswiftc -gnone -Xlinker -s)
echo "$work/build/release/bleat"
