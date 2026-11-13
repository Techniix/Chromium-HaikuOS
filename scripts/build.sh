#!/bin/bash
# Copyright 2026 The Chromium Authors
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.
#
# Bootstrap GN, generate the build and run ninja.
# Usage: scripts/build.sh SRC_DIR [OUT_DIR] [ninja target ...]
#   OUT_DIR defaults to out/Release; target defaults to "chrome".
# Environment:
#   JOBS=N            ninja parallelism (default: CPU count)
#   EXTRA_GN_ARGS=..  appended to the generated args.gn

set -euo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
SRC=${1:?usage: build.sh SRC_DIR [OUT_DIR] [target ...]}
SRC=$(cd "$SRC" && pwd)
OUT=${2:-out/Release}
shift $(( $# > 1 ? 2 : 1 ))
TARGETS=("$@")
[ ${#TARGETS[@]} -gt 0 ] || TARGETS=(chrome)

[ -f "$SRC/.haiku-prepared" ] || { echo "Run scripts/prepare-tree.sh $SRC first." >&2; exit 1; }

. "$HERE/scripts/detect-toolchain.sh"

export CC=$CLANG CXX=$CLANGXX AR=$LLVM_AR NM=${LLVM_AR%-ar}-nm
# Chromium's Rust code uses unstable features of the stable toolchain.
export RUSTC_BOOTSTRAP=1
# Stub pkg-config entries for libraries Haiku lacks that GN only queries
# (atspi-2, dri, gbm); see prebuilt/pkgconfig.
export PKG_CONFIG_PATH="$HERE/prebuilt/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

cd "$SRC"
mkdir -p "$OUT"

# --- GN ----------------------------------------------------------------------
if [ ! -x "$OUT/gn" ]; then
  echo "==> Bootstrapping GN"
  # GN upstream supports Haiku (build/gen.py knows the platform).
  python3 tools/gn/bootstrap/bootstrap.py --skip-generate-buildfiles \
    --build-path="$OUT"
  mkdir -p buildtools/haiku buildtools/linux64
  ln -sf "$SRC/$OUT/gn" buildtools/haiku/gn
  ln -sf "$SRC/$OUT/gn" buildtools/linux64/gn
fi

# --- args.gn -----------------------------------------------------------------
echo "==> Writing $OUT/args.gn"
sed -e "s|@CLANG_BASE_PATH@|$CLANG_BASE_PATH|" \
    -e "s|@RUST_SYSROOT@|$RUST_SYSROOT|" \
    -e "s|@RUSTC_VERSION@|$RUSTC_VERSION|" \
    -e "s|@LIBCLANG_SO@|$(ls "$LIBCLANG_PREFIX"/lib/libclang.so.$("$CLANG" -dumpversion | cut -d. -f1)* 2>/dev/null | head -1)|" \
    -e "s|@LIBCLANG_BINDINGS_DIR@|$LIBCLANG_BINDINGS_DIR|" \
    "$HERE/scripts/args.gn.in" > "$OUT/args.gn"
if [ -n "${EXTRA_GN_ARGS:-}" ]; then
  printf '\n# EXTRA_GN_ARGS\n%s\n' "$EXTRA_GN_ARGS" >> "$OUT/args.gn"
fi

# --- Haiku helper library -----------------------------------------------------
# build/config/haiku/compat/lib (Haiku patch 0006/0011) holds C and C++ helpers
# that GN cannot build: the Media Kit audio shim must be compiled against
# Haiku's own headers and libstdc++, not Chromium's libc++. libm.a there is a
# linker script that pulls libhaikucompat.a (and libgnu, libmedia, libbe) into
# every link.
COMPAT=$SRC/build/config/haiku/compat/lib
if [ ! -f "$COMPAT/libhaikucompat.a" ] ||
   [ "$COMPAT/haiku_cxa_thread_atexit.c" -nt "$COMPAT/libhaikucompat.a" ] ||
   [ "$COMPAT/haiku_media_audio.cpp" -nt "$COMPAT/libhaikucompat.a" ]; then
  echo "==> Building libhaikucompat.a"
  [ -n "${SYS_CXX:-}" ] || { echo "No system C++ compiler (g++) for the Media Kit shim." >&2; exit 1; }
  ( cd "$COMPAT"
    "$CLANG" -fPIC -O2 -c haiku_cxa_thread_atexit.c -o haiku_cxa_thread_atexit.o
    "$SYS_CXX" -fPIC -O2 -fno-exceptions -fno-rtti -fno-sized-deallocation \
        -c haiku_media_audio.cpp -o haiku_media_audio.o
    rm -f libhaikucompat.a
    "$LLVM_AR" rcs libhaikucompat.a haiku_cxa_thread_atexit.o haiku_media_audio.o )
fi

# --- Pregenerated Tint sources -----------------------------------------------
# Tint's generator needs Go >= 1.26 (not available on Haiku); see docs/TINT.md.
if [ ! -f "$OUT/gen/src/tint/lang/core/enums.cc" ]; then
  echo "==> Unpacking pregenerated Tint sources into $OUT/gen"
  mkdir -p "$OUT/gen"
  tar -xzf "$HERE/prebuilt/tint-gen.tar.gz" -C "$OUT/gen"
fi

echo "==> gn gen $OUT"
"$OUT/gn" gen "$OUT"

# --- ninja -------------------------------------------------------------------
JOBS=${JOBS:-$(nproc 2>/dev/null || sysinfo -cpu 2>/dev/null | grep -c '^CPU #' || echo 2)}
echo "==> ninja -j$JOBS ${TARGETS[*]}"
ninja -C "$OUT" -j"$JOBS" "${TARGETS[@]}"

echo
echo "Built $SRC/$OUT/chrome"
echo "Run it with: $HERE/scripts/run-chromium.sh $SRC/$OUT"
