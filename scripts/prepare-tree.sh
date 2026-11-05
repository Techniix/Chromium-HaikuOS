#!/bin/bash
# Copyright 2026 The Chromium Authors
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.
#
# Turn a pristine Chromium release tree into a Haiku-ready tree:
#   1. apply the FreeBSD port patches       (patches/freebsd, patch -p0)
#   2. extend BSD guards to Haiku           (tools/haikuify.py)
#   3. apply the Haiku patches              (patches/haiku/{chromium,v8})
#   4. point build files at the system toolchain (LLVM, Rust, bindgen, ...)
#   5. link system tools where Chromium expects its Linux prebuilts
#
# Usage: scripts/prepare-tree.sh SRC_DIR
# Run it once on a freshly unpacked tree. It refuses to run twice.

set -euo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
SRC=${1:?usage: prepare-tree.sh SRC_DIR}
SRC=$(cd "$SRC" && pwd)
STAMP=$SRC/.haiku-prepared

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[ -f "$SRC/chrome/VERSION" ] || die "$SRC does not look like a Chromium src/ tree"
[ -f "$STAMP" ] && die "$SRC was already prepared ($(cat "$STAMP")). Start from a fresh tree."

# --- 0. Detect the toolchain -------------------------------------------------
. "$HERE/scripts/detect-toolchain.sh"

# --- 1. FreeBSD patches ------------------------------------------------------
log "Applying FreeBSD patches"
n=0
for p in "$HERE"/patches/freebsd/patch-*; do
  if ! patch -d "$SRC" -p0 -N -s -f --no-backup-if-mismatch -r - < "$p" >/dev/null; then
    die "FreeBSD patch failed: $(basename "$p")"
  fi
  n=$((n + 1))
done
echo "applied $n patches"

# --- 2. haikuify -------------------------------------------------------------
log "Extending BSD guards to Haiku"
python3 "$HERE/tools/haikuify.py" "$SRC" --report "$SRC/haikuify-report.md"

# --- 3. Haiku patches --------------------------------------------------------
log "Applying Haiku patches"
for p in "$HERE"/patches/haiku/chromium/*.patch "$HERE"/patches/haiku/v8/*.patch; do
  patch -d "$SRC" -p1 -N -s -f --no-backup-if-mismatch -r - < "$p" >/dev/null \
    || die "Haiku patch failed: $p"
  echo "applied $(basename "$p")"
done

# --- 4. Toolchain paths ------------------------------------------------------
# The FreeBSD patches use FreeBSD's LLVM layout (${LOCALBASE}/llvmNN/...);
# replace each with the path detected on this system.
log "Pointing build files at the system toolchain"
subst() { # file from to
  local f=$SRC/$1
  [ -f "$f" ] || die "missing $1"
  python3 - "$f" "$2" "$3" <<'PY'
import sys
path, old, new = sys.argv[1:]
text = open(path).read()
if old not in text:
    sys.exit(f"{path}: pattern not found: {old}")
open(path, "w").write(text.replace(old, new))
PY
}
subst build/linux/strip_binary.gni '${LOCALBASE}/llvm${MODCLANG_VERSION}/bin/llvm-strip' "$LLVM_STRIP"
subst build/linux/strip_binary.gni '${LOCALBASE}/llvm${MODCLANG_VERSION}/bin/llvm-objcopy' "$LLVM_OBJCOPY"
subst build/rust/rust_bindgen.gni '${LOCALBASE}/bin/bindgen' "$BINDGEN"
subst build/rust/rust_bindgen.gni '${LOCALBASE}/llvm${MODCLANG_VERSION}' "$LIBCLANG_PREFIX"
subst build/rust/rust_bindgen_generator.gni '${LOCALBASE}/bin/bindgen' "$BINDGEN"
subst build/rust/rust_bindgen_generator.gni '${LOCALBASE}/bin/rustfmt' "$RUSTFMT"
subst build/rust/rust_bindgen_generator.gni '${LOCALBASE}/llvm${MODCLANG_VERSION}' "$LIBCLANG_PREFIX"
subst v8/BUILD.gn '${LOCALBASE}/llvm${MODCLANG_VERSION}/lib/clang/${MODCLANG_VERSION}' "$CLANG_RESOURCE_DIR"
subst build/config/rust.gni '"/usr/local/bin/rustc"' "\"$RUSTC\""

# Any FreeBSD placeholder left in a build file would silently produce a bogus
# path; fail loudly instead so the substitution list above gets updated.
left=$(grep -rlE '\$\{(LOCALBASE|MODCLANG_VERSION)\}' --include='*.gn' --include='*.gni' "$SRC" || true)
[ -z "$left" ] || die "unsubstituted FreeBSD placeholders in: $left"

# --- 5. Tool links -----------------------------------------------------------
# Chromium looks for these under its own prebuilt directories.
log "Linking system tools into the tree"
link() { mkdir -p "$(dirname "$SRC/$2")"; ln -sf "$1" "$SRC/$2"; echo "$2 -> $1"; }
link "$NODE"   third_party/node/haiku/node-haiku/bin/node
link "$RUSTC"  third_party/rust-toolchain/bin/rustc
link "$GPERF"  third_party/gperf/cipd/bin/gperf
link "$ESBUILD" third_party/devtools-frontend/src/third_party/esbuild/esbuild
if [ -n "${TSGO:-}" ]; then
  link "$TSGO" third_party/typescript/linux-amd64/src/lib/tsc
fi
if [ -n "${CLANG_FORMAT:-}" ]; then
  link "$CLANG_FORMAT" buildtools/haiku/clang-format
  link "$CLANG_FORMAT" buildtools/linux64/clang-format
fi

date -u +"%Y-%m-%dT%H:%M:%SZ by $(basename "$0")" > "$STAMP"

log "Done"
echo "Review $SRC/haikuify-report.md, then run: scripts/build.sh $SRC"
