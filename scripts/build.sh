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
#   LOG_DIR=DIR       where build logs go (default: logs/ in this repository)
#
# Every run writes logs/build-YYYYMMDD-HHMMSS.log (everything gn and ninja
# printed) and, if it fails, logs/build-YYYYMMDD-HHMMSS-failures.txt with just
# the failing steps and their error output: that is the file to send when
# asking for help. logs/build-latest*.txt point at the newest ones.

set -euo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
SRC=${1:?usage: build.sh SRC_DIR [OUT_DIR] [target ...]}
SRC=$(cd "$SRC" && pwd)
OUT=${2:-out/Release}
shift $(( $# > 1 ? 2 : 1 ))
TARGETS=("$@")
[ ${#TARGETS[@]} -gt 0 ] || TARGETS=(chrome)

[ -f "$SRC/.haiku-prepared" ] || { echo "Run scripts/prepare-tree.sh $SRC first." >&2; exit 1; }

# --- logs --------------------------------------------------------------------
LOG_DIR=${LOG_DIR:-$HERE/logs}
mkdir -p "$LOG_DIR"
LOG_DIR=$(cd "$LOG_DIR" && pwd)
LOG_STAMP=$(date +%Y%m%d-%H%M%S)
LOG=$LOG_DIR/build-$LOG_STAMP.log
FAILURES=$LOG_DIR/build-$LOG_STAMP-failures.txt
{
  echo "# build.sh $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "# port: $(git -C "$HERE" rev-parse --abbrev-ref HEAD 2>/dev/null) $(git -C "$HERE" rev-parse --short HEAD 2>/dev/null)"
  echo "# system: $(uname -a)"
  echo "# source: $SRC ($(cat "$SRC/.haiku-prepared"))"
  echo "# out: $OUT, targets: ${TARGETS[*]}, JOBS=${JOBS:-auto}, EXTRA_GN_ARGS=${EXTRA_GN_ARGS:-}"
} > "$LOG"
ln -sf "$(basename "$LOG")" "$LOG_DIR/build-latest.log"

# Pull the failing steps out of a ninja log: from each "FAILED:" line up to the
# next progress line ("[123/456] ...") or ninja's closing message.
extract_failures() {
  awk '
    /^FAILED: /                    { on = 1; n++; print "======== failure " n; print; next }
    on && /^\[[0-9]+\/[0-9]+\] /    { on = 0; print ""; next }
    on && /^ninja: build stopped/  { on = 0; print ""; next }
    on                             { print }
    /^ninja: error/                { print "========"; print }
  ' "$1"
}

# Run a build step with its output going to the terminal and the log; on
# failure, write the failures file and stop.
logged() { # step-name command...
  local step=$1; shift
  set +e
  "$@" 2>&1 | tee -a "$LOG"
  local rc=${PIPESTATUS[0]}
  set -e
  [ "$rc" -eq 0 ] && return 0
  {
    head -5 "$LOG"
    echo "# failed step: $step (exit $rc)"
    echo
    if [ "$step" = ninja ]; then
      extract_failures "$LOG"
    else
      sed -n '6,$p' "$LOG" | tail -n 200
    fi
    if grep -qE 'Return code is -11|code=139|code=245|Segmentation fault' "$LOG"; then
      echo
      echo "# A tool crashed (SIGSEGV). Run the failing command by hand from"
      echo "# $SRC/$OUT to get Haiku's crash report (Debugger > Save report)."
    fi
  } > "$FAILURES"
  ln -sf "$(basename "$FAILURES")" "$LOG_DIR/build-latest-failures.txt"
  echo
  echo "Build failed in $step. Send this file: $FAILURES" >&2
  echo "Full log: $LOG" >&2
  exit "$rc"
}

. "$HERE/scripts/detect-toolchain.sh"

export CC=$CLANG CXX=$CLANGXX AR=$LLVM_AR NM=${LLVM_AR%-ar}-nm
# Chromium's Rust code uses unstable features of the stable toolchain.
export RUSTC_BOOTSTRAP=1
# Stub pkg-config entries for libraries Haiku lacks that GN only queries
# (atspi-2, dri, gbm); see prebuilt/pkgconfig.
# Renga: /boot/system/data/renga_wayland/pkgconfig has wayland-client.pc and
# wayland-server.pc for Renga's socket-transport libwayland (package
# renga_wayland). It goes first, so Chromium's pkg-config lookups of
# "wayland-client"/"wayland-server" find it rather than HaikuPorts'
# in-process libwayland, which must not end up in the same process.
RENGA_WAYLAND_PC=/boot/system/data/renga_wayland/pkgconfig
export PKG_CONFIG_PATH="$RENGA_WAYLAND_PC:$HERE/prebuilt/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

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

# --- Renga check ---------------------------------------------------------------
# This branch targets Renga (Techniix/haiku ce/main), not stock Haiku: it uses
# Renga's epoll, eventfd, inotify, memfd_create, backtrace and
# __cxa_thread_atexit_impl. Fail early, with a clear message, on a system that
# lacks them instead of deep inside the link.
GNU_HEADERS=/boot/system/develop/headers/gnu
for h in sys/epoll.h sys/eventfd.h sys/inotify.h execinfo.h; do
  [ -f "$GNU_HEADERS/$h" ] || {
    echo "$GNU_HEADERS/$h is missing: this is the Renga branch, it does not" >&2
    echo "build on stock Haiku. Use the main branch there." >&2
    exit 1; }
done
grep -q memfd_create "$GNU_HEADERS/sys/mman.h" 2>/dev/null || {
  echo "This Renga image has no memfd_create(); update it (see docs/RENGA.md)." >&2
  exit 1; }
[ -f /boot/system/data/renga_wayland/pkgconfig/wayland-client.pc ] || {
  echo "Package renga_wayland is missing: use the Renga image" >&2
  echo "2026.11.15-chromium-readiness or later. This branch no longer builds" >&2
  echo "against HaikuPorts' in-process libwayland." >&2
  exit 1; }

# --- Haiku helper library -----------------------------------------------------
# build/config/haiku/compat/lib (Haiku patch 0006/0011) holds the Media Kit
# audio shim, which GN cannot build: it must be compiled against Haiku's own
# headers and libstdc++, not Chromium's libc++. libm.a there is a linker script
# that pulls libhaikucompat.a (and libmedia, libbe) into every link. On Renga
# this is the only helper left (thread_local destructors come from libroot).
COMPAT=$SRC/build/config/haiku/compat/lib
if [ ! -f "$COMPAT/libhaikucompat.a" ] ||
   [ "$COMPAT/haiku_media_audio.cpp" -nt "$COMPAT/libhaikucompat.a" ] ||
   [ -f "$COMPAT/haiku_cxa_thread_atexit.o" ]; then
  echo "==> Building libhaikucompat.a"
  [ -n "${SYS_CXX:-}" ] || { echo "No system C++ compiler (g++) for the Media Kit shim." >&2; exit 1; }
  ( cd "$COMPAT"
    rm -f haiku_cxa_thread_atexit.o   # left over from a stock-Haiku build
    "$SYS_CXX" -fPIC -O2 -fno-exceptions -fno-rtti -fno-sized-deallocation \
        -c haiku_media_audio.cpp -o haiku_media_audio.o
    rm -f libhaikucompat.a
    "$LLVM_AR" rcs libhaikucompat.a haiku_media_audio.o )
fi

# --- Pregenerated Tint sources -----------------------------------------------
# Tint's generator needs Go >= 1.26 (not available on Haiku); see docs/TINT.md.
if [ ! -f "$OUT/gen/src/tint/lang/core/enums.cc" ]; then
  echo "==> Unpacking pregenerated Tint sources into $OUT/gen"
  mkdir -p "$OUT/gen"
  tar -xzf "$HERE/prebuilt/tint-gen.tar.gz" -C "$OUT/gen"
fi

echo "==> gn gen $OUT" | tee -a "$LOG"
logged "gn gen" "$OUT/gn" gen "$OUT"

# --- ninja -------------------------------------------------------------------
JOBS=${JOBS:-$(nproc 2>/dev/null || sysinfo -cpu 2>/dev/null | grep -c '^CPU #' || echo 2)}
echo "==> ninja -j$JOBS ${TARGETS[*]}" | tee -a "$LOG"
logged ninja ninja -C "$OUT" -j"$JOBS" "${TARGETS[@]}"
rm -f "$LOG_DIR/build-latest-failures.txt"

echo
echo "Built $SRC/$OUT/chrome"
echo "Run it with: $HERE/scripts/run-chromium.sh $SRC/$OUT"
