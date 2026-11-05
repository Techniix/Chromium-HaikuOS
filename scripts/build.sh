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
    -e "s|@LIBCLANG_SO@|$(ls "$LIBCLANG_PREFIX"/lib/libclang.so* | head -1)|" \
    -e "s|@LIBCLANG_BINDINGS_DIR@|$LIBCLANG_BINDINGS_DIR|" \
    "$HERE/scripts/args.gn.in" > "$OUT/args.gn"
if [ -n "${EXTRA_GN_ARGS:-}" ]; then
  printf '\n# EXTRA_GN_ARGS\n%s\n' "$EXTRA_GN_ARGS" >> "$OUT/args.gn"
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
