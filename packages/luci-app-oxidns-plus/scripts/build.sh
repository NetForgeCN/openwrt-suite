#!/bin/sh
# Local validation build for the vendored Rust source.
#
# In the real OpenWrt build this package is compiled from source by
# feeds/packages/lang/rust/rust-package.mk using the target's own musl
# cross-toolchain (see the Makefile); no prebuilt binary and no Release are
# used. This script exists only for workstation-side verification that the
# same source compiles cleanly and statically for every architecture that
# oxidns-core supports. It writes outputs to build/ (gitignored), never into
# the package source tree.
#
# Requires Rust 1.83+ with the listed musl targets. On non-x86 targets the
# host has no cross gcc, so rust-lld (shipped with Rust) is used as linker via
# CARGO_TARGET_<TRIPLE>_LINKER environment variables — this does not touch the
# source tree and cannot interfere with OpenWrt's own linker settings.
set -e
PKGROOT=$(cd "$(dirname "$0")/.." && pwd)
SRC="$PKGROOT/src/prewarmer-rs"
OUT="$PKGROOT/build"
mkdir -p "$OUT"

echo "== unit tests (host) =="
( cd "$SRC" && cargo test )

# architecture -> rust target triple (mirrors oxidns-core / rust-values.mk)
set -- \
    "x86_64:x86_64-unknown-linux-musl" \
    "aarch64:aarch64-unknown-linux-musl" \
    "i386:i686-unknown-linux-musl" \
    "armv7:armv7-unknown-linux-musleabihf" \
    "armv6:arm-unknown-linux-musleabihf"

echo "== ensure musl targets =="
rustup target add x86_64-unknown-linux-musl aarch64-unknown-linux-musl \
    i686-unknown-linux-musl armv7-unknown-linux-musleabihf \
    arm-unknown-linux-musleabihf 2>/dev/null || true

for spec in "$@"; do
    arch=${spec%%:*}
    target=${spec#*:}
    echo "== build $arch ($target) =="
    upper=$(printf '%s' "$target" | tr 'a-z-' 'A-Z_')
    eval "export CARGO_TARGET_${upper}_LINKER=rust-lld"
    ( cd "$SRC" && cargo build --release --target "$target" )
    bin="$SRC/target/$target/release/oxidns-prewarmer"
    install -m 755 "$bin" "$OUT/prewarmer-$arch"
done

echo "== verify static + sizes =="
for f in "$OUT"/prewarmer-*; do
    printf '%-30s ' "$(basename "$f")"
    file "$f" | sed 's/.*: //' | cut -c1-90
done
echo "== done =="
ls -lh "$OUT"
